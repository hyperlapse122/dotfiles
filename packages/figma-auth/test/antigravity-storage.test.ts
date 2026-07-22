import { lstat, mkdir, readFile, symlink, writeFile } from "node:fs/promises";
import { join } from "node:path";
import { afterEach, describe, expect, it } from "vite-plus/test";
import { AntigravityStorage } from "../src/storage/antigravity.js";
import { FIGMA_SERVER_URL } from "../src/storage/types.js";
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
  const dir = await createScratch("antigravity");
  scratch.push(dir);
  return join(dir, ".gemini", "antigravity-cli", "mcp_oauth_tokens.json");
}

describe("Antigravity storage", () => {
  it("creates a private native token document keyed by the full figma URL", async () => {
    const path = await authPath();
    // 2026-07-22T10:34:56Z + 3600s expiry -> 11:34:56Z
    await new AntigravityStorage({
      path,
      now: () => Date.parse("2026-07-22T10:34:56Z"),
    }).commit(session());
    expect(JSON.parse(await readFile(path, "utf8"))).toEqual({
      [FIGMA_SERVER_URL]: {
        client_id: "fake-client-one",
        client_secret: "fake-client-secret-one",
        token: {
          access_token: "fake-access-one",
          token_type: "bearer",
          refresh_token: "fake-refresh-one",
          expiry: "2026-07-22T11:34:56.000Z",
        },
      },
    });
    expect((await lstat(path)).mode & 0o777).toBe(0o600);
  });

  it("replaces only the figma URL key while preserving unrelated raw bytes", async () => {
    const path = await authPath();
    await mkdir(join(path, ".."), { recursive: true });
    const sentinel = '"https://other.example/mcp" : { "keep" : [ 1, 2, 3 ] }';
    const original = `{
  // keep this comment and formatting
  ${sentinel},
  "${FIGMA_SERVER_URL}": { "old": true },
  "tail": {"untouched":true}
}\n`;
    await writeFile(path, original);
    const storage = new AntigravityStorage({ path, now: () => 0 });
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
    ["duplicate figma URL", `{"${FIGMA_SERVER_URL}":{},"${FIGMA_SERVER_URL}":{}}\n`, "duplicate"],
    ["duplicate unrelated key", '{"other":{},"other":{"keep":true}}\n', "duplicate other"],
  ])("rejects %s input without mutation", async (_name, source, message) => {
    const path = await authPath();
    await mkdir(join(path, ".."), { recursive: true });
    await writeFile(path, source);
    await expect(new AntigravityStorage({ path }).commit(session())).rejects.toThrow(message);
    expect(await readFile(path, "utf8")).toBe(source);
  });

  it("defaults token_type to bearer and omits optional token fields when absent", async () => {
    const path = await authPath();
    const minimal: CompletedSession = {
      clientInformation: { client_id: "public-client" },
      tokens: { access_token: "bare-access", token_type: "bearer" },
      codeVerifier: "v",
      oauthState: "s",
    };
    await new AntigravityStorage({ path, now: () => 0 }).commit(minimal);
    expect(JSON.parse(await readFile(path, "utf8"))).toEqual({
      [FIGMA_SERVER_URL]: {
        client_id: "public-client",
        token: { access_token: "bare-access", token_type: "bearer" },
      },
    });
  });

  it("preserves a concurrent server update by aborting before promotion", async () => {
    const path = await authPath();
    await mkdir(join(path, ".."), { recursive: true });
    const original = '{"other":{"value":"before"}}\n';
    const concurrent = '{"other":{"value":"concurrent"}}\n';
    await writeFile(path, original);
    const barrier = Promise.withResolvers<void>();
    const release = Promise.withResolvers<void>();
    const commit = new AntigravityStorage({
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
    await expect(new AntigravityStorage({ path }).commit(session())).rejects.toThrow("symlink");
    expect(await readFile(real, "utf8")).toBe('{"other":true}\n');

    const directoryTarget = join(path, "..", "directory.json");
    await mkdir(directoryTarget);
    await expect(
      new AntigravityStorage({ path: directoryTarget }).commit(session()),
    ).rejects.toThrow("non-regular");
  });
});
