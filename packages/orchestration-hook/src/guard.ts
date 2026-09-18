/**
 * The subagent tool guard.
 *
 * In an Orca-managed session whose local payload files are staged, this
 * denies the harness's own subagent tool: a subagent that tool starts is a
 * worker Orca cannot supervise. Every other tool call, every session outside
 * Orca, and every Orca agent-teams session allows, because the `Agent` tool is
 * the teammate spawn path there and Orca supervises each teammate through its
 * tmux pane.
 *
 * "Received the injection" is decided from the same local inputs the `hook`
 * command uses, not from a fresh guide fetch: that fetch costs up to eight
 * seconds and proves nothing about a past delivery, and recording a delivery
 * would need new persistent state in a package that holds none. A lead whose
 * guide fetch failed receives no envelope but is still denied, by design — the
 * Everyone payload already forbids a substitute subagent when Orca is
 * unreachable, so the denial removes no permitted path.
 */

import { readFileSync } from "node:fs";
import { join } from "node:path";
import type { Harness } from "./envelope.js";
import { resolveHome } from "./home.js";
import { payload } from "./payload.js";
import { resolveRole, type Role, type RoleEnv } from "./role.js";

/** Blocked `tool_name` per harness, matched exactly. Captured from a live session per plan U2 step 0. */
export const SUBAGENT_TOOLS: Record<Harness, readonly string[]> = {
  claude: ["Agent", "Task"],
  // Codex 0.155.0 reports the multi-agent spawn tool as "collaborationspawn_agent"
  // (the "collaboration" tool namespace concatenated directly onto the base
  // "spawn_agent" name, with no separator), not the bare "spawn_agent" the plan's
  // KTD7 table assumed from static binary-string evidence. This is the captured
  // value; see the U2 report for the capture that settled it.
  codex: ["collaborationspawn_agent"],
  omp: ["task"],
};

function present(value: string | undefined): value is string {
  return value !== undefined && value !== "";
}

export function readOrchestrationSkill(env: NodeJS.ProcessEnv): string {
  const home = resolveHome(env);
  try {
    return readFileSync(join(home, ".agents", "skills", "orchestration", "SKILL.md"), "utf8");
  } catch {
    return "";
  }
}

/** Whether this session received the orchestration injection, per KTD6. */
export function isInjected(role: Role, env: NodeJS.ProcessEnv): boolean {
  if (present((env as RoleEnv).ORCA_AGENT_TEAMS_LEADER_PANE)) return false;
  if (role === "worker") return payload("everyone", env) !== null;
  if (role === "lead") {
    return (
      payload("everyone", env) !== null &&
      payload("coordinator", env) !== null &&
      readOrchestrationSkill(env) !== ""
    );
  }
  return false;
}

export function denyReason(tool: string): string {
  return (
    `The harness's own subagent tool (\`${tool}\`) is not available in an ` +
    "Orca-managed session. Orca owns agent lifecycle, so a subagent this tool " +
    "starts is a worker Orca cannot supervise. Open the `orchestration` skill, " +
    "load its version-matched guide, and use the Orca dispatch path instead. If " +
    "this session is a dispatched worker, do the work yourself or ask the " +
    "coordinator with the `ask` command from your preamble. If Orca is " +
    "unreachable, report the failed command and its exact error and continue " +
    "with your own reasoning only."
  );
}

export interface GuardEvent {
  tool_name?: unknown;
}

export interface Decision {
  deny: boolean;
  reason?: string;
}

/** Allow unless `event.tool_name` is a string in the harness's blocked set and this session is injected. */
export function decide(event: GuardEvent, harness: Harness, env: NodeJS.ProcessEnv): Decision {
  const toolName = event.tool_name;
  if (typeof toolName !== "string") return { deny: false };
  if (!SUBAGENT_TOOLS[harness].includes(toolName)) return { deny: false };
  const role = resolveRole(env as RoleEnv);
  if (!isInjected(role, env)) return { deny: false };
  return { deny: true, reason: denyReason(toolName) };
}

/**
 * The denial, in the document shape the harness actually reads.
 *
 * A response in the wrong shape is silently ignored, which reads as a guard
 * that denies nothing at all.
 */
export function denyOutput(reason: string): string {
  return JSON.stringify({
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      permissionDecision: "deny",
      permissionDecisionReason: reason,
    },
  });
}
