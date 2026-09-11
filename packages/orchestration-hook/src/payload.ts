/**
 * The orchestration payload bodies, embedded at build time.
 *
 * Each body has ONE source file under .chezmoitemplates/. chezmoi renders the
 * everyone body into omp's instruction file, which has no session-start
 * injection point and so cannot call this binary; the build embeds the same
 * bytes here. A second copy would be the duplicate-knowledge defect this
 * package exists to remove, so neither body is vendored into src/.
 *
 * Both bodies carry no template actions, which is what lets the build embed
 * raw bytes instead of rendering. `.ci/test-agent-instructions.sh` asserts the
 * everyone body's sentinels and compares omp's delimited block against a
 * standalone render of it; do not reword those sentinels without updating that
 * gate. The coordinator body reaches Claude Code alone — it is the only harness
 * that leads.
 */

import coordinatorText from "../../../.chezmoitemplates/orchestration-coordinator.tmpl" with { type: "text" };
import everyoneText from "../../../.chezmoitemplates/orchestration-everyone.tmpl" with { type: "text" };

export type PayloadBody = "everyone" | "coordinator";

const BODIES: Record<PayloadBody, string> = {
  everyone: everyoneText,
  coordinator: coordinatorText,
};

export function payload(body: PayloadBody): string {
  return BODIES[body];
}

export function isPayloadBody(value: string): value is PayloadBody {
  return value === "everyone" || value === "coordinator";
}
