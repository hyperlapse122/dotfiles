/**
 * Envelope composition per harness.
 *
 * Any served harness may lead and receive the coordinator payload. A worker
 * session receives the everyone payload — that is the lower-privilege outcome
 * the role rule already requires.
 *
 * Delivery is atomic for the lead: an envelope missing any half is not emitted
 * at all. A partial rule set is worse than none.
 */

import { payload } from "./payload.js";
import type { Role } from "./role.js";

export type Harness = "claude" | "codex" | "agy";

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
  return value === "claude" || value === "codex" || value === "agy";
}

/** The everyone envelope: preamble plus the rules that bind every agent. */
export function workerContext(): string {
  return `${PREAMBLE}\n\n${payload("everyone")}`;
}

/**
 * The lead envelope. Returns null when either half is missing, which the caller
 * turns into the harness's empty output rather than a partial delivery.
 */
export function leadContext(parts: LeadParts): string | null {
  if (parts.skill === "" || parts.guide === "") return null;
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
    payload("everyone"),
    "",
    payload("coordinator"),
  ].join("\n");
}

/** The SessionStart envelope both harnesses accept, as a JSON string. */
export function sessionStartEnvelope(additionalContext: string): string {
  return JSON.stringify({
    hookSpecificOutput: { hookEventName: "SessionStart", additionalContext },
  });
}

/**
 * What a harness receives when nothing is delivered. Claude Code and Antigravity
 * both parse stdout as a response document, so each needs an empty JSON object;
 * Codex treats plain stdout as model context verbatim, so a stray byte there
 * would silently become injected text.
 */
export function emptyOutput(harness: Harness): string {
  return harness === "codex" ? "" : "{}";
}

/** Decide what this session receives, given its harness and resolved role. */
export function composeContext(
  harness: Harness,
  role: Role,
  leadParts: () => LeadParts | null,
): string | null {
  if (role === "none") return null;
  if (role === "worker") return workerContext();
  const parts = leadParts();
  return parts === null ? null : leadContext(parts);
}
