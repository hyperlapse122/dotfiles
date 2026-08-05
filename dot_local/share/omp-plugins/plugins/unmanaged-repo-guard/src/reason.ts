/**
 * Blocked-call reason composer (plan U4).
 *
 * The reason string is the entire interface between the guard and the blocked
 * agent's next decision, so plan R12-R14 specify it as a contract: name the
 * target and the probe outcome, say that another route hits the same gate, and
 * name exactly one sanctioned next move for the current run.
 */

import type { ProbeOutcome } from "./probe.ts";

export function composeReason(outcome: ProbeOutcome, hasUI: boolean): string {
  const cause =
    outcome.verdict === "unmanaged"
      ? `Your account does not have write access to it (${outcome.detail}).`
      : `The access check could not complete (${outcome.detail}), and this gate is fail-closed, so an undecidable check blocks rather than allows. This is not a statement that you lack access.`;

  // The guard has no channel through which a user's consent could reach it, so
  // it must not imply that asking will unlock a retry. Attended runs still ask,
  // because the user may want to act themselves — but the agent's own filing
  // call stays blocked either way.
  const nextMove = hasUI
    ? "Do not retry this call. Tell the user what you would have filed — target repository, proposed title, proposed body — and let them decide and act themselves; this gate cannot be lifted by their answer, because the guard has no way to receive consent."
    : "This run is unattended, so do not file. Record the finding in the committed residual-record file instead, and report it in your run summary.";

  return [
    `Blocked: issue write into ${outcome.repo}, a repository the user does not manage.`,
    cause,
    "Retrying through a different CLI, flag shape, or tool route reaches the same gate, so this is not a transient error to work around.",
    nextMove,
  ].join(" ");
}
