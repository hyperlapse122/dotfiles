import { randomUUID } from "node:crypto";
import { chmod, copyFile, cp, lstat, open, readFile, readdir, rename, rm } from "node:fs/promises";
import { dirname, isAbsolute, join } from "node:path";
import type { UnitManifest } from "./manifest.js";
import { prepareDir, type CommandPaths } from "./paths.js";
import type { CommandState } from "./state.js";

export interface CompletedUnit {
  backingPath: string;
  identity: string;
  generation?: string;
  changed: boolean;
}

export function parseMode(mode: string | number): number {
  if (typeof mode === "number") return mode;
  return Number.parseInt(mode.startsWith("0") ? mode : `0${mode}`, 8);
}

export async function isUnitCompleted(storeUnitDir: string): Promise<boolean> {
  try {
    const marker = join(storeUnitDir, ".complete");
    const st = await lstat(marker);
    return st.isFile() && !st.isSymbolicLink();
  } catch {
    return false;
  }
}
export async function writeCompletionMarker(storeUnitDir: string, mode: number): Promise<void> {
  const marker = join(storeUnitDir, ".complete");
  const tmpMarker = join(storeUnitDir, `.complete.tmp-${randomUUID()}`);
  const fd = await open(tmpMarker, "w", mode);
  try {
    await fd.writeFile("complete\n", "utf-8");
    await fd.sync();
    await fd.close();
    await rename(tmpMarker, marker);
  } catch (err) {
    await fd.close().catch(() => {});
    await rm(tmpMarker, { force: true }).catch(() => {});
    throw err;
  }
}

/**
 * Top-level staging entries a completed generation does not carry yet.
 *
 * Empty whenever the staging path is absent or is not a directory: a run whose
 * externals were not refreshed this pass must leave a converged generation
 * alone rather than fail, and a file staging path is copied per declared
 * command instead of by name.
 */
async function missingStagedEntries(stagingPath: string, storeUnitDir: string): Promise<string[]> {
  let staged: string[];
  try {
    const st = await lstat(stagingPath);
    if (!st.isDirectory()) return [];
    staged = await readdir(stagingPath);
  } catch {
    return [];
  }

  // The caller has just read this directory's completion marker, so a failure
  // here is not a converged generation; repairing on that guess could copy over
  // a live binary, so report nothing missing instead.
  let present: Set<string>;
  try {
    present = new Set(await readdir(storeUnitDir));
  } catch {
    return [];
  }

  return staged.filter((entry) => !present.has(entry));
}

/** Newest modification time under `stagingPath`, or undefined when it is absent. */
async function newestStagedMtimeMs(stagingPath: string): Promise<number | undefined> {
  let st;
  try {
    st = await lstat(stagingPath);
  } catch {
    return undefined;
  }
  if (!st.isDirectory()) return st.mtimeMs;

  let newest = st.mtimeMs;
  let entries: string[];
  try {
    entries = await readdir(stagingPath, { recursive: true });
  } catch {
    return undefined;
  }
  for (const entry of entries) {
    try {
      const entrySt = await lstat(join(stagingPath, entry));
      if (entrySt.mtimeMs > newest) newest = entrySt.mtimeMs;
    } catch {}
  }
  return newest;
}

/**
 * Whether a completed generation was minted BEFORE its staging path was last
 * written -- which means it does not hold the bytes its identity names.
 *
 * A generation is named by an identity hashed from SOURCES, and nothing in the
 * store records which bytes it was minted from, so a mint that ran before the
 * producer did is indistinguishable from a converged one by name alone. It has
 * happened twice on this fleet: an activation pass that ran ahead of the build
 * phase, and a build script that skipped on a host missing its toolchain. Both
 * leave a complete generation carrying the PREVIOUS build's binary, and because
 * the identity never moves again, no later apply repairs it.
 *
 * The completion marker is written last, so its own mtime is the mint time, and
 * staging newer than that is the one observable the store keeps. It is a
 * best-effort signal in one direction only: a false positive costs one
 * redundant copy, and a staging path restored with an archive's own old
 * timestamps is missed -- that case belongs to the external producers, whose
 * identity moves whenever their bytes do.
 */
async function generationPredatesStaging(
  stagingPath: string,
  storeUnitDir: string,
): Promise<boolean> {
  const stagedMtime = await newestStagedMtimeMs(stagingPath);
  if (stagedMtime === undefined) return false;
  try {
    const marker = await lstat(join(storeUnitDir, ".complete"));
    return stagedMtime > marker.mtimeMs;
  } catch {
    return false;
  }
}

/**
 * Re-mints a completed generation from its current staging path.
 *
 * Copying over the generation in place is not available: a running process
 * holds its binary and the rewrite fails ETXTBSY. So the replacement is built
 * beside it and swapped in with two renames, which leaves the identity path
 * resolvable except for the instant between them, and running processes keep
 * the inode they already opened.
 */
