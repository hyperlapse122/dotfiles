import { randomUUID } from "node:crypto";
import { rename, readFile, unlink, writeFile } from "node:fs/promises";
import type { LockedTool, ReleaseLock } from "./types.js";

interface LockFileSystem {
  writeFile: typeof writeFile;
  rename: typeof rename;
  unlink: typeof unlink;
}

const lockFileSystem: LockFileSystem = { writeFile, rename, unlink };

/** Sorted so an unchanged upstream yields a byte-identical file. */
export function sortTools(tools: Record<string, LockedTool>): Record<string, LockedTool> {
  return Object.fromEntries(Object.entries(tools).sort(([a], [b]) => a.localeCompare(b)));
}

/**
 * Overlay a resolution onto the committed lock.
 *
 * Resolution omits sources that failed, so overlaying — rather than replacing —
 * is what leaves a failed entry at its last good value instead of dropping it.
 */
export function mergeLocks(existing: ReleaseLock | null, resolved: ReleaseLock): ReleaseLock {
  return {
    releases: {
      tools: sortTools({ ...existing?.releases.tools, ...resolved.releases.tools }),
    },
  };
}

export function serializeLock(lock: ReleaseLock): string {
  return `${JSON.stringify(lock, null, 2)}\n`;
}

export async function readLock(path: string): Promise<ReleaseLock | null> {
  try {
    return JSON.parse(await readFile(path, "utf8")) as ReleaseLock;
  } catch (error) {
    if ((error as NodeJS.ErrnoException).code === "ENOENT") return null;
    throw error;
  }
}

export async function writeLock(
  path: string,
  lock: ReleaseLock,
  fs: LockFileSystem = lockFileSystem,
): Promise<void> {
  const temporary = `${path}.tmp-${process.pid}-${randomUUID()}`;
  try {
    await fs.writeFile(temporary, serializeLock(lock), { encoding: "utf8", mode: 0o644 });
    await fs.rename(temporary, path);
  } finally {
    await fs.unlink(temporary).catch((error: NodeJS.ErrnoException) => {
      if (error.code !== "ENOENT") throw error;
    });
  }
}
