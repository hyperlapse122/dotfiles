import { randomUUID } from "node:crypto";
import { rename, readFile, unlink, writeFile } from "node:fs/promises";
import { ALL_PLATFORMS, MUSL_PLATFORMS, platformKey, type PlatformKey } from "./platforms.js";
import type { LockedArtifact, LockedTool, ReleaseLock } from "./types.js";

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

/**
 * The current `PlatformKey` vocabulary, as a lookup table.
 *
 * Enumerated from `ALL_PLATFORMS`/`MUSL_PLATFORMS` the same way
 * `registry.test.ts` enumerates its own canonical key set, so "in the
 * vocabulary" means the same thing everywhere it is checked.
 */
const CANONICAL_PLATFORM_KEYS = Object.fromEntries(
  [...ALL_PLATFORMS, ...MUSL_PLATFORMS].map((platform) => [platformKey(platform), true]),
) as Readonly<Record<PlatformKey, true>>;

function pruneToolArtifacts(tool: LockedTool): LockedTool {
  if (!tool.artifacts) return tool;
  const entries = Object.entries(tool.artifacts) as [PlatformKey, LockedArtifact][];
  return {
    ...tool,
    artifacts: Object.fromEntries(entries.filter(([key]) => CANONICAL_PLATFORM_KEYS[key] === true)),
  };
}

/**
 * Drop retired platform keys from every tool's `artifacts` map.
 *
 * A key survives only if it is still in today's `PlatformKey` vocabulary —
 * not by pattern-matching a retired OS's name — so a future platform
 * retirement needs no repeat patch here (KTD1). A single post-merge pass:
 * call once on the run's already-computed `complete` value (clean or
 * partial), not per-tool inside `mergeLocks` (KTD2). A tool with no
 * `artifacts` field is returned untouched — `artifacts: {}` is never
 * synthesized — and `version`/`kind`/`source`/`integrity` are never touched.
 */
export function pruneRetiredPlatforms(lock: ReleaseLock): ReleaseLock {
  const tools: Record<string, LockedTool> = Object.fromEntries(
    Object.entries(lock.releases.tools).map(([name, tool]): [string, LockedTool] => [
      name,
      pruneToolArtifacts(tool),
    ]),
  );
  return { releases: { tools } };
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
