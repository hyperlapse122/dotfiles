import { chmod, lstat, mkdir } from "node:fs/promises";
import { homedir } from "node:os";
import { dirname, join } from "node:path";
import { FIGMA_SERVER_URL, type CompletedSession, type StorageAdapter } from "./types.js";

const SUPPORTED_AUTH_SCHEMA_VERSIONS = new Set([6, 7]);

export interface OmpStorageOptions {
  dbPath?: string;
  profile?: string;
  now?: () => number;
  openDatabase?: (path: string) => DatabaseLike | Promise<DatabaseLike>;
}

interface StatementLike {
  run(...params: unknown[]): unknown;
  get(...params: unknown[]): unknown;
  all(...params: unknown[]): unknown[];
}

export interface DatabaseLike {
  close(): void;
  exec(sql: string): unknown;
  prepare(sql: string): StatementLike;
  transaction(callback: () => void): () => void;
}

export function ompCredentialId(serverUrl = FIGMA_SERVER_URL, profile = "default"): string {
  return `mcp_oauth:profile:${profile}:${serverUrl}`;
}

export class OmpStorage implements StorageAdapter {
  private readonly dbPath: string;
  private readonly profile: string;
  private readonly now: () => number;
  private readonly openDatabase: (path: string) => DatabaseLike | Promise<DatabaseLike>;

  constructor(options: OmpStorageOptions = {}) {
    this.dbPath = options.dbPath ?? join(homedir(), ".omp", "agent", "agent.db");
    this.profile = options.profile ?? "default";
    this.now = options.now ?? Date.now;
    this.openDatabase = options.openDatabase ?? openBunDatabase;
  }

  async commit(session: CompletedSession): Promise<void> {
    const authDir = dirname(this.dbPath);
    await mkdir(authDir, { recursive: true, mode: 0o700 });
    const directoryStats = await lstat(authDir);
    if (directoryStats.isSymbolicLink() || !directoryStats.isDirectory()) {
      throw new Error(`Refusing unsafe omp auth directory: ${authDir}`);
    }
    const repairDirectoryMode = (directoryStats.mode & 0o7777) !== 0o700;
    const databaseExists = await existingDatabase(this.dbPath);
    const client = session.clientInformation;
    const tokens = session.tokens;
    const metadata = session.discoveryState?.authorizationServerMetadata;
    const credential: {
      type: "oauth";
      access: string;
      refresh: string;
      expires: number;
      tokenUrl?: string;
      clientId?: string;
      clientSecret?: string;
      resource?: string;
      authorizationUrl?: string;
    } = {
      type: "oauth",
      access: tokens.access_token,
      refresh: tokens.refresh_token ?? "",
      expires:
        tokens.expires_in === undefined
          ? Number.MAX_SAFE_INTEGER
          : this.now() + tokens.expires_in * 1000,
      clientId: client.client_id,
      ...(client.client_secret === undefined ? {} : { clientSecret: client.client_secret }),
      resource: FIGMA_SERVER_URL,
      ...(typeof metadata?.token_endpoint === "string"
        ? { tokenUrl: metadata.token_endpoint }
        : {}),
      ...(typeof metadata?.authorization_endpoint === "string"
        ? { authorizationUrl: metadata.authorization_endpoint }
        : {}),
    };

    const db = await this.openDatabase(this.dbPath);
    try {
      if (databaseExists) {
        validateExistingOmpSchema(db);
      } else {
        initializeNewOmpAuthSchema(db);
      }
      await secureDatabaseTarget(this.dbPath);
      if (repairDirectoryMode) await chmod(authDir, 0o700);

      db.exec("PRAGMA busy_timeout = 5000");
      db.exec("PRAGMA journal_mode = WAL");
      db.exec("PRAGMA synchronous = NORMAL");
      const provider = ompCredentialId(FIGMA_SERVER_URL, this.profile);
      const { type: credentialType, ...data } = credential;
      const replace = db.transaction(() => {
        db.prepare(
          `DELETE FROM auth_credential_blocks
           WHERE credential_id IN (SELECT id FROM auth_credentials WHERE provider = ?)`,
        ).run(provider);
        db.prepare(
          `DELETE FROM auth_credential_refresh_leases
           WHERE credential_id IN (SELECT id FROM auth_credentials WHERE provider = ?)`,
        ).run(provider);
        db.prepare("DELETE FROM auth_credentials WHERE provider = ?").run(provider);
        db.prepare(
          `INSERT INTO auth_credentials
             (provider, credential_type, data, identity_key, created_at, updated_at)
           VALUES (?, ?, ?, NULL, unixepoch(), unixepoch())`,
        ).run(provider, credentialType, JSON.stringify(data));
      });
      replace();
    } finally {
      db.close();
    }
  }
}

async function existingDatabase(path: string): Promise<boolean> {
  try {
    const stats = await lstat(path);
    if (stats.isSymbolicLink() || !stats.isFile()) {
      throw new Error(`Refusing unsafe omp auth database: ${path}`);
    }
    return true;
  } catch (error) {
    if (isErrno(error, "ENOENT")) return false;
    throw error;
  }
}

