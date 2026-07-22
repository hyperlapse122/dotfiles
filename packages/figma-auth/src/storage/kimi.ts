import { createHash } from "node:crypto";
import { chmod, lstat, mkdir, unlink } from "node:fs/promises";
import { homedir } from "node:os";
import { basename, join, parse, resolve, sep } from "node:path";
import { atomicPrivateWrite, readRegularFileIfExists } from "./atomic.js";
import {
  FIGMA_SERVER_NAME,
  FIGMA_SERVER_URL,
  type CompletedSession,
  type StorageAdapter,
} from "./types.js";

const CREDENTIAL_SUFFIXES = ["client", "tokens", "discovery"] as const;
type CredentialSuffix = (typeof CREDENTIAL_SUFFIXES)[number];

interface Snapshot {
  path: string;
  suffix: CredentialSuffix;
  source: string | undefined;
  output: string;
}

interface RecoveryDocument {
  version: 1;
  files: Array<{ suffix: CredentialSuffix; source: string | null; output: string }>;
}

export interface KimiStorageOptions {
  home?: string;
  beforeSourceRevalidation?: () => Promise<void>;
  afterPromote?: (path: string, index: number) => Promise<void>;
}

export function canonicalKimiMcpResource(serverUrl: string | URL): string {
  const url = new URL(serverUrl);
  url.hash = "";
  return url.toString();
}

export function kimiMcpOAuthStoreKey(serverName: string, serverUrl: string | URL): string {
  const safeName = basename(serverName)
    .replaceAll(/[^a-zA-Z0-9_-]/g, "_")
    .replaceAll(/_+/g, "_");
  if (safeName.length === 0 || safeName.startsWith(".")) {
    throw new Error("Invalid Kimi MCP OAuth store key");
  }
  const digest = createHash("sha256")
    .update(serverName)
    .update("\0")
    .update(canonicalKimiMcpResource(serverUrl))
    .digest("hex")
    .slice(0, 24);
  return `${safeName}-${digest}`;
}

export const KIMI_FIGMA_STORE_KEY = kimiMcpOAuthStoreKey(FIGMA_SERVER_NAME, FIGMA_SERVER_URL);

export class KimiStorage implements StorageAdapter {
  private readonly home: string;
  private readonly beforeSourceRevalidation: (() => Promise<void>) | undefined;
  private readonly afterPromote: ((path: string, index: number) => Promise<void>) | undefined;

  constructor(options: KimiStorageOptions = {}) {
    this.home = options.home ?? process.env.KIMI_CODE_HOME ?? join(homedir(), ".kimi-code");
    this.beforeSourceRevalidation = options.beforeSourceRevalidation;
    this.afterPromote = options.afterPromote;
  }

  async commit(session: CompletedSession): Promise<void> {
    const directory = await ensurePrivateCredentialDirectory(this.home);
    const recoveryPath = join(directory, `.${KIMI_FIGMA_STORE_KEY}-transaction.json`);
    await recoverInterruptedTransaction(directory, recoveryPath);

    const documents: Array<[CredentialSuffix, unknown]> = [
      ["client", session.clientInformation],
      ["tokens", session.tokens],
      ...(session.discoveryState === undefined
        ? []
        : ([["discovery", session.discoveryState]] as Array<[CredentialSuffix, unknown]>)),
    ];
    const snapshots = await Promise.all(
      documents.map(async ([suffix, value]) => {
        const path = credentialPath(directory, suffix);
        const source = await readValidatedDocument(path);
        return {
          path,
          suffix,
          source,
          output: `${JSON.stringify(value, null, 2)}\n`,
        } satisfies Snapshot;
      }),
    );

    await this.beforeSourceRevalidation?.();
    await assertSourcesUnchanged(snapshots);
    const recovery: RecoveryDocument = {
      version: 1,
      files: snapshots.map((snapshot) => ({
        suffix: snapshot.suffix,
        source: snapshot.source ?? null,
        output: snapshot.output,
      })),
    };
    await atomicPrivateWrite(recoveryPath, `${JSON.stringify(recovery)}\n`);

    let promoted = 0;
    try {
      for (const [index, snapshot] of snapshots.entries()) {
        const expected = index < promoted ? snapshot.output : snapshot.source;
        if ((await readRegularFileIfExists(snapshot.path)) !== expected) {
          throw new Error("Kimi credential changed during update; refusing to overwrite it");
        }
        await atomicPrivateWrite(snapshot.path, snapshot.output);
        promoted += 1;
        await this.afterPromote?.(snapshot.path, promoted);
      }
      try {
        await unlink(recoveryPath);
      } catch (error) {
        if (!hasErrorCode(error, "ENOENT")) throw error;
      }
    } catch (error) {
      // Only files promoted by this transaction belong to its rollback. An
      // unpromoted file may contain a concurrent writer's newer generation.
      const rollbackFailures = await restoreSnapshots(snapshots.slice(0, promoted));
      if (rollbackFailures.length === 0) {
        try {
          await unlink(recoveryPath);
        } catch (cleanupError) {
          if (!hasErrorCode(cleanupError, "ENOENT")) rollbackFailures.push(cleanupError);
        }
      }
      const failure = new Error(
        rollbackFailures.length === 0
          ? "Kimi credential transaction failed; the previous generation was restored"
          : "Kimi credential transaction failed and rollback was incomplete",
        { cause: error },
      );
      if (rollbackFailures.length > 0) {
        throw new AggregateError([failure, ...rollbackFailures], failure.message, {
          cause: failure,
        });
      }
      throw failure;
    }
  }
}

