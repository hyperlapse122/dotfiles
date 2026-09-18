import { readFileSync } from "node:fs";
import { type FailureClass, isFailureClass } from "./marker.js";

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
    return isFailureClass(callerReason) ? callerReason : "unknown";
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

  let parsed: unknown;
  try {
    parsed = JSON.parse(content);
  } catch {
    return "unknown";
  }

  const entry = Array.isArray(parsed) ? lastResultEntry(parsed) : parsed;
  if (typeof entry !== "object" || entry === null) {
    return "unknown";
  }

  const record = entry as Record<string, unknown>;
  const status = typeof record["status"] === "number" ? record["status"] : null;
  const text = errorText(record);

  if (status === 429 || QUOTA_PATTERNS.some((p) => p.test(text))) {
    return "quota";
  }

  if (
    (status !== null && status >= 500 && status < 600) ||
    OUTAGE_PATTERNS.some((p) => p.test(text))
  ) {
    return "outage";
  }

  if (status === 401 || CONFIG_PATTERNS.some((p) => p.test(text))) {
    return "configuration";
  }

  return "unknown";
}

function lastResultEntry(messages: unknown[]): unknown {
  return messages.findLast(
    (m) => typeof m === "object" && m !== null && (m as { type?: unknown }).type === "result",
  );
}

// The claude-code-action transcript also holds every tool result, so only the fields that
// carry the API failure are matched. A final answer counts only when the run did not report
// success.
function errorText(record: Record<string, unknown>): string {
  const parts: unknown[] = [record["subtype"], record["message"]];
  if (record["is_error"] !== false) {
    parts.push(record["result"]);
  }
  const error = record["error"];
  if (typeof error === "object" && error !== null) {
    const { type, message } = error as Record<string, unknown>;
    parts.push(type, message);
  } else {
    parts.push(error);
  }
  return parts.filter((p): p is string => typeof p === "string").join("\n");
}
