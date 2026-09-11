/**
 * Session role resolution, shared by every orchestration hook.
 *
 * Precedence, in order:
 *   - ORCA_TERMINAL_HANDLE unset or empty        -> none    (not Orca-managed)
 *   - handle set, and ORCA_AGENT_TEAMS_LEADER_PANE
 *     and TMUX_PANE are both non-empty and equal -> lead
 *   - any other non-empty handle                 -> worker
 *
 * An empty string counts as unset everywhere. Comparing two unset variables
 * matches empty against empty, which would classify every teammate as the
 * lead, so every leg tests presence before equality. Pane variables alone
 * never produce lead or worker: without the Orca terminal handle the session
 * is not Orca-managed at all.
 */

export type Role = "none" | "worker" | "lead";

export interface RoleEnv {
  ORCA_TERMINAL_HANDLE?: string | undefined;
  ORCA_AGENT_TEAMS_LEADER_PANE?: string | undefined;
  TMUX_PANE?: string | undefined;
}

function present(value: string | undefined): value is string {
  return value !== undefined && value !== "";
}

export function resolveRole(env: RoleEnv): Role {
  if (!present(env.ORCA_TERMINAL_HANDLE)) return "none";
  if (!present(env.ORCA_AGENT_TEAMS_LEADER_PANE)) return "worker";
  if (!present(env.TMUX_PANE)) return "worker";
  return env.TMUX_PANE === env.ORCA_AGENT_TEAMS_LEADER_PANE ? "lead" : "worker";
}