async function secureDatabaseTarget(path: string): Promise<void> {
  const stats = await lstat(path);
  if (stats.isSymbolicLink() || !stats.isFile()) {
    throw new Error(`Refusing unsafe omp auth database: ${path}`);
  }
  if ((stats.mode & 0o7777) !== 0o600) await chmod(path, 0o600);
}

function validateExistingOmpSchema(db: DatabaseLike): void {
  const versionTable = readTable(db, "auth_schema_version");
  if (!versionTable) throw new Error("Unsupported omp auth schema: version table is missing");
  requireColumns(db, "auth_schema_version", ["id", "version"]);
  const row = db.prepare("SELECT version FROM auth_schema_version WHERE id = 1").get() as
    | { version?: unknown }
    | undefined;
  if (!row || !Number.isInteger(row.version)) {
    throw new Error("Unsupported omp auth schema: version is missing or invalid");
  }
  const version = row.version as number;
  if (!SUPPORTED_AUTH_SCHEMA_VERSIONS.has(version)) {
    throw new Error(`Unsupported omp auth schema version ${String(version)}; expected 6 or 7`);
  }

  requireColumns(db, "auth_credentials", [
    "id",
    "provider",
    "credential_type",
    "data",
    "disabled_cause",
    "identity_key",
    "created_at",
    "updated_at",
  ]);
  requireColumns(db, "auth_credential_blocks", [
    "credential_id",
    "provider_key",
    "block_scope",
    "blocked_until_ms",
    "updated_at",
  ]);
  requireColumns(db, "auth_credential_refresh_leases", [
    "credential_id",
    "owner",
    "expires_at_ms",
    "updated_at",
  ]);
  if (version === 7) {
    requireColumns(db, "auth_credential_block_mirror_guard", ["credential_id"]);
  }
}

function readTable(db: DatabaseLike, name: string): boolean {
  const row = db
    .prepare("SELECT 1 AS present FROM sqlite_master WHERE type = 'table' AND name = ?")
    .get(name) as { present?: unknown } | undefined;
  return row?.present === 1;
}

function requireColumns(db: DatabaseLike, table: string, expected: readonly string[]): void {
  if (!readTable(db, table)) {
    throw new Error(`Unsupported omp auth schema: table ${table} is missing`);
  }
  const rows = db.prepare(`PRAGMA table_info(${table})`).all() as Array<{ name?: unknown }>;
  const columns = new Set(rows.map((row) => (typeof row.name === "string" ? row.name : "")));
  const missing = expected.filter((column) => !columns.has(column));
  if (missing.length > 0) {
    throw new Error(
      `Unsupported omp auth schema: table ${table} is missing ${missing.join(", ")} column(s)`,
    );
  }
}

function initializeNewOmpAuthSchema(db: DatabaseLike): void {
  db.exec(`
    CREATE TABLE auth_schema_version (
      id INTEGER PRIMARY KEY CHECK (id = 1),
      version INTEGER NOT NULL
    );
    CREATE TABLE auth_credentials (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      provider TEXT NOT NULL,
      credential_type TEXT NOT NULL,
      data TEXT NOT NULL,
      disabled_cause TEXT DEFAULT NULL,
      identity_key TEXT DEFAULT NULL,
      created_at INTEGER NOT NULL DEFAULT (unixepoch()),
      updated_at INTEGER NOT NULL DEFAULT (unixepoch())
    );
    CREATE INDEX idx_auth_provider ON auth_credentials(provider);
    CREATE INDEX idx_auth_provider_identity
      ON auth_credentials(provider, identity_key) WHERE identity_key IS NOT NULL;
    CREATE TABLE auth_credential_blocks (
      credential_id INTEGER NOT NULL,
      provider_key TEXT NOT NULL,
      block_scope TEXT NOT NULL DEFAULT '',
      blocked_until_ms INTEGER NOT NULL,
      updated_at INTEGER NOT NULL,
      PRIMARY KEY (credential_id, provider_key, block_scope)
    );
    CREATE INDEX idx_auth_credential_blocks_expires
      ON auth_credential_blocks(blocked_until_ms);
    CREATE TABLE auth_credential_refresh_leases (
      credential_id INTEGER PRIMARY KEY,
      owner TEXT NOT NULL,
      expires_at_ms INTEGER NOT NULL,
      updated_at INTEGER NOT NULL
    );
    CREATE INDEX idx_auth_credential_refresh_leases_expires
      ON auth_credential_refresh_leases(expires_at_ms);
    INSERT INTO auth_schema_version(id, version) VALUES (1, 6);
  `);
}

function isErrno(error: unknown, code: string): boolean {
  return error instanceof Error && "code" in error && error.code === code;
}

async function openBunDatabase(path: string): Promise<DatabaseLike> {
  const specifier = "bun:sqlite";
  const sqlite = (await import(specifier)) as {
    Database: new (databasePath: string) => DatabaseLike;
  };
  return new sqlite.Database(path);
}
