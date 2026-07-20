import { lstat, mkdir, readFile, symlink, writeFile } from "node:fs/promises";
import { join } from "node:path";
import { afterEach, describe, expect, it } from "vite-plus/test";
import { OpenCodeStorage, serverKey } from "../src/storage/opencode.js";
import type { CompletedSession } from "../src/storage/types.js";
import { createScratch, removeScratch } from "./helpers.js";

const scratch: string[] = [];
afterEach(async () => Promise.all(scratch.splice(0).map(removeScratch)));

function session(suffix = "one"): CompletedSession {
  return {
    clientInformation: {
      client_id: `fake-client-${suffix}`,
      client_secret: `fake-client-secret-${suffix}`,
      client_id_issued_at: 11,
      client_secret_expires_at: 22,
    },
    tokens: {
      access_token: `fake-access-${suffix}`,
      token_type: "bearer",
      refresh_token: `fake-refresh-${suffix}`,
      expires_in: 3600,
      scope: "mcp",
    },
    codeVerifier: `fake-verifier-${suffix}`,
    oauthState: `fake-state-${suffix}`,
  };
}

async function authPath(): Promise<string> {
  const dir = await createScratch("opencode");
  scratch.push(dir);
  return join(dir, "state", "mcp-auth.json");
}

describe("OpenCode storage", () => {
  it("derives figma from the fixed MCP hostname", () => {
    expect(serverKey("https://mcp.figma.com/mcp")).toBe("figma");
  });

  it("creates a private native auth document with exact field mapping", async () => {
    const path = await authPath();
    await new OpenCodeStorage({ path, now: () => 1_700_000_000_000 }).commit(session());
    expect(JSON.parse(await readFile(path, "utf8"))).toEqual({
      figma: {
        serverUrl: "https://mcp.figma.com/mcp",
        clientInfo: {
          clientId: "fake-client-one",
          clientSecret: "fake-client-secret-one",
          clientIdIssuedAt: 11,
          clientSecretExpiresAt: 22,
        },
        tokens: {
          accessToken: "fake-access-one",
          refreshToken: "fake-refresh-one",
          expiresAt: 1_700_003_600,
        },
      },
      Figma: { oauthState: "fake-state-one", codeVerifier: "fake-verifier-one" },
    });
    expect((await lstat(path)).mode & 0o777).toBe(0o600);
  });

  it("replaces only figma and Figma while preserving unrelated raw bytes", async () => {
    const path = await authPath();
    await mkdir(join(path, ".."), { recursive: true });
    const sentinel = '"other" : { "keep" : [ 1, 2, 3 ], "text": "byte sentinel" }';
    const original = `{
  // keep this comment and formatting
  ${sentinel},
  "figma": { "old": true },
  "Figma": { "oldState": true },
  "tail": {"untouched":true}
}\n`;
    await writeFile(path, original);
    const storage = new OpenCodeStorage({ path, now: () => 0 });
    await storage.commit(session("two"));
    const once = await readFile(path, "utf8");
    expect(once).toContain(sentinel);
    expect(once).toContain('"tail": {"untouched":true}');
    expect(once).toContain("keep this comment and formatting");
    expect(once).not.toContain('"old": true');
    expect(once).toContain("fake-access-two");

    await storage.commit(session("three"));
    const twice = await readFile(path, "utf8");
    expect(twice).toContain(sentinel);
    expect(twice).toContain('"tail": {"untouched":true}');
    expect(twice).not.toContain("fake-access-two");
    expect(twice).toContain("fake-access-three");
  });

  it.each([
    ["malformed", "{not json", "malformed JSON"],
    ["non-object", "[]\n", "must contain an object"],
    ["duplicate figma", '{"figma":{},"figma":{}}\n', "duplicate figma"],
    ["duplicate Figma", '{"Figma":{},"Figma":{}}\n', "duplicate Figma"],
    ["duplicate unrelated key", '{"other":{},"other":{"keep":true}}\n', "duplicate other"],
  ])("rejects %s input without mutation", async (_name, source, message) => {
    const path = await authPath();
    await mkdir(join(path, ".."), { recursive: true });
    await writeFile(path, source);
    await expect(new OpenCodeStorage({ path }).commit(session())).rejects.toThrow(message);
    expect(await readFile(path, "utf8")).toBe(source);
  });

  it("preserves a concurrent server update by aborting before promotion", async () => {
    const path = await authPath();
    await mkdir(join(path, ".."), { recursive: true });
    const original = '{"other":{"value":"before"},"figma":{"old":true}}\n';
    const concurrent = '{"other":{"value":"concurrent"},"figma":{"old":true}}\n';
    await writeFile(path, original);
    const barrier = Promise.withResolvers<void>();
    const release = Promise.withResolvers<void>();
    const commit = new OpenCodeStorage({
      path,
      beforeSourceRevalidation: async () => {
        barrier.resolve();
        await release.promise;
      },
    }).commit(session());

    await barrier.promise;
    await writeFile(path, concurrent);
    release.resolve();

    await expect(commit).rejects.toThrow("changed during update");
    expect(await readFile(path, "utf8")).toBe(concurrent);
  });

  it("rejects symlink and non-regular targets without mutation", async () => {
    const path = await authPath();
    await mkdir(join(path, ".."), { recursive: true });
    const real = join(path, "..", "real.json");
    await writeFile(real, '{"other":true}\n');
    await symlink(real, path);
    await expect(new OpenCodeStorage({ path }).commit(session())).rejects.toThrow("symlink");
    expect(await readFile(real, "utf8")).toBe('{"other":true}\n');

    const directoryTarget = join(path, "..", "directory.json");
    await mkdir(directoryTarget);
    await expect(new OpenCodeStorage({ path: directoryTarget }).commit(session())).rejects.toThrow(
      "non-regular",
    );
  });
});
