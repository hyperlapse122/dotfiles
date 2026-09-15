import { createServer, type IncomingMessage, type Server, type ServerResponse } from "node:http";
import { Readable } from "node:stream";
import { createProxyHandler, DEFAULT_HOST, DEFAULT_PORT, type ProxyOptions } from "./proxy.js";

export interface ListenOptions extends ProxyOptions {
  host?: string;
  port?: number;
}

export interface ListeningSidecar {
  server: Server;
  host: string;
  port: number;
  url: string;
  close: () => Promise<void>;
}

function requestTarget(input: string | undefined): string {
  if (input === undefined || input.startsWith("/")) return input ?? "/";
  try {
    const parsed = new URL(input);
    return `${parsed.pathname}${parsed.search}`;
  } catch {
    return "/";
  }
}

function requestHeaders(input: IncomingMessage): Headers {
  const headers = new Headers();
  for (const [name, value] of Object.entries(input.headers)) {
    if (value === undefined) continue;
    headers.set(name, Array.isArray(value) ? value.join(", ") : value);
  }
  return headers;
}

async function writeResponse(
  response: Response,
  output: ServerResponse,
  request: IncomingMessage,
  controller: AbortController,
): Promise<void> {
  output.statusCode = response.status;
  if (response.statusText !== "") output.statusMessage = response.statusText;
  response.headers.forEach((value, name) => output.setHeader(name, value));

  if (
    response.body === null ||
    request.method === "HEAD" ||
    response.status === 204 ||
    response.status === 304
  ) {
    if (response.body !== null) await response.body.cancel();
    output.end();
    return;
  }

  const body = Readable.fromWeb(
    response.body as unknown as import("node:stream/web").ReadableStream<
      Uint8Array<ArrayBufferLike>
    >,
  );
  const abortOnClose = () => {
    if (!output.writableEnded) {
      controller.abort();
      body.destroy();
    }
  };
  output.once("close", abortOnClose);

  return new Promise((resolve) => {
    const finish = () => {
      output.removeListener("close", abortOnClose);
      output.removeListener("close", finish);
      resolve();
    };
    output.once("close", finish);
    body.once("error", () => {
      if (!output.headersSent) {
        output.statusCode = 502;
        output.setHeader("content-type", "application/json");
        output.end(JSON.stringify({ error: { code: 502, message: "upstream stream failed" } }));
      } else {
        output.destroy();
      }
      finish();
    });
    body.once("end", finish);
    body.pipe(output);
  });
}

export function createNodeServer(options: ProxyOptions = {}): Server {
  const handler = createProxyHandler(options);
  return createServer((request, response) => {
    void (async () => {
      const controller = new AbortController();
      const abort = () => controller.abort();
      const onResponseClose = () => {
        if (!response.writableEnded) abort();
      };
      response.once("close", onResponseClose);
      request.once("aborted", abort);
      request.once("close", () => {
        if (!request.complete) abort();
      });

      const method = request.method ?? "GET";
      const init = {
        method,
        headers: requestHeaders(request),
        signal: controller.signal,
        ...(method === "GET" || method === "HEAD"
          ? {}
          : { body: Readable.toWeb(request) as unknown as BodyInit, duplex: "half" as const }),
      } as RequestInit & { duplex?: "half" };
      const webRequest = new Request(`http://${DEFAULT_HOST}${requestTarget(request.url)}`, init);
      try {
        const webResponse = await handler(webRequest);
        if (!response.destroyed) {
          await writeResponse(webResponse, response, request, controller);
        } else {
          await webResponse.body?.cancel();
        }
      } finally {
        request.removeListener("aborted", abort);
        response.removeListener("close", onResponseClose);
      }
    })().catch(() => {
      if (response.headersSent) {
        response.destroy();
      } else {
        response.statusCode = 500;
        response.setHeader("content-type", "application/json");
        response.end(JSON.stringify({ error: { code: 500, message: "sidecar request failed" } }));
      }
    });
  });
}

function validatePort(port: number): number {
  if (!Number.isInteger(port) || port < 0 || port > 65_535) {
    throw new RangeError("port must be an integer from 0 through 65535");
  }
  return port;
}

export async function listenSidecar(options: ListenOptions = {}): Promise<ListeningSidecar> {
  const host = options.host ?? DEFAULT_HOST;
  if (host !== DEFAULT_HOST) throw new Error(`sidecar host must be ${DEFAULT_HOST}`);
  const port = validatePort(options.port ?? DEFAULT_PORT);
  const server = createNodeServer(options);

  await new Promise<void>((resolve, reject) => {
    const onError = (error: Error) => {
      server.removeListener("listening", onListening);
      reject(error);
    };
    const onListening = () => {
      server.removeListener("error", onError);
      resolve();
    };
    server.once("error", onError);
    server.once("listening", onListening);
    server.listen(port, host);
  });

  const address = server.address();
  if (address === null || typeof address === "string") {
    await new Promise<void>((resolve) => server.close(() => resolve()));
    throw new Error("sidecar did not expose a TCP address");
  }
  const actualPort = address.port;
  return {
    server,
    host,
    port: actualPort,
    url: `http://${host}:${actualPort}`,
    close: async () => {
      if (!server.listening) return;
      await new Promise<void>((resolve, reject) => {
        server.close((error) => (error === undefined ? resolve() : reject(error)));
      });
    },
  };
}