function credentialPath(directory: string, suffix: CredentialSuffix): string {
  return join(directory, `${KIMI_FIGMA_STORE_KEY}-${suffix}.json`);
}

async function ensurePrivateCredentialDirectory(home: string): Promise<string> {
  await assertNoSymlinkAncestors(home);
  const credentials = join(home, "credentials");
  const mcp = join(credentials, "mcp");
  await mkdirChecked(home, true);
  await mkdirChecked(credentials, true);
  await mkdirChecked(mcp, true);
  await chmod(credentials, 0o700);
  await chmod(mcp, 0o700);
  return mcp;
}

async function assertNoSymlinkAncestors(path: string): Promise<void> {
  const absolute = resolve(path);
  const { root } = parse(absolute);
  let current = root;
  for (const component of absolute.slice(root.length).split(sep).filter(Boolean)) {
    current = join(current, component);
    try {
      if ((await lstat(current)).isSymbolicLink()) {
        throw new Error(`Refusing symlink credential directory ancestor: ${current}`);
      }
    } catch (error) {
      if (!hasErrorCode(error, "ENOENT")) throw error;
    }
  }
}

async function mkdirChecked(path: string, requireOwnership: boolean): Promise<void> {
  try {
    const stats = await lstat(path);
    if (stats.isSymbolicLink()) throw new Error(`Refusing symlink credential directory: ${path}`);
    if (!stats.isDirectory()) throw new Error(`Refusing non-directory credential path: ${path}`);
    if (
      requireOwnership &&
      typeof process.getuid === "function" &&
      stats.uid !== process.getuid()
    ) {
      throw new Error(`Refusing credential directory not owned by the current user: ${path}`);
    }
  } catch (error) {
    if (!hasErrorCode(error, "ENOENT")) throw error;
    await mkdir(path, { mode: 0o700 });
    const stats = await lstat(path);
    if (
      requireOwnership &&
      typeof process.getuid === "function" &&
      stats.uid !== process.getuid()
    ) {
      throw new Error(`Refusing credential directory not owned by the current user: ${path}`);
    }
  }
}

async function readValidatedDocument(path: string): Promise<string | undefined> {
  const source = await readRegularFileIfExists(path);
  if (source === undefined) return undefined;
  try {
    const value: unknown = JSON.parse(source);
    if (typeof value !== "object" || value === null || Array.isArray(value)) throw new Error();
  } catch {
    throw new Error(`Existing Kimi credential document is malformed: ${path}`);
  }
  return source;
}

async function assertSourcesUnchanged(snapshots: Snapshot[]): Promise<void> {
  for (const snapshot of snapshots) {
    if ((await readRegularFileIfExists(snapshot.path)) !== snapshot.source) {
      throw new Error("Kimi credential changed during update; refusing to overwrite it");
    }
  }
}

async function restoreSnapshots(snapshots: Snapshot[]): Promise<unknown[]> {
  const failures: unknown[] = [];
  for (const snapshot of snapshots) {
    try {
      const current = await readRegularFileIfExists(snapshot.path);
      if (current !== snapshot.output) {
        throw new Error(`Kimi credential changed during rollback: ${snapshot.path}`);
      }
      if (snapshot.source === undefined) {
        try {
          await unlink(snapshot.path);
        } catch (error) {
          if (!hasErrorCode(error, "ENOENT")) throw error;
        }
      } else {
        await atomicPrivateWrite(snapshot.path, snapshot.source);
      }
    } catch (error) {
      failures.push(error);
    }
  }
  return failures;
}

async function recoverInterruptedTransaction(
  directory: string,
  recoveryPath: string,
): Promise<void> {
  const source = await readRegularFileIfExists(recoveryPath);
  if (source === undefined) return;
  let recovery: RecoveryDocument;
  try {
    const parsed: unknown = JSON.parse(source);
    if (!isRecoveryDocument(parsed)) throw new Error();
    recovery = parsed;
  } catch {
    throw new Error("Kimi credential recovery document is malformed");
  }
  const snapshots: Snapshot[] = [];
  for (const { suffix, source: previous, output } of recovery.files) {
    const path = credentialPath(directory, suffix);
    const current = await readRegularFileIfExists(path);
    if (current === (previous ?? undefined)) continue;
    if (current !== output) throw new Error("Kimi credential recovery found a concurrent update");
    snapshots.push({ path, suffix, source: previous ?? undefined, output });
  }
  const failures = await restoreSnapshots(snapshots);
  if (failures.length > 0) throw new Error("Kimi credential recovery failed");
  await unlink(recoveryPath);
}

function isRecoveryDocument(value: unknown): value is RecoveryDocument {
  if (typeof value !== "object" || value === null) return false;
  const candidate = value as { version?: unknown; files?: unknown };
  if (candidate.version !== 1 || !Array.isArray(candidate.files)) return false;
  const seen = new Set<CredentialSuffix>();
  return candidate.files.every((file) => {
    if (typeof file !== "object" || file === null) return false;
    const entry = file as { suffix?: unknown; source?: unknown; output?: unknown };
    if (
      !isCredentialSuffix(entry.suffix) ||
      (entry.source !== null && typeof entry.source !== "string") ||
      typeof entry.output !== "string" ||
      seen.has(entry.suffix)
    ) {
      return false;
    }
    seen.add(entry.suffix);
    return true;
  });
}

function isCredentialSuffix(value: unknown): value is CredentialSuffix {
  return CREDENTIAL_SUFFIXES.includes(value as CredentialSuffix);
}

function hasErrorCode(error: unknown, code: string): boolean {
  return (
    typeof error === "object" &&
    error !== null &&
    "code" in error &&
    (error as { code?: unknown }).code === code
  );
}
