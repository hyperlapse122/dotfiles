/**
 * Durable audit trail for the guard's block path (plan U4, KTD4).
 *
 * A block is rare and today its only trace is the reason string inside that
 * run's own transcript. This appends a session-independent JSONL record
 * instead, so an operator can audit block frequency over time and notice a
 * fail-open pattern silently missing a newly named issue-write tool (R5).
 *
 * Writing happens only on the block path, never on allow: the handler runs on
 * every tool call, so keeping the hot path free of this I/O is what makes the
 * cost of the audit trail proportional to how rarely it fires. The append is
 * wrapped so that a full disk or an unwritable state directory degrades the
 * audit trail, never the guard's verdict — the security decision must never
 * depend on whether this write succeeded.
 */

import { appendFileSync, mkdirSync, statSync, truncateSync } from "node:fs";
import { homedir } from "node:os";
import { dirname, join } from "node:path";

export type AuditOutcome = "unmanaged" | "indeterminate" | "invalid-target";

/**
 * One block's durable trace. Deliberately excludes the command text: it can
 * carry a title or body the user typed, and this file is meant to be safe to
 * hand to an operator auditing block frequency.
 */
export type AuditRecord = {
  tool: string;
  outcome: AuditOutcome;
  /** The target string as classified. The only identifying field present at the invalid-target site. */
  attempted: string;
  /** Resolved `RepoRef` field. `null` exactly when no valid `RepoRef` resolved (the invalid-target site). */
  host: string | null;
  /** Resolved `RepoRef` field. `null` exactly when no valid `RepoRef` resolved (the invalid-target site). */
  repo: string | null;
  /** The probe detail string, `null` when no probe ran. */
  detail: string | null;
};

export type AuditConfig = { enabled: boolean; maxBytes: number };

/** The filesystem surface the audit log needs, so the unit suite never touches a real disk. */
export type AuditFs = {
  /** Current size in bytes; 0 when the path does not exist or cannot be read. */
  size: (path: string) => number;
  /** Empty the file in place (creating its parent directory first). */
  truncate: (path: string) => void;
  /** Append one already newline-terminated line, creating parents and the file as needed. */
  append: (path: string, line: string) => void;
};

export type AuditDeps = {
  config: AuditConfig;
  now?: () => number;
  fs?: AuditFs;
};

const nodeFs: AuditFs = {
  size(path) {
    try {
      return statSync(path).size;
    } catch {
      return 0;
    }
  },
  truncate(path) {
    mkdirSync(dirname(path), { recursive: true });
    truncateSync(path, 0);
  },
  append(path, line) {
    mkdirSync(dirname(path), { recursive: true });
    appendFileSync(path, line);
  },
};

/**
 * Testable core: an injected clock and filesystem, matching the file-local
 * factory style `createProber` (probe.ts) uses for its own `now`/`exec` seams.
 */
export function createAuditLog(deps: AuditDeps) {
  const { config, now = Date.now, fs = nodeFs } = deps;
  // `${XDG_STATE_HOME:-$HOME/.local/state}/unmanaged-repo-guard/blocks.jsonl`.
  const path = config.enabled
    ? join(process.env["XDG_STATE_HOME"] ?? join(homedir(), ".local", "state"), "unmanaged-repo-guard", "blocks.jsonl")
    : null;

  return {
    /** Append one record, or do nothing when disabled. Never throws. */
    record(entry: AuditRecord): void {
      if (path === null) return;
      try {
        const line = `${JSON.stringify({ at: new Date(now()).toISOString(), ...entry })}\n`;
        if (fs.size(path) >= config.maxBytes) fs.truncate(path);
        fs.append(path, line);
      } catch {
        // Swallowed by design (plan KTD4): a full disk or unwritable state
        // directory must degrade the audit trail, never the block verdict.
      }
    },
  };
}
