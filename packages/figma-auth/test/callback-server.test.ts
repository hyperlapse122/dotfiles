import { createServer } from "node:http";
import { afterEach, describe, expect, it } from "vite-plus/test";
import {
  CALLBACK_TIMEOUT_MS,
  startCallbackServer,
  type CallbackServer,
} from "../src/callback-server.js";
import { CALLBACK_PATH, CALLBACK_PORT, REDIRECT_URI } from "../src/oauth-provider.js";

const openServers: CallbackServer[] = [];
afterEach(async () => {
  await Promise.all(openServers.splice(0).map((server) => server.close()));
});

async function request(
  server: CallbackServer,
  query: string,
  path = CALLBACK_PATH,
  method = "GET",
): Promise<Response> {
  return fetch(`http://127.0.0.1:${server.port}${path}${query}`, { method });
}

describe("OAuth callback server", () => {
  it("exposes the fixed production callback constants", () => {
    expect(CALLBACK_PORT).toBe(19876);
    expect(REDIRECT_URI).toBe("http://127.0.0.1:19876/callback");
    expect(CALLBACK_TIMEOUT_MS).toBe(300_000);
  });

  it("accepts an authorization code only with an exact state", async () => {
    const server = await startCallbackServer({ state: "expected", port: 0 });
    openServers.push(server);
    const response = await request(server, "?code=code-1&state=expected");
    expect(response.status).toBe(200);
    await expect(server.waitForCode()).resolves.toBe("code-1");
  });

  it.each([
    ["?state=expected", "authorization code"],
    ["?error=access_denied&state=expected", "provider error"],
  ])("settles an exact-state terminal callback %s", async (query, message) => {
    const server = await startCallbackServer({ state: "expected", port: 0 });
    openServers.push(server);
    const rejection = expect(server.waitForCode()).rejects.toThrow(message);
    expect((await request(server, query)).status).toBe(400);
    await rejection;
  });

  it.each([
    ["wrong state", "?code=wrong&state=unexpected", "GET"],
    ["missing state", "?code=missing", "GET"],
    ["post", "?code=posted&state=expected", "POST"],
    ["duplicate state", "?code=x&state=expected&state=expected", "GET"],
    ["duplicate code", "?code=x&code=y&state=expected", "GET"],
    ["duplicate error", "?error=x&error=y&state=expected", "GET"],
  ])("does not settle after a rejected %s callback", async (_name, query, method) => {
    const server = await startCallbackServer({ state: "expected", port: 0 });
    openServers.push(server);
    const waiting = server.waitForCode();

    const rejected = await request(server, query, CALLBACK_PATH, method);
    expect(rejected.status).toBe(method === "POST" ? 405 : 400);
    if (method === "POST") expect(rejected.headers.get("allow")).toBe("GET");

    expect((await request(server, "?code=valid-later&state=expected")).status).toBe(200);
    await expect(waiting).resolves.toBe("valid-later");
  });

  it("returns 404 for unrelated paths without settling authorization", async () => {
    const controller = new AbortController();
    const server = await startCallbackServer({
      state: "expected",
      port: 0,
      signal: controller.signal,
    });
    openServers.push(server);
    const waiting = server.waitForCode();
    expect((await request(server, "", "/unrelated")).status).toBe(404);
    controller.abort();
    await expect(waiting).rejects.toThrow("cancelled");
  });

  it("rejects a pre-aborted signal before opening a listener", async () => {
    const controller = new AbortController();
    controller.abort(new Error("cancelled before startup"));
    await expect(
      startCallbackServer({ state: "x", port: 0, signal: controller.signal }),
    ).rejects.toThrow("cancelled before startup");
  });

  it("rejects cancellation during listener startup", async () => {
    const controller = new AbortController();
    const starting = startCallbackServer({ state: "x", port: 0, signal: controller.signal });
    controller.abort(new Error("cancelled during startup"));
    await expect(starting).rejects.toThrow("cancelled during startup");
  });

  it("times out", async () => {
    const timeoutServer = await startCallbackServer({ state: "x", port: 0, timeoutMs: 5 });
    openServers.push(timeoutServer);
    await expect(timeoutServer.waitForCode()).rejects.toThrow("timed out");
  });

  it("fails when its port is occupied", async () => {
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
