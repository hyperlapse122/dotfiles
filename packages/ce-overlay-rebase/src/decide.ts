import semver from "semver";
import { type Marker, createIdleMarker, extractSemverFromTag, isValidTargetTag } from "./marker.js";

export interface RebaseRun {
  status: "queued" | "in_progress" | "completed";
  conclusion?: string | null;
}

export interface OpenPullRequest {
  number: number;
  headRefName: string;
  targetTag?: string;
  createdAt: string;
  autoMergeEnabled: boolean;
}

export interface TrackingIssue {
  number: number;
  state: "open" | "closed";
  title: string;
}

export interface DecideInput {
  resolvedTag: string;
  pin: string;
  gateClass: "valid" | "invalid" | "upstream-unavailable" | (string & {});
  marker: Marker;
  rebaseRuns: RebaseRun[];
  openPullRequests: OpenPullRequest[];
  trackingIssue?: TrackingIssue | null;
  now?: Date | string;
  stateQueryFailed?: boolean;
}

export type DecisionAction = "skip" | "dispatch" | "close-then-dispatch";

export interface DecisionResult {
  action: DecisionAction;
  reason: string;
  closePrNumbers?: number[];
}

function doesPrTargetTag(pr: OpenPullRequest, tag: string): boolean {
  if (pr.targetTag) {
    return pr.targetTag === tag;
  }
  const semverPart = extractSemverFromTag(tag);
  if (semverPart && pr.headRefName.endsWith(`-v${semverPart}`)) {
    return true;
  }
  return false;
}

export function decideDispatch(input: DecideInput): DecisionResult {
  if (input.stateQueryFailed) {
    return { action: "skip", reason: "Failed state query" };
  }

  const { resolvedTag, pin, gateClass, marker, rebaseRuns, openPullRequests, trackingIssue } =
    input;

  if (!isValidTargetTag(resolvedTag)) {
    const tagDisplay = String(resolvedTag);
    return {
      action: "skip",
      reason: `Resolved tag ${tagDisplay} is outside compound-engineering-v<semver> form`,
    };
  }

  const resolvedSemver = extractSemverFromTag(resolvedTag);
  const pinSemver = extractSemverFromTag(pin);

  if (!resolvedSemver || !pinSemver || !semver.gt(resolvedSemver, pinSemver)) {
    return {
      action: "skip",
      reason: `Resolved tag ${resolvedTag} is not newer than pin ${pin}`,
    };
  }

  if (gateClass === "valid") {
    return { action: "skip", reason: "Patches are already valid for resolved tag" };
  }

  if (gateClass === "upstream-unavailable") {
    return { action: "skip", reason: "Upstream unavailable for resolved tag" };
  }

  if (rebaseRuns.some((r) => r.status === "in_progress")) {
    return { action: "skip", reason: "Rebase run in progress" };
  }

  if (rebaseRuns.some((r) => r.status === "queued")) {
    return { action: "skip", reason: "Rebase run queued" };
  }

  if (trackingIssue && trackingIssue.state === "open") {
    return { action: "skip", reason: `Tracking issue #${trackingIssue.number} is open` };
  }

  const nowDate = input.now
    ? typeof input.now === "string"
      ? new Date(input.now)
      : input.now
    : new Date();

  // A stored marker whose target is older than the resolved tag counts as idle
  const markerSemver = extractSemverFromTag(marker.target);
  const isOlderTarget = markerSemver && semver.lt(markerSemver, resolvedSemver);
  const effectiveMarker = isOlderTarget ? createIdleMarker(resolvedTag) : marker;

  if (effectiveMarker.status === "deferred") {
    if (effectiveMarker.notBefore) {
      if (nowDate.getTime() < new Date(effectiveMarker.notBefore).getTime()) {
        return {
          action: "skip",
          reason: `Backoff floor has not passed (notBefore: ${effectiveMarker.notBefore})`,
        };
      }
    }
  }

  if (effectiveMarker.status === "blocked-config") {
    return { action: "skip", reason: "Blocked by configuration prerequisites" };
  }

  if (effectiveMarker.status === "escalated") {
    // Escalate stops retries unless tracking issue is explicitly closed
    if (!trackingIssue || trackingIssue.state !== "closed") {
      return { action: "skip", reason: "Marker is escalated" };
    }
  }

  if (openPullRequests.length > 0) {
    const unhealthPrs: number[] = [];

    for (const pr of openPullRequests) {
      const targetsResolved = doesPrTargetTag(pr, resolvedTag);
      const ageMs = nowDate.getTime() - new Date(pr.createdAt).getTime();
      const isYoungerThan2h = ageMs < 2 * 60 * 60 * 1000;
      const isAwaitingReview = effectiveMarker.status === "awaiting-review" && targetsResolved;
      const isHealthyAutoMerge = targetsResolved && isYoungerThan2h && pr.autoMergeEnabled;

      if (isAwaitingReview) {
        return { action: "skip", reason: "Pull request is awaiting review" };
      }
      if (isHealthyAutoMerge) {
        return { action: "skip", reason: "Healthy pull request open" };
      }

      unhealthPrs.push(pr.number);
    }

    if (unhealthPrs.length > 0) {
      return {
        action: "close-then-dispatch",
        closePrNumbers: unhealthPrs,
        reason: "Superseded or orphaned pull request",
      };
    }
  }

  return { action: "dispatch", reason: "Conditions clear for rebase dispatch" };
}
