import { readFileSync } from "node:fs";
import { FAILURE_CLASSES, type FailureClass } from "./marker.js";

export interface ClassifyInput {
  stepOutcome?: string | null;
  actionConclusion?: string | null;
  executionFile?: string | null;
  executionFileContent?: string | null;
  callerReason?: string | null;
}

const QUOTA_PATTERNS = [
  /rate[_\s-]?limit/i,
  /usage[_\s-]?limit/i,
  /quota[_\s-]?exceeded/i,
  /exceeded.*quota/i,
  /insufficient_quota/i,
  /too many requests/i,
];

const OUTAGE_PATTERNS = [
  /overloaded[_\s-]?error/i,
  /\boverloaded\b/i,
  /service unavailable/i,
  /bad gateway/i,
  /gateway timeout/i,
  /internal server error/i,
  /etimedout/i,
  /timeout/i,
  /timed[_\s-]?out/i,
  /econnreset/i,
  /econnrefused/i,
  /enotfound/i,
  /connection error/i,
  /socket hang up/i,
];

const CONFIG_PATTERNS = [
  /authentication[_\s-]?error/i,
  /unauthorized/i,
  /invalid[_\s-]?api[_\s-]?key/i,
  /unauthenticated/i,
  /authentication failed/i,
  /invalid credentials/i,
];

export function classifyFailure(input: ClassifyInput): FailureClass {
  const { callerReason, actionConclusion } = input;

  if (callerReason) {
    if (
      callerReason === "scope-check-failed" ||
      callerReason === "gate-failed" ||
      callerReason === "genuine"
    ) {
      return "genuine";
    }
    if (FAILURE_CLASSES.includes(callerReason as FailureClass)) {
      return callerReason as FailureClass;
    }
    return "unknown";
  }

  if (actionConclusion === "timed_out") {
    return "outage";
  }

  let content = input.executionFileContent;
  if (content === undefined && input.executionFile) {
    try {
      content = readFileSync(input.executionFile, "utf-8");
    } catch {
      return "unknown";
    }
  }

  if (!content) {
    return "unknown";
  }

  let parsed: Record<string, unknown>;
  try {
    const raw = JSON.parse(content);
    if (typeof raw !== "object" || raw === null) {
      return "unknown";
    }
    parsed = raw as Record<string, unknown>;
  } catch {
    return "unknown";
  }

  const status = typeof parsed["status"] === "number" ? parsed["status"] : null;

  if (status === 429 || QUOTA_PATTERNS.some((p) => p.test(content))) {
    return "quota";
  }

  if (
    (status !== null && status >= 500 && status < 600) ||
    OUTAGE_PATTERNS.some((p) => p.test(content))
  ) {
    return "outage";
  }

  if (status === 401 || CONFIG_PATTERNS.some((p) => p.test(content))) {
    return "configuration";
  }

  return "unknown";
}
