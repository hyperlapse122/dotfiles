import { lstat, readdir, rename, rm } from "node:fs/promises";
import { join } from "node:path";
import type { CommandManifest } from "./manifest.js";
import { prepareDir, type CommandPaths } from "./paths.js";
import { scanDarwinRoots } from "./process-darwin.js";
import { scanLinuxRoots, type ProcessRoots } from "./process-linux.js";
import type { CommandState } from "./state.js";

export async function defaultRootScanner(): Promise<ProcessRoots> {
  if (process.platform === "darwin") {
    return scanDarwinRoots();
  }
  return scanLinuxRoots();
}
async function cleanupQuarantine(
  paths: CommandPaths,
  rootScanner: () => Promise<ProcessRoots>,
): Promise<void> {
  try {
    const units = await readdir(paths.quarantineDir);
    const roots = await rootScanner();
    for (const unitId of units) {
      const qUnitDir = join(paths.quarantineDir, unitId);
      let versions: string[];
      try {
        versions = await readdir(qUnitDir);
      } catch {
        continue;
      }
      for (const version of versions) {
        const qPath = join(qUnitDir, version);
        if (await generationInUse(qPath, roots)) {
          const storeVersionDir = join(paths.storeDir, unitId, version);
          await prepareDir(join(paths.storeDir, unitId), 0o755);
          await rename(qPath, storeVersionDir).catch(() => {});
        } else {
          await rm(qPath, { recursive: true, force: true }).catch(() => {});
        }
      }
    }
  } catch {}
}

/**
 * Whether any running process holds a file inside `versionDir`.
 *
 * Walks the whole generation rather than the unit's declared commands: a
 * proof-eligible unit may carry native binaries that are not public commands
 * (the codex code-mode helper), and those are just as live as the entrypoint.
 * An unreadable directory counts as in use -- absent evidence never authorises
 * a delete.
 */
async function generationInUse(versionDir: string, roots: ProcessRoots): Promise<boolean> {
  if (roots.uncertain) return true;
  let files: string[];
  try {
    files = await readdir(versionDir, { recursive: true });
  } catch {
    return true;
  }
  for (const relative of files) {
    const fullPath = join(versionDir, relative);
    if (roots.paths.has(fullPath)) return true;
    try {
      const st = await lstat(fullPath);
      if (roots.inodes.has(`${st.dev}:${st.ino}`)) return true;
    } catch {}
  }
  return false;
}

export async function pruneEligibleUnits(
  paths: CommandPaths,
  manifest: CommandManifest,
  state: CommandState,
  rootScanner: () => Promise<ProcessRoots> = defaultRootScanner,
): Promise<{ retained: string[]; pruned: string[] }> {
  const retained: string[] = [];
  const pruned: string[] = [];
  await cleanupQuarantine(paths, rootScanner);

  const roots = await rootScanner();
  for (const unit of manifest.units) {
    if (unit.mutableTree) continue;

    const unitStoreDir = join(paths.storeDir, unit.id);
    let installedVersions: string[];
    try {
      installedVersions = await readdir(unitStoreDir);
    } catch {
      continue;
    }

    const activeIdentity = state.units[unit.id]?.activeIdentity;

    for (const version of installedVersions) {
      if (version === activeIdentity) continue;
      const versionDir = join(unitStoreDir, version);

      try {
        const st = await lstat(versionDir);
        if (!st.isDirectory()) continue;
      } catch {
        continue;
      }

      const versionLabel = `${unit.id}/${version}`;

      if (!unit.proofEligible) {
        retained.push(versionLabel);
        continue;
      }

      if (roots.uncertain) {
        retained.push(versionLabel);
        continue;
      }

      if (await generationInUse(versionDir, roots)) {
        retained.push(versionLabel);
        continue;
      }

      const quarantineUnitDir = join(paths.quarantineDir, unit.id);
      await prepareDir(quarantineUnitDir, 0o700);
      const quarantinePath = join(quarantineUnitDir, version);

      try {
        await rename(versionDir, quarantinePath);
      } catch {
        retained.push(versionLabel);
        continue;
      }

      const recheckedRoots = await rootScanner();
      if (await generationInUse(quarantinePath, recheckedRoots)) {
        await rename(quarantinePath, versionDir).catch(() => {});
        retained.push(versionLabel);
      } else {
        await rm(quarantinePath, { recursive: true, force: true }).catch(() => {});
        pruned.push(versionLabel);
      }
    }
  }

  return { retained, pruned };
}
