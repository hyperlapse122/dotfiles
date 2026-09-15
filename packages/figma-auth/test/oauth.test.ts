import type { ChildProcess, spawn as spawnType } from "node:child_process";
import { EventEmitter } from "node:events";
import { describe, expect, it, vi } from "vite-plus/test";
import { openBrowser } from "../src/browser.js";
import type { CallbackServer } from "../src/callback-server.js";
import { FreshOAuthProvider, REDIRECT_URI } from "../src/oauth-provider.js";
import {
  FIGMA_MCP_CLIENT_INFO,
  runOAuthFlow,
  type ConnectionFactory,
  type McpConnection,
} from "../src/oauth.js";
import { FIGMA_SERVER_URL, type CompletedSession } from "../src/storage/types.js";

function callbackServer(
  options: { code?: string; close?: () => Promise<void> } = {},
): CallbackServer {
  return {
    port: 19876,
    waitForCode: async () => options.code ?? "auth-code",
    close: options.close ?? vi.fn(async () => undefined),
  };
}

function successfulFactory(unauthorized: Error, order: string[] = []): ConnectionFactory {
  let connectionNumber = 0;
  return (provider): McpConnection => {
    connectionNumber += 1;
    const number = connectionNumber;
    return {
      connect: async () => {
        if (number === 1) {
          order.push("discover-register-authorize");
          provider.saveDiscoveryState({ authorizationServerUrl: "https://www.figma.com" });
          provider.saveClientInformation({ client_id: "new-client" });
          provider.saveCodeVerifier("verifier");
          await provider.redirectToAuthorization(new URL("https://www.figma.com/oauth"));
          throw unauthorized;
        }
        order.push("authenticated-reconnect");
      },
      finishAuth: async (code) => {
        order.push(`finish:${code}`);
        provider.saveTokens({
          access_token: "fake-access",
          token_type: "bearer",
          refresh_token: "fake-refresh",
          expires_in: 3600,
        });
      },
      close: vi.fn(async () => undefined),
    };
  };
}

function fakeChild(): { child: ChildProcess; unref: ReturnType<typeof vi.fn> } {
  const unref = vi.fn();
  const child = Object.assign(new EventEmitter(), { unref }) as unknown as ChildProcess;
  return { child, unref };
}

describe("fresh OAuth provider", () => {
  it("starts empty and exposes the Figma client identity", () => {
    const provider = new FreshOAuthProvider(
      "state",
      vi.fn(async () => undefined),
    );
    expect(provider.clientInformation()).toBeUndefined();
    expect(provider.tokens()).toBeUndefined();
    expect(provider.discoveryState()).toBeUndefined();
    expect(provider.redirectUrl).toBe(REDIRECT_URI);
    expect(provider.clientMetadata).toEqual({
      client_name: "Codex",
      redirect_uris: [REDIRECT_URI],
      grant_types: ["authorization_code", "refresh_token"],
      response_types: ["code"],
      token_endpoint_auth_method: "none",
    });
    expect(FIGMA_MCP_CLIENT_INFO).toEqual({ name: "Codex", version: "1.0.0" });
    expect(FIGMA_SERVER_URL).toBe("https://mcp.figma.com/mcp");
  });
});

describe("OAuth flow", () => {
  it("performs fresh DCR/PKCE, reconnects, and commits once", async () => {
    const order: string[] = [];
    const committed: CompletedSession[] = [];
    const unauthorized = new Error("unauthorized");
    const close = vi.fn(async () => undefined);

    await runOAuthFlow({
      adapter: {
        commit: async (session) => {
          committed.push(session);
        },
      },
      randomState: () => "random-state",
      callbackFactory: async () => callbackServer({ close }),
      isUnauthorized: (error) => error === unauthorized,
      connectionFactory: successfulFactory(unauthorized, order),
      opener: async () => {
        order.push("browser");
      },
    });

    expect(order).toEqual([
      "discover-register-authorize",
      "browser",
      "finish:auth-code",
      "authenticated-reconnect",
    ]);
    expect(committed).toHaveLength(1);
    expect(committed[0]).toMatchObject({
      clientInformation: { client_id: "new-client" },
      tokens: { access_token: "fake-access" },
      codeVerifier: "verifier",
      oauthState: "random-state",
    });
    expect(close).toHaveBeenCalledOnce();
  });

  it("rejects a callback with a wrong state before commit", async () => {
    const commit = vi.fn(async () => undefined);
    const callbackError = new Error("wrong state");
    await expect(
      runOAuthFlow({
        adapter: { commit },
        callbackFactory: async () => ({
          port: 19876,
          waitForCode: async () => {
            throw callbackError;
          },
          close: vi.fn(async () => undefined),
        }),
        connectionFactory: () => ({
          connect: () => new Promise<void>(() => undefined),
          finishAuth: vi.fn(async () => undefined),
          close: vi.fn(async () => undefined),
        }),
      }),
    ).rejects.toBe(callbackError);
    expect(commit).not.toHaveBeenCalled();
  });

  it("cancels a stalled OAuth operation before commit", async () => {
    const controller = new AbortController();
    const reason = new Error("cancelled");
    const commit = vi.fn(async () => undefined);
    const connectionClose = vi.fn(async () => undefined);
    const running = runOAuthFlow({
      adapter: { commit },
      signal: controller.signal,
      callbackFactory: async () => callbackServer(),
      connectionFactory: () => ({
        connect: () => new Promise<void>(() => undefined),
        finishAuth: vi.fn(async () => undefined),
        close: connectionClose,
      }),
    });
    controller.abort(reason);
    await expect(running).rejects.toBe(reason);
    expect(commit).not.toHaveBeenCalled();
    expect(connectionClose).toHaveBeenCalledOnce();
  });

  it("continues after a detached browser spawn", async () => {
    const unauthorized = new Error("unauthorized");
    const commit = vi.fn(async () => undefined);
    const { child, unref } = fakeChild();
    const spawn = vi.fn(() => {
      queueMicrotask(() => child.emit("spawn"));
      return child;
    }) as unknown as typeof spawnType;
    await runOAuthFlow({
      adapter: { commit },
      callbackFactory: async () => callbackServer(),
      isUnauthorized: (error) => error === unauthorized,
      connectionFactory: successfulFactory(unauthorized),
      opener: (url) =>
        openBrowser(url, {
          platform: "linux",
          spawnProcess: spawn,
          stderr: { write: vi.fn() },
        }),
    });
    expect(commit).toHaveBeenCalledOnce();
    expect(unref).toHaveBeenCalledOnce();
  });
});
