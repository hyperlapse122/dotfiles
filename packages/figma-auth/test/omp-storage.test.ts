import Database from "better-sqlite3";
import { chmod, lstat, mkdir, symlink, writeFile } from "node:fs/promises";
import { join } from "node:path";
import { afterEach, describe, expect, it } from "vite-plus/test";
import { OmpStorage, ompCredentialId } from "../src/storage/omp.js";
import type { CompletedSession } from "../src/storage/types.js";
import { createScratch, removeScratch } from "./helpers.js";

const scratch: string[] = [];
afterEach(async () => Promise.all(scratch.splice(0).map(removeScratch)));

function session(optional = true): CompletedSession {
  return {
    clientInformation: {
      client_id: "fake-omp-client",
      ...(optional ? { client_secret: "fake-omp-secret" } : {}),
    },
    tokens: {
      access_token: "fake-omp-access",
      token_type: "bearer",
      ...(optional ? { refresh_token: "fake-omp-refresh", expires_in: 7200, scope: "mcp" } : {}),
    },
    codeVerifier: "fake-omp-verifier",
    oauthState: "not-stored-by-omp",
    ...(optional
      ? {
          discoveryState: {
            authorizationServerUrl: "https://www.figma.com",
            authorizationServerMetadata: {
              issuer: "https://www.figma.com",
              authorization_endpoint: "https://www.figma.com/oauth/mcp",
              token_endpoint: "https://api.figma.com/v1/oauth/token",
              response_types_supported: ["code"],
            },
          },
        }
      : {}),
  };
}

async function dbPath(): Promise<string> {
  const root = await createScratch("omp");
  scratch.push(root);
  return join(root, ".omp", "agent", "agent.db");
}

const openDatabase = (path: string) => new Database(path);

async function readCredential(path: string, profile = "default") {
  const db = new Database(path, { readonly: true });
  try {
    const row = db
      .prepare(
        `SELECT credential_type, data FROM auth_credentials
         WHERE provider = ? AND disabled_cause IS NULL`,
      )
      .get(ompCredentialId("https://mcp.figma.com/mcp", profile)) as
      | { credential_type: string; data: string }
      | undefined;
    return row ? { type: row.credential_type, ...JSON.parse(row.data) } : undefined;
  } finally {
    db.close();
  }
}

describe("omp storage", () => {
  it("uses OMP's profile-scoped MCP OAuth provider id", () => {
    expect(ompCredentialId()).toBe("mcp_oauth:profile:default:https://mcp.figma.com/mcp");
  });

  it("writes a native refreshable credential to agent.db with private modes", async () => {
    const path = await dbPath();
    await new OmpStorage({
      dbPath: path,
      now: () => Date.parse("2026-07-20T12:34:56Z"),
      openDatabase,
    }).commit(session());

    expect(await readCredential(path)).toEqual({
      type: "oauth",
      access: "fake-omp-access",
      refresh: "fake-omp-refresh",
      expires: Date.parse("2026-07-20T14:34:56Z"),
      clientId: "fake-omp-client",
      clientSecret: "fake-omp-secret",
      resource: "https://mcp.figma.com/mcp",
      tokenUrl: "https://api.figma.com/v1/oauth/token",
      authorizationUrl: "https://www.figma.com/oauth/mcp",
    });
    expect((await lstat(join(path, ".."))).mode & 0o777).toBe(0o700);
    expect((await lstat(path)).mode & 0o777).toBe(0o600);
  });

  it("uses a non-expiring sentinel when the server omits expiry", async () => {
    const path = await dbPath();
    await new OmpStorage({ dbPath: path, openDatabase }).commit(session(false));
    expect(await readCredential(path)).toMatchObject({
      access: "fake-omp-access",
      refresh: "",
      expires: Number.MAX_SAFE_INTEGER,
    });
  });

  it("replaces only the selected profile credential", async () => {
    const path = await dbPath();
    await new OmpStorage({ dbPath: path, profile: "work", openDatabase }).commit(session(false));
    await new OmpStorage({ dbPath: path, openDatabase }).commit(session());
    await new OmpStorage({ dbPath: path, openDatabase }).commit({
      ...session(),
      tokens: { access_token: "fake-replacement", token_type: "bearer" },
    });

    expect(await readCredential(path)).toMatchObject({ access: "fake-replacement" });
    expect(await readCredential(path, "work")).toMatchObject({ access: "fake-omp-access" });
  });

  it("repairs an existing auth directory with an unsafe mode", async () => {
    const path = await dbPath();
    await mkdir(join(path, ".."), { recursive: true });
    await chmod(join(path, ".."), 0o755);
    await new OmpStorage({ dbPath: path, openDatabase }).commit(session(false));
    expect((await lstat(join(path, ".."))).mode & 0o7777).toBe(0o700);
  });

  it("rejects symlink directories and database targets", async () => {
    const path = await dbPath();
    const parent = join(path, "..", "..");
    const realDir = join(parent, "real-agent");
    const linkedDir = join(parent, "linked-agent");
    await mkdir(realDir, { recursive: true });
    await symlink(realDir, linkedDir);
    await expect(
      new OmpStorage({ dbPath: join(linkedDir, "agent.db"), openDatabase }).commit(session()),
    ).rejects.toThrow("unsafe omp auth directory");

    await mkdir(join(path, ".."), { recursive: true });
    const realDb = join(parent, "real.db");
    await writeFile(realDb, "unchanged");
    await symlink(realDb, path);
    await expect(new OmpStorage({ dbPath: path, openDatabase }).commit(session())).rejects.toThrow(
      "unsafe omp auth database",
    );
  });
});
