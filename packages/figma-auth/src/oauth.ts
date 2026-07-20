import { randomBytes } from "node:crypto";
import { UnauthorizedError } from "@modelcontextprotocol/sdk/client/auth.js";
import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { StreamableHTTPClientTransport } from "@modelcontextprotocol/sdk/client/streamableHttp.js";
import { openBrowser, type BrowserOpener } from "./browser.js";
import {
  startCallbackServer,
  type CallbackServer,
  type CallbackServerOptions,
} from "./callback-server.js";
import { FreshOAuthProvider } from "./oauth-provider.js";
import { FIGMA_SERVER_URL, type StorageAdapter } from "./storage/types.js";

export interface McpConnection {
  connect(): Promise<void>;
  finishAuth(code: string): Promise<void>;
  close(): Promise<void>;
}

export type ConnectionFactory = (provider: FreshOAuthProvider) => McpConnection;
export type CallbackFactory = (options: CallbackServerOptions) => Promise<CallbackServer>;

export interface OAuthFlowOptions {
  adapter: StorageAdapter;
  opener?: BrowserOpener;
  callbackFactory?: CallbackFactory;
  connectionFactory?: ConnectionFactory;
  randomState?: () => string;
  signal?: AbortSignal;
  isUnauthorized?: (error: unknown) => boolean;
}

export const FIGMA_MCP_CLIENT_INFO = { name: "Codex", version: "1.0.0" } as const;

function createMcpConnection(provider: FreshOAuthProvider): McpConnection {
  const transport = new StreamableHTTPClientTransport(new URL(FIGMA_SERVER_URL), {
    authProvider: provider,
  });
  const client = new Client(FIGMA_MCP_CLIENT_INFO, { capabilities: {} });
  return {
    // SDK 1.29.0's concrete transport exposes an optional sessionId while its
    // Transport interface declares the same getter without exact-optional
    // compatibility. It is the SDK's documented transport for this client.
    connect: () => client.connect(transport as Parameters<Client["connect"]>[0]),
    finishAuth: (code) => transport.finishAuth(code),
    close: () => client.close(),
  };
}

export async function runOAuthFlow(options: OAuthFlowOptions): Promise<void> {
  options.signal?.throwIfAborted();

  const oauthState = (options.randomState ?? (() => randomBytes(32).toString("base64url")))();
  if (!oauthState) throw new Error("Could not generate OAuth state");

  const provider = new FreshOAuthProvider(oauthState, options.opener ?? openBrowser);
  const factory = options.connectionFactory ?? createMcpConnection;
  const abort = rejectionOnAbort(options.signal);
  let callback: CallbackServer | undefined;
  let first: McpConnection | undefined;
  let retry: McpConnection | undefined;
  let primaryError: unknown;
  let failed = false;
  let committed = false;
  let callbackCloseError: unknown;

  try {
    callback = await raceWithAbort(
      (options.callbackFactory ?? startCallbackServer)({
        state: oauthState,
        ...(options.signal === undefined ? {} : { signal: options.signal }),
      }),
      abort.promise,
    );
    const waitForCode = callback.waitForCode();
    // A successful callback cannot replace the required UnauthorizedError from
    // the initial connection, but callback failure must interrupt a stalled one.
    const callbackRejection = new Promise<never>((_resolve, reject) => {
      void waitForCode.catch(reject);
    });

    first = factory(provider);
    try {
      await Promise.race([first.connect(), callbackRejection, abort.promise]);
      throw new Error("Figma MCP unexpectedly accepted a fresh unauthenticated session");
    } catch (error) {
      const unauthorized = options.isUnauthorized
        ? options.isUnauthorized(error)
        : error instanceof UnauthorizedError;
      if (!unauthorized) throw error;
    }

    const code = await Promise.race([waitForCode, abort.promise]);
    await Promise.race([first.finishAuth(code), abort.promise]);
    retry = factory(provider);
    await Promise.race([retry.connect(), abort.promise]);
    const completedSession = provider.completedSession();
    // Persistence is the commit point. Once entered it is intentionally not
    // raced with cancellation so an atomic credential replacement can finish.
    options.signal?.throwIfAborted();
    await options.adapter.commit(completedSession);
    committed = true;
  } catch (error) {
    failed = true;
    primaryError = error;
  } finally {
    abort.dispose();
    const callbackClose = Promise.resolve().then(() => callback?.close());
    const cleanup = await Promise.allSettled([safeClose(retry), safeClose(first), callbackClose]);
    if (cleanup[2]?.status === "rejected") callbackCloseError = cleanup[2].reason;
  }

  if (failed) throw primaryError;
  if (callbackCloseError !== undefined) {
    const detail =
      callbackCloseError instanceof Error
        ? callbackCloseError.message
        : typeof callbackCloseError === "string"
          ? callbackCloseError
          : "unknown cleanup error";
    throw new Error(
      committed
        ? `Figma MCP credentials were committed, but the OAuth callback server failed to close: ${detail}`
        : `OAuth callback server cleanup failed before credentials were committed: ${detail}`,
      { cause: callbackCloseError },
    );
  }
}

function rejectionOnAbort(signal: AbortSignal | undefined): {
  promise: Promise<never>;
  dispose(): void;
} {
  if (!signal) {
    return { promise: new Promise<never>(() => undefined), dispose: () => undefined };
  }

  let onAbort: () => void = () => undefined;
  const promise = new Promise<never>((_resolve, reject) => {
    onAbort = () => {
      try {
        signal.throwIfAborted();
      } catch (error) {
        reject(error);
      }
    };
    signal.addEventListener("abort", onAbort, { once: true });
    if (signal.aborted) onAbort();
  });
  return {
    promise,
    dispose: () => signal.removeEventListener("abort", onAbort),
  };
}

function raceWithAbort<T>(operation: Promise<T>, abort: Promise<never>): Promise<T> {
  return Promise.race([operation, abort]);
}

async function safeClose(connection: McpConnection | undefined): Promise<void> {
  if (!connection) return;
  try {
    await connection.close();
  } catch {
    // Connection cleanup must not mask the authorization or persistence result.
  }
}
