import { randomUUID } from "node:crypto";
import { chmod, copyFile, cp, lstat, open, readFile, rename, rm } from "node:fs/promises";
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
  if (await isUnitCompleted(targetStoreDir)) {
    return {
      backingPath: targetStoreDir,
      identity,
      changed: false,
    };
  }

  const stagingPath = isAbsolute(unit.stagingPath)
    ? unit.stagingPath
    : join(paths.home, unit.stagingPath);
  let st;
  try {
    st = await lstat(stagingPath);
  } catch (err) {
    throw new Error(`Staging path missing for unit ${unit.id}: ${stagingPath} (${String(err)})`);
  }

  await prepareDir(targetStoreDir, unitMode);

  if (st.isDirectory()) {
    await cp(stagingPath, targetStoreDir, { recursive: true });
  } else {
    for (const cmd of unit.commands) {
      const destFile = join(targetStoreDir, cmd.relPath ?? cmd.name);
      await prepareDir(dirname(destFile), unitMode);
      await copyFile(stagingPath, destFile);
      await chmod(destFile, unitMode);
    }
  }

  await writeCompletionMarker(targetStoreDir, unitMode);
  return {
    backingPath: targetStoreDir,
    identity,
    changed: true,
  };
}
