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
  options: {
    code?: string;
    close?: () => Promise<void>;
  } = {},
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
  it("begins empty and exposes the known-working Figma client identity", () => {
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
  it("performs fresh DCR/PKCE, reconnects, then commits exactly once", async () => {
    const order: string[] = [];
    const committed: CompletedSession[] = [];
    const unauthorized = new Error("unauthorized");
    const close = vi.fn(async () => undefined);

    await runOAuthFlow({
      adapter: {
        commit: async (session) => {
          order.push("commit");
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
      "commit",
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

  it("continues OAuth after a detached browser opener spawns but never exits", async () => {
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

  it("interrupts a stalled initial connection when the callback rejects", async () => {
    const callbackError = new Error("OAuth callback timed out");
    const commit = vi.fn(async () => undefined);
    const connectionClose = vi.fn(async () => undefined);
    const callbackClose = vi.fn(async () => undefined);

    await expect(
      runOAuthFlow({
        adapter: { commit },
        randomState: () => "state",
        callbackFactory: async () => ({
          port: 19876,
          waitForCode: async () => {
            throw callbackError;
          },
          close: callbackClose,
        }),
        connectionFactory: () => ({
          connect: () => new Promise<void>(() => undefined),
          finishAuth: vi.fn(async () => undefined),
          close: connectionClose,
        }),
      }),
    ).rejects.toBe(callbackError);

    expect(commit).not.toHaveBeenCalled();
    expect(connectionClose).toHaveBeenCalledOnce();
    expect(callbackClose).toHaveBeenCalledOnce();
  });

  it.each(["initial", "finish", "reconnect"] as const)(
    "commits zero times on %s failure and cleans up",
    async (failure) => {
      const unauthorized = new Error("unauthorized");
      const commit = vi.fn(async () => undefined);
      const close = vi.fn(async () => undefined);
      let number = 0;
      await expect(
        runOAuthFlow({
          adapter: { commit },
          randomState: () => "state",
          callbackFactory: async () => callbackServer({ close }),
          isUnauthorized: (error) => error === unauthorized,
          opener: vi.fn(async () => undefined),
          connectionFactory: (provider) => {
            number += 1;
            const current = number;
            return {
              connect: async () => {
                if (current === 1) {
                  if (failure === "initial") throw new Error("initial failed");
                  provider.saveClientInformation({ client_id: "client" });
                  provider.saveCodeVerifier("verifier");
                  throw unauthorized;
                }
                if (failure === "reconnect") throw new Error("reconnect failed");
              },
              finishAuth: async () => {
                if (failure === "finish") throw new Error("finish failed");
                provider.saveTokens({ access_token: "access", token_type: "bearer" });
              },
              close: vi.fn(async () => undefined),
            };
          },
        }),
      ).rejects.toThrow(`${failure} failed`);
      expect(commit).not.toHaveBeenCalled();
      expect(close).toHaveBeenCalledOnce();
    },
  );

  it("rejects pre-abort without starting callback or committing", async () => {
    const controller = new AbortController();
    const reason = new Error("pre-aborted");
    controller.abort(reason);
    const callbackFactory = vi.fn(async () => callbackServer());
    const commit = vi.fn(async () => undefined);

    await expect(
      runOAuthFlow({ adapter: { commit }, callbackFactory, signal: controller.signal }),
    ).rejects.toBe(reason);
    expect(callbackFactory).not.toHaveBeenCalled();
    expect(commit).not.toHaveBeenCalled();
  });

  it("cancels stalled callback startup before constructing a connection", async () => {
    const controller = new AbortController();
    const reason = new Error("abort during callback startup");
    const commit = vi.fn(async () => undefined);
    const connectionFactory = vi.fn();
    const running = runOAuthFlow({
      adapter: { commit },
      signal: controller.signal,
      callbackFactory: () => new Promise<CallbackServer>(() => undefined),
      connectionFactory,
    });

    controller.abort(reason);
    await expect(running).rejects.toBe(reason);
    expect(connectionFactory).not.toHaveBeenCalled();
    expect(commit).not.toHaveBeenCalled();
  });

  it.each(["finishAuth", "reconnect"] as const)(
    "cancels a stalled %s before commit",
    async (phase) => {
      const controller = new AbortController();
      const reason = new Error(`abort during ${phase}`);
      const unauthorized = new Error("unauthorized");
      const commit = vi.fn(async () => undefined);
      let number = 0;

      await expect(
        runOAuthFlow({
          adapter: { commit },
          signal: controller.signal,
          callbackFactory: async () => callbackServer(),
          isUnauthorized: (error) => error === unauthorized,
          connectionFactory: (provider) => {
            number += 1;
            const current = number;
            return {
              connect: async () => {
                if (current === 1) {
                  provider.saveClientInformation({ client_id: "client" });
                  provider.saveCodeVerifier("verifier");
                  throw unauthorized;
                }
                controller.abort(reason);
                return new Promise<void>(() => undefined);
              },
              finishAuth: async () => {
                if (phase === "finishAuth") {
                  controller.abort(reason);
                  return new Promise<void>(() => undefined);
                }
                provider.saveTokens({ access_token: "access", token_type: "bearer" });
              },
              close: vi.fn(async () => undefined),
            };
          },
        }),
      ).rejects.toBe(reason);
      expect(commit).not.toHaveBeenCalled();
    },
  );

  it.each(["first", "retry"] as const)(
    "cleans up when the %s connection factory construction throws",
    async (which) => {
      const unauthorized = new Error("unauthorized");
      const factoryError = new Error(`${which} factory failed`);
      const callbackClose = vi.fn(async () => undefined);
      const firstClose = vi.fn(async () => undefined);
      const commit = vi.fn(async () => undefined);
      let calls = 0;

      await expect(
        runOAuthFlow({
          adapter: { commit },
          callbackFactory: async () => callbackServer({ close: callbackClose }),
          isUnauthorized: (error) => error === unauthorized,
          connectionFactory: (provider) => {
            calls += 1;
            if (which === "first" || calls === 2) throw factoryError;
            return {
              connect: async () => {
                provider.saveClientInformation({ client_id: "client" });
                provider.saveCodeVerifier("verifier");
                throw unauthorized;
              },
              finishAuth: async () => {
                provider.saveTokens({ access_token: "access", token_type: "bearer" });
              },
              close: firstClose,
            };
          },
        }),
      ).rejects.toBe(factoryError);

      expect(callbackClose).toHaveBeenCalledOnce();
      expect(firstClose).toHaveBeenCalledTimes(which === "retry" ? 1 : 0);
      expect(commit).not.toHaveBeenCalled();
    },
  );

  it("does not let callback cleanup rejection mask the primary error", async () => {
    const primary = new Error("primary OAuth failure");
    const commit = vi.fn(async () => undefined);
    await expect(
      runOAuthFlow({
        adapter: { commit },
        callbackFactory: async () =>
          callbackServer({ close: async () => Promise.reject(new Error("close failed")) }),
        connectionFactory: () => ({
          connect: async () => {
            throw primary;
          },
          finishAuth: vi.fn(async () => undefined),
          close: vi.fn(async () => undefined),
        }),
      }),
    ).rejects.toBe(primary);
    expect(commit).not.toHaveBeenCalled();
  });

  it("reports callback cleanup failure clearly after credentials were committed", async () => {
    const unauthorized = new Error("unauthorized");
    const commit = vi.fn(async () => undefined);
    await expect(
      runOAuthFlow({
        adapter: { commit },
        callbackFactory: async () =>
          callbackServer({ close: async () => Promise.reject(new Error("close failed")) }),
        isUnauthorized: (error) => error === unauthorized,
        connectionFactory: successfulFactory(unauthorized),
        opener: vi.fn(async () => undefined),
      }),
    ).rejects.toThrow("credentials were committed, but the OAuth callback server failed to close");
    expect(commit).toHaveBeenCalledOnce();
  });

  it("does not cancel persistence after the commit point begins", async () => {
    const unauthorized = new Error("unauthorized");
    const controller = new AbortController();
    const commit = vi.fn(async () => {
      controller.abort(new Error("late abort"));
      await Promise.resolve();
    });

    await runOAuthFlow({
      adapter: { commit },
      signal: controller.signal,
      callbackFactory: async () => callbackServer(),
      isUnauthorized: (error) => error === unauthorized,
      connectionFactory: successfulFactory(unauthorized),
      opener: vi.fn(async () => undefined),
    });
    expect(commit).toHaveBeenCalledOnce();
  });

  it("does not launch a browser or commit when callback startup fails", async () => {
    const opener = vi.fn(async () => undefined);
    const commit = vi.fn(async () => undefined);
    await expect(
      runOAuthFlow({
        adapter: { commit },
        opener,
        callbackFactory: async () => {
          throw new Error("EADDRINUSE");
        },
      }),
    ).rejects.toThrow("EADDRINUSE");
    expect(opener).not.toHaveBeenCalled();
    expect(commit).not.toHaveBeenCalled();
  });
});

describe("browser opening", () => {
  it.each([
    ["linux", "xdg-open"],
    ["darwin", "open"],
  ] as const)(
    "uses and detaches the %s opener %s without printing the URL",
    async (platform, expectedCommand) => {
      const { child, unref } = fakeChild();
      const spawn = vi.fn(() => {
        queueMicrotask(() => child.emit("spawn"));
        return child;
      }) as unknown as typeof spawnType;
      const write = vi.fn();
      await openBrowser(new URL("https://example.invalid/auth"), {
        platform,
        spawnProcess: spawn,
        stderr: { write },
      });
      expect(spawn).toHaveBeenCalledWith(expectedCommand, ["https://example.invalid/auth"], {
        detached: true,
        stdio: "ignore",
      });
      expect(unref).toHaveBeenCalledOnce();
      expect(write).not.toHaveBeenCalled();
    },
  );

  it("prints the full URL when a detached opener later exits nonzero", async () => {
    const { child } = fakeChild();
    const spawn = vi.fn(() => {
      queueMicrotask(() => child.emit("spawn"));
      return child;
    }) as unknown as typeof spawnType;
    const write = vi.fn();
    await openBrowser(new URL("https://example.invalid/auth?full=value"), {
      platform: "linux",
      spawnProcess: spawn,
      stderr: { write },
    });
    child.emit("exit", 1, null);
    expect(write).toHaveBeenCalledWith(
      expect.stringContaining("https://example.invalid/auth?full=value"),
    );
  });

  it("prints the URL and rejects an immediate spawn failure", async () => {
    const { child } = fakeChild();
    const spawn = vi.fn(() => {
      queueMicrotask(() => child.emit("error", new Error("ENOENT")));
      return child;
    }) as unknown as typeof spawnType;
    const write = vi.fn();
    await expect(
      openBrowser(new URL("https://example.invalid/auth"), {
        platform: "linux",
        spawnProcess: spawn,
        stderr: { write },
      }),
    ).rejects.toThrow("Could not launch xdg-open: ENOENT");
    expect(write).toHaveBeenCalledWith(expect.stringContaining("https://example.invalid/auth"));
  });

  it("prints the URL and rejects unsupported platforms", async () => {
    const write = vi.fn();
    await expect(
      openBrowser(new URL("https://example.invalid/auth"), {
        platform: "win32",
        stderr: { write },
      }),
    ).rejects.toThrow("Unsupported platform");
    expect(write).toHaveBeenCalledWith(expect.stringContaining("https://example.invalid/auth"));
  });
});
