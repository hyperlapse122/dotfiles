export const DEFAULT_HOST = "127.0.0.1";
export const DEFAULT_PORT = 45123;
export const DEFAULT_UPSTREAM_ORIGIN = "https://daily-cloudcode-pa.googleapis.com";
export const DEFAULT_MAX_BODY_BYTES = 8 * 1024 * 1024;

export const PROVIDER_PATHS = Object.freeze([
  "/v1internal:streamGenerateContent",
  "/v1internal:fetchAvailableModels",
  "/v1internal:retrieveUserQuota",
  "/v1internal:loadCodeAssist",
  "/v1internal:onboardUser",
] as const);

const POST_PATHS = new Set<string>(PROVIDER_PATHS);
const HOP_BY_HOP_HEADERS = new Set([
  "connection",
  "keep-alive",
  "proxy-authenticate",
  "proxy-authorization",
  "proxy-connection",
  "te",
  "trailer",
  "transfer-encoding",
  "upgrade",
]);
const OPERATION_PATH = /^\/v1internal\/operations\/[A-Za-z0-9._~-]+$/;
type ByteArray = Uint8Array<ArrayBufferLike>;

export type FetchLike = (input: RequestInfo | URL, init?: RequestInit) => Promise<Response>;

export interface ProxyOptions {
  upstreamFetch?: FetchLike;
  maxBodyBytes?: number;
}

class ProxyError extends Error {
  constructor(
    readonly status: number,
    readonly code: number,
    readonly publicMessage: string,
    readonly allow?: string,
  ) {
    super(publicMessage);
  }
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

// Patterns from bottlebrushes/antigravity-masking-sidecar, under the included MIT license.
function rewriteText(value: string): string {
  return value
    .replace(/<(\/?)system[-_]conventions>/gi, "<$1conventions>")
    .replace(/<(\/?)system[-_]directive>/gi, "<$1instructions>")
    .replace(/<(\/?)critical>/gi, "<$1important>")
    .replace(/Oh My Pi coding harness/gi, "AI coding assistant")
    .replace(/Oh My Pi/gi, "coding assistant")
    .replace(/omp Live/gi, "coding assistant live");
}

export function rewriteSystemInstructionParts(value: unknown): unknown {
  if (!isRecord(value) || !isRecord(value.request) || !isRecord(value.request.systemInstruction)) {
    return value;
  }

  const parts = value.request.systemInstruction.parts;
  if (!Array.isArray(parts)) return value;

  let changed = false;
  const rewrittenParts = parts.map((part) => {
    if (!isRecord(part) || typeof part.text !== "string") return part;
    const text = rewriteText(part.text);
    if (text === part.text) return part;
    changed = true;
    return { ...part, text };
  });

  if (!changed) return value;
  return {
    ...value,
    request: {
      ...value.request,
      systemInstruction: {
        ...value.request.systemInstruction,
        parts: rewrittenParts,
      },
    },
  };
}

function normalizeMaxBodyBytes(value: number | undefined): number {
  if (value === undefined) return DEFAULT_MAX_BODY_BYTES;
  if (!Number.isSafeInteger(value) || value <= 0) {
    throw new RangeError("maxBodyBytes must be a positive safe integer");
  }
  return value;
}

function isOperationPath(pathname: string): boolean {
  return OPERATION_PATH.test(pathname);
}

export function allowedProviderMethods(pathname: string): readonly string[] {
  if (POST_PATHS.has(pathname)) return ["POST"];
  if (isOperationPath(pathname)) return ["GET"];
  return [];
}

function errorResponse(error: ProxyError): Response {
  const headers = new Headers({ "content-type": "application/json" });
  if (error.allow !== undefined) headers.set("allow", error.allow);
  return new Response(
    JSON.stringify({
      error: {
        code: error.code,
        message: error.publicMessage,
        status: statusName(error.status),
      },
    }),
    { status: error.status, headers },
  );
}

function statusName(status: number): string {
  if (status === 400) return "BAD_REQUEST";
  if (status === 404) return "NOT_FOUND";
  if (status === 405) return "METHOD_NOT_ALLOWED";
  if (status === 413) return "PAYLOAD_TOO_LARGE";
  if (status === 415) return "UNSUPPORTED_MEDIA_TYPE";
  if (status === 499) return "CLIENT_CLOSED_REQUEST";
  return "BAD_GATEWAY";
}

function clientClosedResponse(): Response {
  return new Response(null, { status: 499 });
}

async function readBody(request: Request, maxBytes: number): Promise<ByteArray> {
  const rawLength = request.headers.get("content-length");
  const declaredLength = rawLength === null ? undefined : Number(rawLength);
  if (
    declaredLength !== undefined &&
    Number.isSafeInteger(declaredLength) &&
    declaredLength > maxBytes
  ) {
    throw new ProxyError(413, 413, "request body exceeds the sidecar limit");
  }
  if (request.body === null) return new Uint8Array();

  const reader = request.body.getReader();
  const chunks: ByteArray[] = [];
  let total = 0;
  const abort = () => {
    void reader.cancel(request.signal.reason).catch(() => undefined);
  };
  request.signal.addEventListener("abort", abort, { once: true });
  try {
    while (true) {
      const result = await reader.read();
      if (result.done) break;
      const chunk = new Uint8Array(result.value);
      total += chunk.byteLength;
      if (total > maxBytes) {
        await reader.cancel("request body exceeds the sidecar limit");
        throw new ProxyError(413, 413, "request body exceeds the sidecar limit");
      }
      chunks.push(chunk);
    }
  } catch (error) {
    if (error instanceof ProxyError) throw error;
    throw new ProxyError(400, 400, "request body could not be read");
  } finally {
    request.signal.removeEventListener("abort", abort);
  }

  const body = new Uint8Array(total);
  let offset = 0;
  for (const chunk of chunks) {
    body.set(chunk, offset);
    offset += chunk.byteLength;
  }
  return body;
}

function decodeJson(bytes: Uint8Array): string {
  try {
    return new TextDecoder("utf-8", { fatal: true }).decode(bytes);
  } catch {
    throw new ProxyError(400, 400, "request body is not valid UTF-8 JSON");
  }
}

function transformJsonBody(bytes: ByteArray): ByteArray {
  const raw = decodeJson(bytes);
  let value: unknown;
  try {
    value = JSON.parse(raw);
  } catch {
    throw new ProxyError(400, 400, "request body is not valid JSON");
  }

  const rewritten = rewriteSystemInstructionParts(value);
  if (rewritten === value) return bytes;
  // Preserve raw numbers, duplicate keys, and whitespace outside the system strings.
  const frames: {
    path: (string | number)[];
    array: boolean;
    key: string | number;
    keyNext: boolean;
  }[] = [];
  const result = raw.replace(/"(?:\\.|[^"\\])*"|[{}[\]:,]|[^\s{}[\]:,]+/g, (token) => {
    const parent = frames.at(-1);
    if (token === "}" || token === "]") {
      frames.pop();
    } else if (token === ",") {
      if (parent?.array) parent.key = Number(parent.key) + 1;
      else if (parent) parent.keyNext = true;
    } else if (token === ":") {
      if (parent) parent.keyNext = false;
    } else if (parent?.keyNext && token.startsWith('"')) {
      parent.key = JSON.parse(token) as string;
    } else {
      const path = parent ? [...parent.path, parent.key] : [];
      if (token === "{" || token === "[") {
        frames.push({
          path: path.slice(0, 6),
          array: token === "[",
          key: token === "[" ? 0 : "",
          keyNext: token === "{",
        });
      } else if (
        token.startsWith('"') &&
        path.length === 5 &&
        path[0] === "request" &&
        path[1] === "systemInstruction" &&
        path[2] === "parts" &&
        typeof path[3] === "number" &&
        path[4] === "text"
      ) {
        const text = JSON.parse(token) as string;
        const replacement = rewriteText(text);
        return replacement === text ? token : JSON.stringify(replacement);
      }
    }
    return token;
  });
  return new TextEncoder().encode(result);
}

