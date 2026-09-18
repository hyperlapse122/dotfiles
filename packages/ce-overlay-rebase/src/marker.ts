import semver from "semver";

export const MARKER_STATUSES = [
  "idle",
  "deferred",
  "escalated",
  "blocked-config",
  "awaiting-review",
] as const;
export type MarkerStatus = (typeof MARKER_STATUSES)[number];

export const FAILURE_CLASSES = ["outage", "quota", "genuine", "unknown", "configuration"] as const;
export type FailureClass = (typeof FAILURE_CLASSES)[number];

export const MISSING_PREREQUISITES = ["P1", "P2", "P3", "P4"] as const;
export type MissingPrerequisite = (typeof MISSING_PREREQUISITES)[number];

export interface Marker {
  target: string;
  status: MarkerStatus;
  attempts: number;
  firstAttempt: string | null;
  lastAttempt: string | null;
  notBefore: string | null;
  failureClass: FailureClass | null;
  missing: MissingPrerequisite[];
  issue: number | null;
}

export interface MarkerDocument {
  ceOverlayRebase: Marker;
}

const REQUIRED_KEYS: (keyof Marker)[] = [
  "target",
  "status",
  "attempts",
  "firstAttempt",
  "lastAttempt",
  "notBefore",
  "failureClass",
  "missing",
  "issue",
];

const TARGET_PREFIX = "compound-engineering-v";
const TAG_PATTERN =
  /^compound-engineering-v\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?(?:\+[0-9A-Za-z.-]+)?$/;

export function extractSemverFromTag(tag: string): string | null {
  if (!tag.startsWith(TARGET_PREFIX)) {
    return null;
  }
  const version = tag.slice(TARGET_PREFIX.length);
  return semver.valid(version);
}

export function isValidTargetTag(tag: unknown): tag is string {
  if (typeof tag !== "string" || !TAG_PATTERN.test(tag)) {
    return false;
  }
  return extractSemverFromTag(tag) !== null;
}

export interface ValidationResult {
  valid: boolean;
  errors: string[];
}

export function validateMarker(val: unknown): ValidationResult {
  const errors: string[] = [];
  if (typeof val !== "object" || val === null || Array.isArray(val)) {
    return { valid: false, errors: ["marker must be a non-null object"] };
  }

  const record = val as Record<string, unknown>;

  for (const key of REQUIRED_KEYS) {
    if (!(key in record)) {
      errors.push(`missing key: ${key}`);
    }
  }

  if (
    typeof record["status"] !== "string" ||
    !MARKER_STATUSES.includes(record["status"] as MarkerStatus)
  ) {
    errors.push(`invalid status: ${String(record["status"])}`);
  }

  if (!isValidTargetTag(record["target"])) {
    errors.push(
      `target outside tag form compound-engineering-v<semver>: ${String(record["target"])}`,
    );
  }

  if (
    typeof record["attempts"] !== "number" ||
    !Number.isInteger(record["attempts"]) ||
    record["attempts"] < 0
  ) {
    errors.push(`attempts must be a non-negative integer: ${String(record["attempts"])}`);
  }

  for (const dateKey of ["firstAttempt", "lastAttempt", "notBefore"] as const) {
    const v = record[dateKey];
    if (v !== null && (typeof v !== "string" || Number.isNaN(Date.parse(v)))) {
      errors.push(`${dateKey} must be a valid ISO 8601 string or null: ${JSON.stringify(v)}`);
    }
  }

  if (
    record["failureClass"] !== null &&
    (typeof record["failureClass"] !== "string" ||
      !FAILURE_CLASSES.includes(record["failureClass"] as FailureClass))
  ) {
    errors.push(`failureClass must be one of ${FAILURE_CLASSES.join(", ")} or null`);
  }

  if (!Array.isArray(record["missing"])) {
    errors.push("missing must be an array");
  } else {
    for (const m of record["missing"]) {
      if (typeof m !== "string" || !MISSING_PREREQUISITES.includes(m as MissingPrerequisite)) {
        errors.push(`missing item outside P1-P4: ${String(m)}`);
      }
    }
  }

  if (
    record["issue"] !== null &&
    (typeof record["issue"] !== "number" ||
      !Number.isInteger(record["issue"]) ||
      record["issue"] <= 0)
  ) {
    errors.push(`issue must be a positive integer or null: ${JSON.stringify(record["issue"])}`);
  }

  return {
    valid: errors.length === 0,
    errors,
  };
}

