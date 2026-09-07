import { lstat, readlink, realpath, stat } from "node:fs/promises";
import { dirname, join, relative, resolve } from "node:path";
import type { CommandManifest, UnitManifest } from "./manifest.js";
import {
  atomicSymlink,
  contained,
  prepareDir,
  resolveCommandPaths,
  type CommandPaths,
} from "./paths.js";
import { ensureCompletedUnit } from "./producer.js";
import { pruneEligibleUnits } from "./prune.js";
import { readState, writeState, type CommandState } from "./state.js";

export interface ActivationResult {
  unitId: string;
  identity: string;
  changed: boolean;
  status: "activated" | "unchanged" | "failed" | "conflict";
  error?: string;
  conflictPath?: string;
}

export interface ReconcileReport {
  activated: string[];
  unchanged: string[];
  failed: Array<{ id: string; error: string }>;
  conflicts: Array<{ id: string; path: string; reason: string }>;
  retained: string[];
  pruned: string[];
}

async function findUnresolvableCommand(
  unit: UnitManifest,
  backingPath: string,
): Promise<string | undefined> {
  let backingRoot: string;
  try {
    backingRoot = await realpath(backingPath);
  } catch (err) {
    // `ensureCompletedUnit` returns a `mutableTree` unit's raw tree path with no
    // store copy, and that tree may legitimately be absent on a host.
    if (unit.mutableTree) return undefined;
    return `Unit ${unit.id}: backing store ${backingPath} is unreadable (${String(err)})`;
  }

  for (const cmd of unit.commands) {
    const rel = cmd.relPath ?? cmd.name;
    const targetPath = join(backingPath, rel);
    let resolvedTarget: string;
    try {
      resolvedTarget = await realpath(targetPath);
    } catch {
      const remedy = cmd.relPath
        ? `relPath ${cmd.relPath} does not resolve to an existing file`
        : "declare relPath for an existing file";
      return `Unit ${unit.id} command ${cmd.name} has no backing file at ${targetPath}; ${remedy}`;
    }
    try {
      contained(backingRoot, resolvedTarget);
    } catch {
      return `Unit ${unit.id} command ${cmd.name} resolves to ${resolvedTarget}, outside its store directory ${backingRoot}`;
    }
    if (!(await stat(resolvedTarget)).isFile()) {
      return `Unit ${unit.id} command ${cmd.name} resolves to ${resolvedTarget}, which is not a regular file`;
    }
  }

  return undefined;
}