function isJsonContentType(value: string | null): boolean {
  if (value === null) return false;
  const mediaType = value.split(";", 1)[0]?.trim().toLowerCase();
  return mediaType === "application/json" || mediaType?.endsWith("+json") === true;
}

function hopByHopHeaderNames(input: Headers): Set<string> {
  const names = new Set(HOP_BY_HOP_HEADERS);
  for (const value of input.get("connection")?.split(",") ?? []) {
    const name = value.trim().toLowerCase();
    if (name !== "") names.add(name);
  }
  return names;
}

function copyRequestHeaders(input: Headers, bodyChanged: boolean): Headers {
  const output = new Headers();
  const hopByHop = hopByHopHeaderNames(input);
  input.forEach((value, name) => {
    const lower = name.toLowerCase();
    if (lower === "host" || lower === "content-length" || hopByHop.has(lower)) return;
    if (bodyChanged && lower === "content-encoding") return;
    output.set(name, value);
  });
  return output;
}

function copyResponseHeaders(input: Headers): Headers {
  const output = new Headers();
  const hopByHop = hopByHopHeaderNames(input);
  input.forEach((value, name) => {
    const lower = name.toLowerCase();
    if (hopByHop.has(lower) || lower === "content-length" || lower === "content-encoding") {
      return;
    }
    output.set(name, value);
  });
  return output;
}

