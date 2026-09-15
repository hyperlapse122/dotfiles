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
  const root = await createScratch("sqlite-auth");
  scratch.push(root);
  return join(root, ".omp", "agent", "agent.db");
}

const openDatabase = (path: string) => new Database(path);

function readCredential(path: string, profile = "default") {
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

function readSchemaVersion(path: string): number | undefined {
  const db = new Database(path, { readonly: true });
  try {
    return (
      db.prepare("SELECT version FROM auth_schema_version WHERE id = 1").get() as
        | { version?: number }
        | undefined
    )?.version;
  } finally {
    db.close();
  }
}

function updateSchemaVersion(path: string, version: number): void {
  const db = new Database(path);
  try {
    db.prepare("UPDATE auth_schema_version SET version = ? WHERE id = 1").run(version);
  } finally {
    db.close();
  }
}

function tableExists(path: string, table: string): boolean {
  const db = new Database(path, { readonly: true });
  try {
    return Boolean(
      (
        db
          .prepare("SELECT 1 AS present FROM sqlite_master WHERE type = 'table' AND name = ?")
          .get(table) as { present?: number } | undefined
      )?.present,
    );
  } finally {
    db.close();
  }
}

describe("omp storage", () => {
  it("uses the profile-scoped MCP OAuth provider id", () => {
    expect(ompCredentialId()).toBe("mcp_oauth:profile:default:https://mcp.figma.com/mcp");
  });

  it("writes a native refreshable credential with private modes", async () => {
    const path = await dbPath();
    await new OmpStorage({
      dbPath: path,
      now: () => Date.parse("2026-07-20T12:34:56Z"),
      openDatabase,
    }).commit(session());

    expect(readCredential(path)).toEqual({
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
    expect(readSchemaVersion(path)).toBe(6);
    expect(tableExists(path, "auth_credential_block_mirror_guard")).toBe(false);
  });

  it("uses a non-expiring sentinel when the server omits expiry", async () => {
    const path = await dbPath();
    await new OmpStorage({ dbPath: path, openDatabase }).commit(session(false));
    expect(readCredential(path)).toMatchObject({
      access: "fake-omp-access",
      refresh: "",
      expires: Number.MAX_SAFE_INTEGER,
    });
  });

  it("replaces only the selected profile and preserves other providers", async () => {
    const path = await dbPath();
    await new OmpStorage({ dbPath: path, profile: "work", openDatabase }).commit(session(false));
    const db = new Database(path);
    db.prepare(
      `INSERT INTO auth_credentials
       (provider, credential_type, data, identity_key, created_at, updated_at)
       VALUES (?, 'api_key', ?, NULL, unixepoch(), unixepoch())`,
    ).run("other-provider", JSON.stringify({ key: "other-secret" }));
    db.close();

    await new OmpStorage({ dbPath: path, openDatabase }).commit(session());
    await new OmpStorage({ dbPath: path, openDatabase }).commit({
      ...session(),
      tokens: { access_token: "fake-replacement", token_type: "bearer" },
    });

    expect(readCredential(path)).toMatchObject({ access: "fake-replacement" });
    expect(readCredential(path, "work")).toMatchObject({ access: "fake-omp-access" });
    const storedDb = new Database(path, { readonly: true });
    try {
      const stored = storedDb
        .prepare("SELECT data FROM auth_credentials WHERE provider = 'other-provider'")
        .get() as { data: string } | undefined;
      expect(stored && JSON.parse(stored.data)).toEqual({ key: "other-secret" });
    } finally {
      storedDb.close();
    }
  });

  it("supports an existing schema 7 without changing its version or mirror table", async () => {
    const path = await dbPath();
    await new OmpStorage({ dbPath: path, openDatabase }).commit(session(false));
    const db = new Database(path);
    db.exec(`
      UPDATE auth_schema_version SET version = 7;
      CREATE TABLE auth_credential_block_mirror_guard (
        credential_id INTEGER PRIMARY KEY
      ) WITHOUT ROWID;
    `);
    db.close();

    await new OmpStorage({ dbPath: path, openDatabase }).commit(session());
    expect(readSchemaVersion(path)).toBe(7);
    expect(tableExists(path, "auth_credential_block_mirror_guard")).toBe(true);
    expect(readCredential(path)).toMatchObject({ access: "fake-omp-access" });
  });

  it.each([5, 8])("rejects unsupported schema %s before replacing credentials", async (version) => {
    const path = await dbPath();
    await new OmpStorage({ dbPath: path, openDatabase }).commit(session(false));
    const before = readCredential(path);
    updateSchemaVersion(path, version);

    await expect(
      new OmpStorage({ dbPath: path, openDatabase }).commit({
        ...session(false),
        tokens: { access_token: "must-not-write", token_type: "bearer" },
      }),
    ).rejects.toThrow(`Unsupported omp auth schema version ${version}`);
    expect(readSchemaVersion(path)).toBe(version);
    expect(readCredential(path)).toEqual(before);
  });

  it("rolls back a failed replacement and preserves the valid credential", async () => {
    const path = await dbPath();
    await new OmpStorage({ dbPath: path, openDatabase }).commit(session(false));
    const before = readCredential(path);
    const db = new Database(path);
    db.exec(`
      CREATE TRIGGER fail_figma_insert
      BEFORE INSERT ON auth_credentials
      WHEN NEW.provider = '${ompCredentialId()}'
      BEGIN SELECT RAISE(ABORT, 'injected insert failure'); END;
    `);
    db.close();

    await expect(
      new OmpStorage({ dbPath: path, openDatabase }).commit({
        ...session(false),
        tokens: { access_token: "must-not-write", token_type: "bearer" },
      }),
    ).rejects.toThrow("injected insert failure");
    expect(readCredential(path)).toEqual(before);
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