export async function activateUnitInternal(
  paths: CommandPaths,
  unit: UnitManifest,
  state: CommandState,
): Promise<ActivationResult> {
  const completed = await ensureCompletedUnit(paths, unit, state);

  const unresolved = await findUnresolvableCommand(unit, completed.backingPath);
  if (unresolved) {
    return {
      unitId: unit.id,
      identity: completed.identity,
      changed: false,
      status: "failed",
      error: unresolved,
    };
  }

  await prepareDir(paths.currentDir, 0o755);
  const currentLink = join(paths.currentDir, unit.id);
  await atomicSymlink(completed.backingPath, currentLink);

  await prepareDir(paths.binDir, 0o755);

  for (const cmd of unit.commands) {
    const publicPath = join(paths.binDir, cmd.name);
    const expectedRel = join("../lib/commands/current", unit.id, cmd.relPath ?? cmd.name);

    try {
      const st = await lstat(publicPath);
      if (st.isSymbolicLink()) {
        const linkTarget = await readlink(publicPath);
        if (
          linkTarget !== expectedRel &&
          linkTarget !== join(paths.currentDir, unit.id, cmd.relPath ?? cmd.name)
        ) {
          await atomicSymlink(expectedRel, publicPath);
        }
      } else if (st.isFile()) {
        const isLegacyOwner =
          unit.legacy?.path &&
          (publicPath === resolve(paths.home, unit.legacy.path) ||
            relative(paths.home, publicPath) === unit.legacy.path ||
            (dirname(publicPath) === resolve(paths.home, dirname(unit.legacy.path)) &&
              unit.commands.some((c) => c.name === cmd.name)));
        if (isLegacyOwner) {
          await atomicSymlink(expectedRel, publicPath);
        } else {
          return {
            unitId: unit.id,
            identity: completed.identity,
            changed: false,
            status: "conflict",
            conflictPath: publicPath,
            error: `Ownership conflict: ${publicPath} exists and is not proven legacy owner for unit ${unit.id}`,
          };
        }
      } else {
        return {
          unitId: unit.id,
          identity: completed.identity,
          changed: false,
          status: "conflict",
          conflictPath: publicPath,
          error: `Unsupported file type at ${publicPath}`,
        };
      }
    } catch (err: unknown) {
      if ((err as NodeJS.ErrnoException).code === "ENOENT") {
        await atomicSymlink(expectedRel, publicPath);
      } else {
        throw err;
      }
    }
  }

  const prevUnitState = state.units[unit.id];
  const unitChanged = completed.changed || prevUnitState?.activeIdentity !== completed.identity;

  state.units[unit.id] = {
    ...prevUnitState,
    activeIdentity: completed.identity,
    ...(completed.generation ? { activeGeneration: completed.generation } : {}),
    legacyClaimed: true,
  };

  return {
    unitId: unit.id,
    identity: completed.identity,
    changed: unitChanged,
    status: unitChanged ? "activated" : "unchanged",
  };
}

export async function activateUnit(
  targetHome: string | undefined,
  manifest: CommandManifest,
  unitId: string,
): Promise<ActivationResult> {
  const paths = resolveCommandPaths(targetHome);
  const unit = manifest.units.find((u) => u.id === unitId);
  if (!unit) {
    throw new Error(`Unit ${unitId} not found in command manifest`);
  }
  const state = await readState(targetHome);
  const result = await activateUnitInternal(paths, unit, state);
  if (result.status === "activated" || result.status === "unchanged") {
    await writeState(targetHome, state);
  }
  return result;
}

export async function reconcileAll(
  targetHome: string | undefined,
  manifest: CommandManifest,
  pruner:
    | ((
        paths: CommandPaths,
        manifest: CommandManifest,
        state: CommandState,
      ) => Promise<{ retained: string[]; pruned: string[] }>)
    | boolean = true,
): Promise<ReconcileReport> {
  const paths = resolveCommandPaths(targetHome);
  const state = await readState(targetHome);

  const report: ReconcileReport = {
    activated: [],
    unchanged: [],
    failed: [],
    conflicts: [],
    retained: [],
    pruned: [],
  };

  for (const unit of manifest.units) {
    try {
      const result = await activateUnitInternal(paths, unit, state);
      if (result.status === "activated") {
        report.activated.push(unit.id);
      } else if (result.status === "unchanged") {
        report.unchanged.push(unit.id);
      } else if (result.status === "failed") {
        report.failed.push({ id: unit.id, error: result.error ?? "Activation failed" });
      } else if (result.status === "conflict") {
        report.conflicts.push({
          id: unit.id,
          path: result.conflictPath ?? "",
          reason: result.error ?? "Ownership conflict",
        });
      }
    } catch (err: unknown) {
      report.failed.push({
        id: unit.id,
        error: err instanceof Error ? err.message : String(err),
      });
    }
  }

  if (pruner) {
    const pruneFn = typeof pruner === "function" ? pruner : pruneEligibleUnits;
    try {
      const pruneResults = await pruneFn(paths, manifest, state);
      report.retained.push(...pruneResults.retained);
      report.pruned.push(...pruneResults.pruned);
    } catch (err) {
      report.failed.push({
        id: "prune",
        error: `Pruning failure: ${String(err)}`,
      });
    }
  }

  await writeState(targetHome, state);
  return report;
}