function relayBody(
  source: ReadableStream<ByteArray>,
  signal: AbortSignal,
): ReadableStream<ByteArray> {
  const reader = source.getReader();
  let controller: ReadableStreamDefaultController<ByteArray> | undefined;
  let closed = false;
  const cleanup = () => signal.removeEventListener("abort", abort);
  const close = () => {
    if (closed) return;
    closed = true;
    cleanup();
    controller?.close();
  };
  const abort = () => {
    void reader.cancel(signal.reason).catch(() => undefined);
    close();
  };
  signal.addEventListener("abort", abort, { once: true });

  return new ReadableStream<ByteArray>({
    start(value) {
      controller = value;
      if (signal.aborted) abort();
    },
    async pull(value) {
      if (closed) return;
      try {
        const result = await reader.read();
        if (result.done) {
          close();
          return;
        }
        value.enqueue(result.value);
      } catch (error) {
        if (signal.aborted) {
          close();
        } else {
          closed = true;
          cleanup();
          value.error(error);
        }
      }
    },
    async cancel(reason) {
      closed = true;
      cleanup();
      await reader.cancel(reason);
    },
  });
}

export function createProxyHandler(
  options: ProxyOptions = {},
): (request: Request) => Promise<Response> {
  const maxBodyBytes = normalizeMaxBodyBytes(options.maxBodyBytes);
  const upstreamFetch = options.upstreamFetch ?? (fetch as FetchLike);

  return async (request: Request): Promise<Response> => {
    if (request.signal.aborted) return clientClosedResponse();

    const url = new URL(request.url);
    if (url.pathname === "/health") {
      if (request.method !== "GET" && request.method !== "HEAD") {
        return errorResponse(new ProxyError(405, 405, "method is not allowed", "GET, HEAD"));
      }
      return new Response(
        JSON.stringify({
          status: "ok",
          service: "antigravity-sidecar",
          upstream: DEFAULT_UPSTREAM_ORIGIN,
        }),
        { status: 200, headers: { "content-type": "application/json" } },
      );
    }

    const method = request.method.toUpperCase();
    const allowedMethods = allowedProviderMethods(url.pathname);
    if (allowedMethods.length === 0) {
      return errorResponse(new ProxyError(404, 404, "path is not available through the sidecar"));
    }
    if (!allowedMethods.includes(method)) {
      return errorResponse(
        new ProxyError(405, 405, "method is not allowed", allowedMethods.join(", ")),
      );
    }

    let body: ByteArray = new Uint8Array();
    let bodyChanged = false;
    if (method !== "GET" && method !== "HEAD") {
      try {
        body = await readBody(request, maxBodyBytes);
      } catch (error) {
        if (request.signal.aborted) return clientClosedResponse();
        if (error instanceof ProxyError) return errorResponse(error);
        return errorResponse(new ProxyError(400, 400, "request body could not be read"));
      }
      if (request.signal.aborted) return clientClosedResponse();
      const contentType = request.headers.get("content-type");
      if (contentType !== null && !isJsonContentType(contentType)) {
        return errorResponse(new ProxyError(415, 415, "JSON request content type is required"));
      }
      const contentEncoding = request.headers.get("content-encoding")?.trim().toLowerCase();
      if (
        contentEncoding !== undefined &&
        contentEncoding !== "" &&
        contentEncoding !== "identity"
      ) {
        return errorResponse(
          new ProxyError(415, 415, "compressed JSON requests are not supported"),
        );
      }
      let transformed: ByteArray;
      try {
        transformed = transformJsonBody(body);
      } catch (error) {
        if (error instanceof ProxyError) return errorResponse(error);
        return errorResponse(new ProxyError(400, 400, "request body is not valid JSON"));
      }
      bodyChanged = transformed !== body;
      body = transformed;
    }

    const init: RequestInit = {
      method,
      headers: copyRequestHeaders(request.headers, bodyChanged),
      redirect: "error",
      signal: request.signal,
    };
    if (body.byteLength > 0 && method !== "GET" && method !== "HEAD") {
      init.body = body as unknown as BodyInit;
    }

    let upstreamResponse: Response;
    try {
      upstreamResponse = await upstreamFetch(
        `${DEFAULT_UPSTREAM_ORIGIN}${url.pathname}${url.search}`,
        init,
      );
    } catch {
      return request.signal.aborted
        ? clientClosedResponse()
        : errorResponse(new ProxyError(502, 502, "upstream request failed"));
    }

    const responseInit: ResponseInit = {
      status: upstreamResponse.status,
      headers: copyResponseHeaders(upstreamResponse.headers),
    };
    if (upstreamResponse.statusText !== "") responseInit.statusText = upstreamResponse.statusText;
    const responseBody =
      upstreamResponse.body === null ? null : relayBody(upstreamResponse.body, request.signal);
    return new Response(responseBody, responseInit);
  };
}
