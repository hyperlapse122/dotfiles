import { randomUUID } from "node:crypto";
import { open, readFile, rename, rm } from "node:fs/promises";
import { join } from "node:path";
import { prepareDir, resolveCommandPaths } from "./paths.js";

export const STATE_CONTRACT = "command-reconcile/v1";

export interface UnitState {
  activeIdentity: string;
  activeGeneration?: string;
  pendingIdentity?: string;
  quarantineAlias?: string;
  legacyClaimed?: boolean;
  authoredEvidence?: {
    target: string;
    relTarget: string;
    mode: string;
    digest?: string;
  };
}

export interface CommandState {
  schemaVersion: "command-reconcile/v1";
  revision: number;
  updatedAt: string;
  units: Record<string, UnitState>;
}

export function initEmptyState(): CommandState {
  return {
    schemaVersion: "command-reconcile/v1",
    revision: 0,
    updatedAt: new Date().toISOString(),
    units: {},
  };
}

export async function readState(targetHome?: string): Promise<CommandState> {
  const paths = resolveCommandPaths(targetHome);
  try {
    const raw = await readFile(paths.stateFile, "utf-8");
    const parsed = JSON.parse(raw) as unknown;
    if (!parsed || typeof parsed !== "object") {
      throw new Error(`Corrupt state in ${paths.stateFile}: root must be an object`);
    }
    const obj = parsed as Record<string, unknown>;
    if (obj["schemaVersion"] !== STATE_CONTRACT) {
      throw new Error(
        `Incompatible state schema in ${paths.stateFile}: expected ${STATE_CONTRACT}, got ${String(obj["schemaVersion"])}`,
      );
    }
    if (typeof obj["revision"] !== "number") {
      throw new Error(`Corrupt state in ${paths.stateFile}: missing numeric revision`);
    }
    const units = (obj["units"] && typeof obj["units"] === "object" ? obj["units"] : {}) as Record<
      string,
      UnitState
    >;
    return {
      schemaVersion: STATE_CONTRACT,
      revision: obj["revision"] as number,
      updatedAt: typeof obj["updatedAt"] === "string" ? obj["updatedAt"] : new Date().toISOString(),
      units,
    };
  } catch (err: unknown) {
    if ((err as NodeJS.ErrnoException).code === "ENOENT") {
      return initEmptyState();
    }
    throw err;
  }
}

export async function writeState(
  targetHome: string | undefined,
  state: CommandState,
): Promise<void> {
  const paths = resolveCommandPaths(targetHome);
  await prepareDir(paths.stateDir, 0o700);
  const next: CommandState = {
    ...state,
    schemaVersion: STATE_CONTRACT,
    revision: state.revision + 1,
    updatedAt: new Date().toISOString(),
  };
  const jsonStr = `${JSON.stringify(next, null, 2)}\n`;
  const tmpFile = join(paths.stateDir, `.state.tmp-${randomUUID()}`);
  const fd = await open(tmpFile, "w", 0o600);
  try {
    await fd.writeFile(jsonStr, "utf-8");
    await fd.sync();
    await fd.close();
    await rename(tmpFile, paths.stateFile);
  } catch (err) {
    await fd.close().catch(() => {});
    await rm(tmpFile, { force: true }).catch(() => {});
    throw err;
  }
}
