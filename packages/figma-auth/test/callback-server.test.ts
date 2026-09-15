import { createServer } from "node:http";
import { afterEach, describe, expect, it } from "vite-plus/test";
import {
  CALLBACK_TIMEOUT_MS,
  startCallbackServer,
  type CallbackServer,
} from "../src/callback-server.js";
import { CALLBACK_PATH, CALLBACK_PORT, REDIRECT_URI } from "../src/oauth-provider.js";

const openServers: CallbackServer[] = [];
afterEach(async () => Promise.all(openServers.splice(0).map((server) => server.close())));

async function request(
  server: CallbackServer,
  query: string,
  path = CALLBACK_PATH,
  method = "GET",
): Promise<Response> {
  return fetch(`http://127.0.0.1:${server.port}${path}${query}`, { method });
}

describe("OAuth callback server", () => {
  it("exposes the production callback constants", () => {
    expect(CALLBACK_PORT).toBe(19876);
    expect(REDIRECT_URI).toBe("http://127.0.0.1:19876/callback");
    expect(CALLBACK_TIMEOUT_MS).toBe(300_000);
  });

  it("accepts a code only with an exact state", async () => {
    const server = await startCallbackServer({ state: "expected", port: 0 });
    openServers.push(server);
    expect((await request(server, "?code=code-1&state=expected")).status).toBe(200);
    await expect(server.waitForCode()).resolves.toBe("code-1");
  });

  it.each([
    ["wrong state", "?code=wrong&state=unexpected", "GET"],
    ["missing state", "?code=missing", "GET"],
    ["post", "?code=posted&state=expected", "POST"],
    ["duplicate state", "?code=x&state=expected&state=expected", "GET"],
    ["duplicate code", "?code=x&code=y&state=expected", "GET"],
  ])("does not settle after a rejected %s callback", async (_name, query, method) => {
    const server = await startCallbackServer({ state: "expected", port: 0 });
    openServers.push(server);
    const waiting = server.waitForCode();
    const rejected = await request(server, query, CALLBACK_PATH, method);
    expect(rejected.status).toBe(method === "POST" ? 405 : 400);
    expect((await request(server, "?code=valid-later&state=expected")).status).toBe(200);
    await expect(waiting).resolves.toBe("valid-later");
  });

  it("rejects provider errors and cancellation", async () => {
    const server = await startCallbackServer({ state: "expected", port: 0 });
    openServers.push(server);
    const rejected = expect(server.waitForCode()).rejects.toThrow("provider error");
    expect((await request(server, "?error=access_denied&state=expected")).status).toBe(400);
    await rejected;

    const controller = new AbortController();
    const cancelled = await startCallbackServer({
      state: "other",
      port: 0,
      signal: controller.signal,
    });
    openServers.push(cancelled);
    const cancelledCode = cancelled.waitForCode();
    controller.abort(new Error("cancelled"));
    await expect(cancelledCode).rejects.toThrow("cancelled");
  });

  it("times out and reports an occupied port", async () => {
    const timeoutServer = await startCallbackServer({ state: "x", port: 0, timeoutMs: 5 });
    openServers.push(timeoutServer);
    await expect(timeoutServer.waitForCode()).rejects.toThrow("timed out");

    const occupied = createServer();
    await new Promise<void>((resolve) => occupied.listen(0, "127.0.0.1", resolve));
    const address = occupied.address();
    if (!address || typeof address === "string") throw new Error("test port unavailable");
    try {
      await expect(startCallbackServer({ state: "x", port: address.port })).rejects.toThrow(
        "EADDRINUSE",
      );
    } finally {
      await new Promise<void>((resolve, reject) =>
        occupied.close((error) => (error ? reject(error) : resolve())),
      );
    }
  });
});
