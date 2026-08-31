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

export async function pruneEligibleUnits(
  paths: CommandPaths,
  manifest: CommandManifest,
  state: CommandState,
  rootScanner: () => Promise<ProcessRoots> = defaultRootScanner,
): Promise<{ retained: string[]; pruned: string[] }> {
  const retained: string[] = [];
  const pruned: string[] = [];

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

      let inUse = false;
      try {
        for (const cmd of unit.commands) {
          const cmdPath = join(versionDir, cmd.relPath ?? cmd.name);
          if (roots.paths.has(cmdPath)) {
            inUse = true;
            break;
          }
          try {
            const st = await lstat(cmdPath);
            if (roots.inodes.has(`${st.dev}:${st.ino}`)) {
              inUse = true;
              break;
            }
          } catch {}
        }
      } catch {
        inUse = true;
      }

      if (inUse) {
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
      let lateUse = recheckedRoots.uncertain;
      if (!lateUse) {
        for (const cmd of unit.commands) {
          const cmdPath = join(quarantinePath, cmd.relPath ?? cmd.name);
          if (recheckedRoots.paths.has(cmdPath)) {
            lateUse = true;
            break;
          }
          try {
            const st = await lstat(cmdPath);
            if (recheckedRoots.inodes.has(`${st.dev}:${st.ino}`)) {
              lateUse = true;
              break;
            }
          } catch {}
        }
      }

      if (lateUse) {
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
