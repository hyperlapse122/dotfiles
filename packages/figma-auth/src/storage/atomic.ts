import { constants, type Stats } from "node:fs";
import { lstat, open, rename, unlink } from "node:fs/promises";
import { basename, dirname, join } from "node:path";
import { randomUUID } from "node:crypto";

export interface AtomicWriteOptions {
  beforePromote?: () => Promise<void>;
  renameFile?: (source: string, destination: string) => Promise<void>;
  temporaryName?: () => string;
  unlinkFile?: (path: string) => Promise<void>;
}

export async function readRegularFileIfExists(path: string): Promise<string | undefined> {
  let handle;
  try {
    handle = await open(path, constants.O_RDONLY | constants.O_NOFOLLOW | constants.O_NONBLOCK);
  } catch (error) {
    if (hasErrorCode(error, "ENOENT")) return undefined;
    if (hasErrorCode(error, "ELOOP")) throw refusalError("symlink", path);
    throw error;
  }

  try {
    assertRegular(await handle.stat(), path);
    return await handle.readFile({ encoding: "utf8" });
  } finally {
    await handle.close();
  }
}

export async function atomicPrivateWrite(
  path: string,
  contents: string,
  options: AtomicWriteOptions = {},
): Promise<void> {
  await assertRegularOrMissing(path);
  const temporaryName = options.temporaryName ?? randomUUID;
  const temporaryPath = join(dirname(path), `.${basename(path)}.${temporaryName()}.tmp`);
  let handle;
  let temporaryCreated = false;
  let promoted = false;
  let primaryFailure: unknown;

  try {
    handle = await open(
      temporaryPath,
      constants.O_WRONLY | constants.O_CREAT | constants.O_EXCL | constants.O_NOFOLLOW,
      0o600,
    );
    temporaryCreated = true;
    await handle.writeFile(contents, { encoding: "utf8" });
    await handle.sync();
    await handle.chmod(0o600);
    await handle.close();
    handle = undefined;
    await options.beforePromote?.();
    await (options.renameFile ?? rename)(temporaryPath, path);
    promoted = true;
  } catch (error) {
    primaryFailure = error;
  }

  if (promoted) return;

  const cleanupFailures: unknown[] = [];
  if (handle) {
    try {
      await handle.close();
    } catch (error) {
      cleanupFailures.push(error);
    }
  }

  if (temporaryCreated) {
    try {
      await scrubTemporary(temporaryPath);
    } catch (error) {
      cleanupFailures.push(error);
    }

    let removed = false;
    try {
      await (options.unlinkFile ?? unlink)(temporaryPath);
      removed = true;
    } catch (error) {
      if (hasErrorCode(error, "ENOENT")) removed = true;
      else cleanupFailures.push(error);
    }

    if (removed) cleanupFailures.length = 0;
  }

  if (cleanupFailures.length > 0) {
    throw cleanupError(primaryFailure, cleanupFailures);
  }
  throw primaryFailure;
}

async function scrubTemporary(path: string): Promise<void> {
  const handle = await open(path, constants.O_WRONLY | constants.O_NOFOLLOW | constants.O_NONBLOCK);
  try {
    assertRegular(await handle.stat(), path);
    await handle.truncate(0);
    await handle.sync();
  } finally {
    await handle.close();
  }
}

function cleanupError(primaryFailure: unknown, cleanupFailures: unknown[]): AggregateError {
  const primary = asError(primaryFailure);
  const cleanup = cleanupFailures.map(asError);
  return new AggregateError(
    [primary, ...cleanup],
    `${primary.message}; temporary credential cleanup failed: ${cleanup
      .map((error) => error.message)
      .join("; ")}`,
    { cause: primary },
  );
}

function asError(error: unknown): Error {
  return error instanceof Error ? error : new Error(String(error));
}

async function assertRegularOrMissing(path: string): Promise<void> {
  try {
    const stats = await lstat(path);
    if (stats.isSymbolicLink()) throw refusalError("symlink", path);
    assertRegular(stats, path);
  } catch (error) {
    if (hasErrorCode(error, "ENOENT")) return;
    throw error;
  }
}

function assertRegular(stats: Stats, path: string): void {
  if (!stats.isFile()) throw refusalError("non-regular", path);
}

function refusalError(kind: "symlink" | "non-regular", path: string): Error {
  return new Error(`Refusing ${kind} credential target: ${path}`);
}

function hasErrorCode(error: unknown, code: string): boolean {
  return (
    typeof error === "object" &&
    error !== null &&
    "code" in error &&
    (error as { code?: unknown }).code === code
  );
}
