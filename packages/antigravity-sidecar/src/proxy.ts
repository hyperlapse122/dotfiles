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

function findSystemInstructionValueSpan(raw: string): { start: number; end: number } | null {
  let inString = false;
  let escaped = false;
  const objectKeyStack: string[] = [];
  let currentKey = "";
  let expectingKey = false;
  let colonAfterKey = false;

  for (let i = 0; i < raw.length; i++) {
    const code = raw.charCodeAt(i);
    if (inString) {
      if (escaped) {
        escaped = false;
      } else if (code === 92) {
        escaped = true;
      } else if (code === 34) {
        inString = false;
      }
      continue;
    }

    if (code === 34) {
      if (expectingKey) {
        const keyStart = i + 1;
        let keyEnd = -1;
        for (let j = keyStart; j < raw.length; j++) {
          const c = raw.charCodeAt(j);
          if (c === 92) {
            j++;
          } else if (c === 34) {
            keyEnd = j;
            break;
          }
        }
        if (keyEnd !== -1) {
          try {
            currentKey = JSON.parse(raw.slice(i, keyEnd + 1)) as string;
          } catch {
            currentKey = raw.slice(keyStart, keyEnd);
          }
          i = keyEnd;
          expectingKey = false;
          colonAfterKey = true;
          continue;
        }
      }
      inString = true;
      continue;
    }

    if (colonAfterKey) {
      if (code === 32 || code === 9 || code === 10 || code === 13) continue;
      if (code === 58) {
        colonAfterKey = false;
        const parentKey = objectKeyStack[objectKeyStack.length - 1] ?? "";
        if (
          currentKey === "systemInstruction" &&
          (parentKey === "request" || objectKeyStack.length === 0)
        ) {
          let braceIdx = i + 1;
          while (
            braceIdx < raw.length &&
            (raw.charCodeAt(braceIdx) === 32 ||
              raw.charCodeAt(braceIdx) === 9 ||
              raw.charCodeAt(braceIdx) === 10 ||
              raw.charCodeAt(braceIdx) === 13)
          ) {
            braceIdx++;
          }
          if (raw.charCodeAt(braceIdx) === 123) {
            let objDepth = 0;
            let str = false;
            let esc = false;
            for (let k = braceIdx; k < raw.length; k++) {
              const c = raw.charCodeAt(k);
              if (str) {
                if (esc) esc = false;
                else if (c === 92) esc = true;
                else if (c === 34) str = false;
              } else if (c === 34) {
                str = true;
              } else if (c === 123) {
                objDepth++;
              } else if (c === 125) {
                objDepth--;
                if (objDepth === 0) {
                  return { start: braceIdx, end: k + 1 };
                }
              }
            }
          }
        }
        continue;
      }
      colonAfterKey = false;
    }

    if (code === 123) {
      objectKeyStack.push(currentKey);
      expectingKey = true;
      currentKey = "";
    } else if (code === 125) {
      objectKeyStack.pop();
      expectingKey = false;
      currentKey = "";
    } else if (code === 91) {
      objectKeyStack.push("");
      expectingKey = false;
      currentKey = "";
    } else if (code === 93) {
      objectKeyStack.pop();
      expectingKey = false;
      currentKey = "";
    } else if (code === 44) {
      if (objectKeyStack.length > 0) {
        expectingKey = true;
        currentKey = "";
      }
    }
  }
  return null;
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

  const span = findSystemInstructionValueSpan(raw);
  if (span !== null) {
    const sysSegment = raw.slice(span.start, span.end);
    const frames: {
      path: (string | number)[];
      array: boolean;
      key: string | number;
      keyNext: boolean;
    }[] = [];
    const rewrittenSegment = sysSegment.replace(
      /"(?:\\.|[^"\\])*"|[{}[\]:,]|[^\s{}[\]:,]+/g,
      (token) => {
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
              path: path.slice(0, 4),
              array: token === "[",
              key: token === "[" ? 0 : "",
              keyNext: token === "{",
            });
          } else if (
            token.startsWith('"') &&
            path.length === 3 &&
            path[0] === "parts" &&
            typeof path[1] === "number" &&
            path[2] === "text"
          ) {
            const text = JSON.parse(token) as string;
            const replacement = rewriteText(text);
            return replacement === text ? token : JSON.stringify(replacement);
          }
        }
        return token;
      },
    );
    const result = raw.slice(0, span.start) + rewrittenSegment + raw.slice(span.end);
    return new TextEncoder().encode(result);
  }

  return new TextEncoder().encode(JSON.stringify(rewritten));
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
  let closed = false;
  const cleanup = () => signal.removeEventListener("abort", abort);
  const close = () => {
    if (closed) return;
    closed = true;
    cleanup();
  };
  const abort = () => {
    if (closed) return;
    closed = true;
    cleanup();
    void reader.cancel(signal.reason).catch(() => undefined);
  };
  signal.addEventListener("abort", abort, { once: true });
  if (signal.aborted) abort();

  return new ReadableStream<ByteArray>({
    async pull(controller) {
      if (closed) {
        controller.close();
        return;
      }
      try {
        const result = await reader.read();
        if (result.done) {
          close();
          controller.close();
          return;
        }
        controller.enqueue(result.value);
      } catch (error) {
        if (signal.aborted) {
          close();
        } else {
          close();
          controller.error(error);
        }
      }
    },
    async cancel(reason) {
      close();
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
