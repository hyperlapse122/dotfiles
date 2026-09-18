/**
 * Session role resolution, shared by every orchestration hook.
 *
 * Precedence, in order:
 *   - ORCA_TERMINAL_HANDLE unset or empty        -> none    (not Orca-managed)
 *   - handle set, and ORCA_AGENT_TEAMS_LEADER_PANE
 *     and TMUX_PANE are both non-empty and equal -> lead
 *   - handle set, and TMUX_PANE or
 *     ORCA_AGENT_TEAMS_LEADER_PANE is non-empty  -> worker  (tmux teammate pane)
 *   - handle set, matching active worker in
 *     orchestration database                     -> worker  (dispatched worker)
 *   - any other non-empty handle                 -> lead    (interactive coordinator)
 *
 * An empty string counts as unset everywhere. Comparing two unset variables
 * matches empty against empty, which would classify every teammate as the
 * lead, so every leg tests presence before equality. Pane variables alone
 * never produce lead or worker: without the Orca terminal handle the session
 * is not Orca-managed at all.
 */

import { existsSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";
import { DatabaseSync } from "node:sqlite";

export type Role = "none" | "worker" | "lead";
export interface RoleEnv {
  ORCA_TERMINAL_HANDLE?: string | undefined;
  ORCA_AGENT_TEAMS_LEADER_PANE?: string | undefined;
  TMUX_PANE?: string | undefined;
  ORCA_USER_DATA_PATH?: string | undefined;
  HOME?: string | undefined;
  [key: string]: string | undefined;
}

export interface RoleOptions {
  isWorker?: (handle: string, env: RoleEnv) => boolean;
}
export function present(value: string | undefined): value is string {
  return value !== undefined && value !== "";
}

export function isWorkerTerminal(handle: string, env: RoleEnv): boolean {
  const userDataDir = present(env.ORCA_USER_DATA_PATH)
    ? env.ORCA_USER_DATA_PATH
    : join(present(env.HOME) ? env.HOME : homedir(), ".config", "orca");
  const dbPath = join(userDataDir, "orchestration.db");
  if (!existsSync(dbPath)) return false;
  try {
    const db = new DatabaseSync(dbPath, { readOnly: true });
    try {
      const hasWorkers = db
        .prepare("SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = 'worker_dispatches'")
        .get();
      if (hasWorkers !== undefined) {
        const row = db
          .prepare(
            "SELECT 1 as found FROM worker_dispatches WHERE agent_terminal_handle = ? AND state IN ('starting', 'ready') LIMIT 1",
          )
          .get(handle);
        if (row !== undefined) return true;
      }
      const hasContexts = db
        .prepare("SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = 'dispatch_contexts'")
        .get();
      if (hasContexts !== undefined) {
        const row = db
          .prepare(
            "SELECT 1 as found FROM dispatch_contexts WHERE assignee_handle = ? AND status IN ('pending', 'dispatched') LIMIT 1",
          )
          .get(handle);
        if (row !== undefined) return true;
      }
      return false;
    } finally {
      db.close();
    }
  } catch {
    return false;
  }
}

export function resolveRole(env: RoleEnv, options?: RoleOptions): Role {
  if (!present(env.ORCA_TERMINAL_HANDLE)) return "none";
  if (present(env.ORCA_AGENT_TEAMS_LEADER_PANE)) {
    if (!present(env.TMUX_PANE)) return "worker";
    return env.TMUX_PANE === env.ORCA_AGENT_TEAMS_LEADER_PANE ? "lead" : "worker";
  }
  if (present(env.TMUX_PANE)) {
    return "worker";
  }
  const isWorker = options?.isWorker ?? isWorkerTerminal;
  return isWorker(env.ORCA_TERMINAL_HANDLE, env) ? "worker" : "lead";
}