async function remintGeneration(
  targetStoreDir: string,
  stagingPath: string,
  unit: UnitManifest,
  unitMode: number,
): Promise<void> {
  const unitStoreDir = dirname(targetStoreDir);
  const token = randomUUID();
  const replacementDir = join(unitStoreDir, `.remint-${token}`);
  const retiredDir = join(unitStoreDir, `.retired-${token}`);

  try {
    await prepareDir(replacementDir, unitMode);
    await copyStagingInto(replacementDir, stagingPath, unit, unitMode);
    await writeCompletionMarker(replacementDir, unitMode);
    await rename(targetStoreDir, retiredDir);
    try {
      await rename(replacementDir, targetStoreDir);
    } catch (err) {
      await rename(retiredDir, targetStoreDir).catch(() => {});
      throw err;
    }
  } finally {
    await rm(replacementDir, { recursive: true, force: true }).catch(() => {});
    await rm(retiredDir, { recursive: true, force: true }).catch(() => {});
  }
}

/** Copies a directory staging path wholesale, a file staging path per command. */
async function copyStagingInto(
  destinationDir: string,
  stagingPath: string,
  unit: UnitManifest,
  unitMode: number,
): Promise<void> {
  const st = await lstat(stagingPath);
  if (st.isDirectory()) {
    await cp(stagingPath, destinationDir, { recursive: true });
    return;
  }
  for (const cmd of unit.commands) {
    const destFile = join(destinationDir, cmd.relPath ?? cmd.name);
    await prepareDir(dirname(destFile), unitMode);
    await copyFile(stagingPath, destFile);
    await chmod(destFile, unitMode);
  }
}

export async function ensureCompletedUnit(
  paths: CommandPaths,
  unit: UnitManifest,
  state: CommandState,
): Promise<CompletedUnit> {
  if (unit.mutableTree) {
    const fullTreePath = isAbsolute(unit.stagingPath)
      ? unit.stagingPath
      : join(paths.home, unit.stagingPath);
    return {
      backingPath: fullTreePath,
      identity: unit.identity || "mutable",
      changed: false,
    };
  }

  const unitMode = parseMode(unit.mode);

  if (unit.privacy === "secret") {
    const unitState = state.units[unit.id];
    const activeGen = unitState?.activeGeneration;
    const stagedFile = isAbsolute(unit.stagingPath)
      ? unit.stagingPath
      : join(paths.home, unit.stagingPath);

    let stagedBytes: Buffer;
    try {
      stagedBytes = await readFile(stagedFile);
    } catch (err) {
      throw new Error(`Failed to read secret staged file for unit ${unit.id}: ${String(err)}`);
    }

    if (activeGen) {
      const activeStoreDir = join(paths.storeDir, unit.id, activeGen);
      const activeFile = join(activeStoreDir, unit.commands[0]?.name ?? unit.id);
      try {
        const activeBytes = await readFile(activeFile);
        if (stagedBytes.equals(activeBytes) && (await isUnitCompleted(activeStoreDir))) {
          return {
            backingPath: activeStoreDir,
            identity: activeGen,
            generation: activeGen,
            changed: false,
          };
        }
      } catch {
        // Active file missing or unreadable; create new generation below
      }
    }

    const newGen = `gen-${randomUUID()}`;
    const newStoreDir = join(paths.storeDir, unit.id, newGen);
    await prepareDir(newStoreDir, 0o700);

    for (const cmd of unit.commands) {
      const destFile = join(newStoreDir, cmd.relPath ?? cmd.name);
      await prepareDir(dirname(destFile), 0o700);
      const fd = await open(destFile, "w", 0o700);
      await fd.writeFile(stagedBytes);
      await fd.sync();
      await fd.close();
      await chmod(destFile, 0o700);
    }

    await writeCompletionMarker(newStoreDir, 0o700);
    return {
      backingPath: newStoreDir,
      identity: newGen,
      generation: newGen,
      changed: true,
    };
  }

  const identity = unit.identity;
  if (!identity) {
    throw new Error(`Unit ${unit.id} is missing immutable identity`);
  }

  const targetStoreDir = join(paths.storeDir, unit.id, identity);
  const stagingPath = isAbsolute(unit.stagingPath)
    ? unit.stagingPath
    : join(paths.home, unit.stagingPath);

  if (await isUnitCompleted(targetStoreDir)) {
    if (await generationPredatesStaging(stagingPath, targetStoreDir)) {
      await remintGeneration(targetStoreDir, stagingPath, unit, unitMode);
      return { backingPath: targetStoreDir, identity, changed: true };
    }
    // A unit can gain a file without changing identity -- a second external
    // staged into the same directory. Copy only what the generation lacks:
    // rewriting an entry already there would fail ETXTBSY against a running
    // binary, and the entries present are the ones processes are executing.
    const missing = await missingStagedEntries(stagingPath, targetStoreDir);
    if (missing.length === 0) {
      return { backingPath: targetStoreDir, identity, changed: false };
    }
    for (const entry of missing) {
      await cp(join(stagingPath, entry), join(targetStoreDir, entry), {
        recursive: true,
        preserveTimestamps: true,
      });
    }
    await writeCompletionMarker(targetStoreDir, unitMode);
    return { backingPath: targetStoreDir, identity, changed: true };
  }

  try {
    await lstat(stagingPath);
  } catch (err) {
    throw new Error(`Staging path missing for unit ${unit.id}: ${stagingPath} (${String(err)})`);
  }

  await prepareDir(targetStoreDir, unitMode);
  await copyStagingInto(targetStoreDir, stagingPath, unit, unitMode);
  await writeCompletionMarker(targetStoreDir, unitMode);
  return {
    backingPath: targetStoreDir,
    identity,
    changed: true,
  };
}