export function validateMarkerDocument(val: unknown): ValidationResult {
  if (typeof val !== "object" || val === null || Array.isArray(val)) {
    return { valid: false, errors: ["document must be a non-null object"] };
  }
  const record = val as Record<string, unknown>;
  if (!("ceOverlayRebase" in record)) {
    return { valid: false, errors: ["missing top-level key: ceOverlayRebase"] };
  }
  return validateMarker(record["ceOverlayRebase"]);
}

export function createIdleMarker(target = "compound-engineering-v3.26.3"): Marker {
  return {
    target,
    status: "idle",
    attempts: 0,
    firstAttempt: null,
    lastAttempt: null,
    notBefore: null,
    failureClass: null,
    missing: [],
    issue: null,
  };
}

export function resetMarker(target: string): Marker {
  return createIdleMarker(target);
}

export interface FailureEvent {
  type: "failure";
  target: string;
  failureClass: FailureClass;
  reachedClaude?: boolean;
  missing?: MissingPrerequisite[];
  now?: Date | string;
  manualTrigger?: boolean;
  issue?: number | null;
}

export interface AwaitingReviewEvent {
  type: "awaiting-review";
  target: string;
  now?: Date | string;
  issue?: number | null;
}

export interface ResetEvent {
  type: "reset";
  target: string;
}

export type MarkerEvent = FailureEvent | AwaitingReviewEvent | ResetEvent;

export function transitionMarker(current: Marker, event: MarkerEvent): Marker {
  if (event.type === "reset") {
    return resetMarker(event.target);
  }

  const nowDate = event.now
    ? typeof event.now === "string"
      ? new Date(event.now)
      : event.now
    : new Date();
  const nowIso = nowDate.toISOString();

  if (event.type === "awaiting-review") {
    return {
      target: event.target,
      status: "awaiting-review",
      attempts: current.attempts,
      firstAttempt: current.firstAttempt ?? nowIso,
      lastAttempt: nowIso,
      notBefore: null,
      failureClass: null,
      missing: [],
      issue: event.issue !== undefined ? event.issue : current.issue,
    };
  }

  // failure event
  const currentSemver = extractSemverFromTag(current.target);
  const eventSemver = extractSemverFromTag(event.target);
  const isNewerTarget = currentSemver && eventSemver && semver.gt(eventSemver, currentSemver);
  const isResetRun = Boolean(isNewerTarget || event.manualTrigger);

  let attempts = isResetRun ? 0 : current.attempts;
  let firstAttempt = isResetRun ? null : current.firstAttempt;

  const failureClass = event.failureClass;

  if (failureClass === "configuration") {
    return {
      target: event.target,
      status: "blocked-config",
      attempts,
      firstAttempt: firstAttempt ?? nowIso,
      lastAttempt: nowIso,
      notBefore: null,
      failureClass: "configuration",
      missing: event.missing ?? [],
      issue: event.issue !== undefined ? event.issue : current.issue,
    };
  }

  if (event.reachedClaude !== false) {
    attempts += 1;
  }
  if (!firstAttempt) {
    firstAttempt = nowIso;
  }

  const firstAttemptDate = new Date(firstAttempt);
  const durationSinceFirstAttempt = nowDate.getTime() - firstAttemptDate.getTime();
  const exceededTimeLimit = durationSinceFirstAttempt >= 24 * 60 * 60 * 1000;

  if (failureClass === "genuine" || failureClass === "unknown") {
    return {
      target: event.target,
      status: "escalated",
      attempts,
      firstAttempt,
      lastAttempt: nowIso,
      notBefore: null,
      failureClass,
      missing: [],
      issue: event.issue !== undefined ? event.issue : current.issue,
    };
  }

  // outage or quota
  if (attempts >= 3 || exceededTimeLimit) {
    return {
      target: event.target,
      status: "escalated",
      attempts,
      firstAttempt,
      lastAttempt: nowIso,
      notBefore: null,
      failureClass,
      missing: [],
      issue: event.issue !== undefined ? event.issue : current.issue,
    };
  }

  const floorHours = failureClass === "outage" ? 2 : 6;
  const notBeforeDate = new Date(nowDate.getTime() + floorHours * 60 * 60 * 1000);

  return {
    target: event.target,
    status: "deferred",
    attempts,
    firstAttempt,
    lastAttempt: nowIso,
    notBefore: notBeforeDate.toISOString(),
    failureClass,
    missing: [],
    issue: event.issue !== undefined ? event.issue : current.issue,
  };
}
