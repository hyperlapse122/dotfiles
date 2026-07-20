import { chmod, lstat, mkdir, readFile, readdir, symlink, writeFile } from "node:fs/promises";
import { join } from "node:path";
import { afterEach, describe, expect, it } from "vite-plus/test";
import { PiStorage, piCredentialFilename } from "../src/storage/pi.js";
import type { CompletedSession } from "../src/storage/types.js";
import { createScratch, removeScratch } from "./helpers.js";

const scratch: string[] = [];
afterEach(async () => Promise.all(scratch.splice(0).map(removeScratch)));

function session(optional = true): CompletedSession {
  return {
    clientInformation: {
      client_id: "fake-pi-client",
      ...(optional
        ? {
            client_secret: "fake-pi-secret",
            client_id_issued_at: 1_721_234_567,
            client_secret_expires_at: 1_799_999_999,
          }
        : {}),
    },
    tokens: {
      access_token: "fake-pi-access",
      token_type: "bearer",
      ...(optional
        ? {
            refresh_token: "fake-pi-refresh",
            expires_in: 7200,
            scope: "mcp",
          }
        : {}),
    },
    codeVerifier: "fake-pi-verifier",
    oauthState: "not-stored-by-pi",
    ...(optional
      ? {
          discoveryState: {
            authorizationServerUrl: "https://www.figma.com",
          },
        }
      : {}),
  };
}

async function authDir(): Promise<string> {
  const root = await createScratch("pi");
  scratch.push(root);
  return join(root, ".pi", "agent", "mcp-auth");
}

describe("pi storage", () => {
  it("uses the deterministic first 16 hex characters of sha256(figma)", () => {
    expect(piCredentialFilename()).toBe("5b79d0d574eedd09.json");
  });

  it("writes the exact native envelope, relative expiry, discovery, and private modes", async () => {
    const dir = await authDir();
    const storage = new PiStorage({ authDir: dir, now: () => Date.parse("2026-07-20T12:34:56Z") });
    await storage.commit(session());
    const path = join(dir, piCredentialFilename());
    expect(JSON.parse(await readFile(path, "utf8"))).toEqual({
      clientInfo: {
        client_id: "fake-pi-client",
        client_secret: "fake-pi-secret",
        client_id_issued_at: 1_721_234_567,
        client_secret_expires_at: 1_799_999_999,
      },
      tokens: {
        access_token: "fake-pi-access",
        token_type: "bearer",
        refresh_token: "fake-pi-refresh",
        expires_in: 7200,
        scope: "mcp",
        saved_at: "2026-07-20T12:34:56.000Z",
      },
      codeVerifier: "fake-pi-verifier",
      discoveryState: {
        authorizationServerUrl: "https://www.figma.com",
      },
    });
    expect((await lstat(dir)).mode & 0o777).toBe(0o700);
    expect((await lstat(path)).mode & 0o777).toBe(0o600);
  });

  it("repairs an existing auth directory with an unsafe mode", async () => {
    const dir = await authDir();
    await mkdir(dir, { recursive: true });
    await chmod(dir, 0o755);

    await new PiStorage({ authDir: dir, now: () => 0 }).commit(session(false));

    expect((await lstat(dir)).mode & 0o7777).toBe(0o700);
  });

  it("omits undefined optional fields and injects saved_at once", async () => {
    const dir = await authDir();
    await new PiStorage({ authDir: dir, now: () => 0 }).commit(session(false));
    const output = await readFile(join(dir, piCredentialFilename()), "utf8");
    expect(JSON.parse(output)).toEqual({
      clientInfo: { client_id: "fake-pi-client" },
      tokens: {
        access_token: "fake-pi-access",
        token_type: "bearer",
        saved_at: "1970-01-01T00:00:00.000Z",
      },
      codeVerifier: "fake-pi-verifier",
    });
    expect(output.match(/saved_at/g)).toHaveLength(1);
  });

  it("replaces only the figma-specific file", async () => {
    const dir = await authDir();
    await mkdir(dir, { recursive: true });
    const other = join(dir, "other-server.json");
    await writeFile(other, "other bytes\n");
    const storage = new PiStorage({ authDir: dir, now: () => 0 });
    await storage.commit(session(false));
    await storage.commit({
      ...session(false),
      tokens: { access_token: "fake-replacement", token_type: "bearer" },
    });
    expect(await readFile(other, "utf8")).toBe("other bytes\n");
    expect(await readFile(join(dir, piCredentialFilename()), "utf8")).toContain("fake-replacement");
    expect((await readdir(dir)).sort()).toEqual([piCredentialFilename(), "other-server.json"]);
  });

  it.each([
    ["malformed", "{broken", "malformed JSON"],
    ["non-object", "[]", "must contain an object"],
  ])("rejects an existing %s target without mutation", async (_name, source, message) => {
    const dir = await authDir();
    await mkdir(dir, { recursive: true });
    const path = join(dir, piCredentialFilename());
    await writeFile(path, source);
    await expect(new PiStorage({ authDir: dir }).commit(session())).rejects.toThrow(message);
    expect(await readFile(path, "utf8")).toBe(source);
  });

  it("rejects symlink and non-regular credential targets", async () => {
    const dir = await authDir();
    await mkdir(dir, { recursive: true });
    const real = join(dir, "real.json");
    await writeFile(real, "{}\n");
    await symlink(real, join(dir, piCredentialFilename()));
    await expect(new PiStorage({ authDir: dir }).commit(session())).rejects.toThrow("symlink");
    expect(await readFile(real, "utf8")).toBe("{}\n");

    const secondDir = await authDir();
    await mkdir(join(secondDir, piCredentialFilename()), { recursive: true });
    await expect(new PiStorage({ authDir: secondDir }).commit(session())).rejects.toThrow(
      "non-regular",
    );
  });

  it("rejects a symlink auth directory", async () => {
    const dir = await authDir();
    const parent = join(dir, "..");
    const real = join(parent, "real-auth");
    const link = join(parent, "linked-auth");
    await mkdir(real, { recursive: true });
    await symlink(real, link);
    await expect(new PiStorage({ authDir: link }).commit(session())).rejects.toThrow(
      "unsafe pi auth directory",
    );
  });
});
