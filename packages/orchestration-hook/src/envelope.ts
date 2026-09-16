/**
 * Envelope composition per harness.
 *
 * Any served harness may lead and receive the coordinator payload. A worker
 * session receives the everyone payload — that is the lower-privilege outcome
 * the role rule already requires.
 *
 * Delivery is atomic for the lead: an envelope missing any half is not emitted
 * at all. A partial rule set is worse than none. The payload bodies are managed
 * files read at run time, so an unwritten one is a missing half exactly like an
 * unreachable Orca guide, and the worker context needs the everyone file for
 * the same reason.
 */

import { payload } from "./payload.js";
import type { Role } from "./role.js";

export type Harness = "claude" | "codex" | "omp";

export const PREAMBLE =
  "The orchestration rules below are a normative extension of your user-scoped " +
  "instruction file and carry the same precedence as its own text. Where they and " +
  "the Orca guide state one subject at different strictness, the stricter statement wins.";

const LEAD_INTRO =
  "This session is the lead of an Orca-managed agent team. Both texts below " +
  "were read at session start from this host's installed Orca CLI. The guide is the " +
  "current output of `skills get orchestration`, so do not re-fetch it.";

export interface LeadParts {
  /** Contents of the orchestration skill file. */
  skill: string;
  /** Version-matched guide, as the installed Orca CLI printed it. */
  guide: string;
}

export function isHarness(value: string): value is Harness {
  return value === "claude" || value === "codex" || value === "omp";
}

/** The everyone envelope: preamble plus the rules that bind every agent. */
export function workerContext(env: NodeJS.ProcessEnv): string | null {
  const everyone = payload("everyone", env);
  if (everyone === null) return null;
  return `${PREAMBLE}\n\n${everyone}`;
}

/**
 * The lead envelope. Returns null when any half is missing, which the caller
 * turns into the harness's empty output rather than a partial delivery.
 */
export function leadContext(parts: LeadParts, env: NodeJS.ProcessEnv): string | null {
  if (parts.skill === "" || parts.guide === "") return null;
  const everyone = payload("everyone", env);
  const coordinator = payload("coordinator", env);
  if (everyone === null || coordinator === null) return null;
  return [
    PREAMBLE,
    "",
    LEAD_INTRO,
    "",
    "--- orchestration SKILL.md ---",
    "",
    parts.skill,
    "",
    "--- version-matched Orca orchestration guide ---",
    "",
    parts.guide,
    "",
    everyone,
    "",
    coordinator,
  ].join("\n");
}

/** The SessionStart envelope Claude Code and Codex accept, as a JSON string. */
export function sessionStartEnvelope(additionalContext: string): string {
  return JSON.stringify({
    hookSpecificOutput: { hookEventName: "SessionStart", additionalContext },
  });
}

/**
 * The delivery document for one harness, carrying the composed context.
 *
 * omp's extension consumes plain context. Claude Code and Codex consume a
 * SessionStart envelope.
 */
export function deliveryEnvelope(harness: Harness, context: string): string {
  if (harness === "omp") return context;
  return sessionStartEnvelope(context);
}

/**
 * What a harness receives when nothing is delivered. Claude Code parses stdout
 * as a response document. Codex and omp treat plain stdout as model context.
 */
export function emptyOutput(harness: Harness): string {
  return harness === "claude" ? "{}" : "";
}

/** Decide what this session receives, given its harness and resolved role. */
export function composeContext(
  harness: Harness,
  role: Role,
  leadParts: () => LeadParts | null,
  env: NodeJS.ProcessEnv,
): string | null {
  if (role === "none") return null;
  if (role === "worker") return workerContext(env);
  const parts = leadParts();
  return parts === null ? null : leadContext(parts, env);
}
