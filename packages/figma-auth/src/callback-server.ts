import { createServer, type Server } from "node:http";
import { CALLBACK_PATH, CALLBACK_PORT } from "./oauth-provider.js";

export const CALLBACK_TIMEOUT_MS = 5 * 60 * 1000;

export interface CallbackServer {
  readonly port: number;
  waitForCode(): Promise<string>;
  close(): Promise<void>;
}

export interface CallbackServerOptions {
  state: string;
  port?: number;
  timeoutMs?: number;
  signal?: AbortSignal;
}

function page(title: string, detail: string): string {
  return `<!doctype html><meta charset="utf-8"><title>${title}</title><h1>${title}</h1><p>${detail}</p>`;
}

function cancellationError(signal: AbortSignal): unknown {
  try {
    signal.throwIfAborted();
  } catch (error) {
    return error;
  }
  return new Error("OAuth authorization cancelled");
}

export async function startCallbackServer(options: CallbackServerOptions): Promise<CallbackServer> {
  options.signal?.throwIfAborted();

  const port = options.port ?? CALLBACK_PORT;
  const timeoutMs = options.timeoutMs ?? CALLBACK_TIMEOUT_MS;
  let settled = false;
  let resolveCode: (code: string) => void = () => undefined;
  let rejectCode: (error: Error) => void = () => undefined;
  const codePromise = new Promise<string>((resolve, reject) => {
    resolveCode = resolve;
    rejectCode = reject;
  });

  const settleError = (error: Error): void => {
    if (settled) return;
    settled = true;
    rejectCode(error);
  };
  const settleCode = (code: string): void => {
    if (settled) return;
    settled = true;
    resolveCode(code);
  };

  const server = createServer((request, response) => {
    const requestUrl = new URL(request.url ?? "/", `http://127.0.0.1:${port}`);
    if (requestUrl.pathname !== CALLBACK_PATH) {
      response.writeHead(404, { "content-type": "text/plain; charset=utf-8" });
      response.end("Not found\n");
      return;
    }

    if (request.method !== "GET") {
      response.writeHead(405, {
        allow: "GET",
        "content-type": "text/plain; charset=utf-8",
      });
      response.end("Method not allowed\n");
      return;
    }

    const stateValues = requestUrl.searchParams.getAll("state");
    const codeValues = requestUrl.searchParams.getAll("code");
    const errorValues = requestUrl.searchParams.getAll("error");
    if (stateValues.length > 1 || codeValues.length > 1 || errorValues.length > 1) {
      response.writeHead(400, { "content-type": "text/html; charset=utf-8" });
      response.end(page("Authorization failed", "The callback contained duplicate parameters."));
      return;
    }

    const state = stateValues[0];
    if (state !== options.state) {
      response.writeHead(400, { "content-type": "text/html; charset=utf-8" });
      response.end(page("Authorization failed", "The OAuth state did not match."));
      return;
    }

    if (errorValues.length === 1) {
      const providerError = errorValues[0] || "unknown_error";
      const description = requestUrl.searchParams.get("error_description");
      response.writeHead(400, { "content-type": "text/html; charset=utf-8" });
      response.end(page("Authorization failed", "Figma rejected the authorization request."));
      settleError(
        new Error(
          `OAuth provider error: ${providerError}${description ? ` (${description})` : ""}`,
        ),
      );
      return;
    }

    const code = codeValues[0];
    if (!code) {
      response.writeHead(400, { "content-type": "text/html; charset=utf-8" });
      response.end(page("Authorization failed", "The callback did not include a code."));
      settleError(new Error("OAuth callback did not include an authorization code"));
      return;
    }

    response.writeHead(200, { "content-type": "text/html; charset=utf-8" });
    response.end(
      page("Authorization successful", "You can close this tab and return to the terminal."),
    );
    settleCode(code);
  });

  await new Promise<void>((resolve, reject) => {
    let finished = false;
    const cleanup = (): void => {
      server.off("error", onError);
      server.off("listening", onListening);
      options.signal?.removeEventListener("abort", onAbort);
    };
    const finish = (action: () => void): void => {
      if (finished) return;
      finished = true;
      cleanup();
      action();
    };
    const onError = (error: Error): void => finish(() => reject(error));
    const onListening = (): void => finish(resolve);
    const onAbort = (): void => {
      finish(() => {
        try {
          server.close();
        } catch {
          // The listener may not have reached the listening state yet.
        }
        reject(cancellationError(options.signal as AbortSignal));
      });
    };

    server.once("error", onError);
    server.once("listening", onListening);
    options.signal?.addEventListener("abort", onAbort, { once: true });
    if (options.signal?.aborted) {
      onAbort();
      return;
    }
    server.listen(port, "127.0.0.1");
  });

  try {
    options.signal?.throwIfAborted();
  } catch (error) {
    await closeServer(server);
    throw error;
  }

  const timeout = setTimeout(() => settleError(new Error("OAuth callback timed out")), timeoutMs);
  timeout.unref();
  const onAbort = (): void => settleError(new Error("OAuth authorization cancelled"));
  options.signal?.addEventListener("abort", onAbort, { once: true });
  if (options.signal?.aborted) onAbort();

  const address = server.address();
  if (!address || typeof address === "string") {
    clearTimeout(timeout);
    options.signal?.removeEventListener("abort", onAbort);
    await closeServer(server);
    throw new Error("Could not determine OAuth callback address");
  }

  let closePromise: Promise<void> | undefined;
  return {
    port: address.port,
    waitForCode: () => codePromise,
    close: () => {
      if (closePromise) return closePromise;
      clearTimeout(timeout);
      options.signal?.removeEventListener("abort", onAbort);
      if (!settled) settleError(new Error("OAuth callback server closed"));
      server.closeAllConnections();
      closePromise = closeServer(server);
      return closePromise;
    },
  };
}

async function closeServer(server: Server): Promise<void> {
  if (!server.listening) return;
  await new Promise<void>((resolve, reject) => {
    server.close((error) => (error ? reject(error) : resolve()));
  });
}
