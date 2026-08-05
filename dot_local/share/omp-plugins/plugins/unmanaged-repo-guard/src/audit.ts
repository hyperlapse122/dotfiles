/**
 * Durable block-path audit log (plan U5 / R4).
 *
 * Every block the guard returns leaves one JSON-line record here; a
 * pass-through writes nothing (plan KTD7 — a block is rare, so the hot path
 * stays allocation-free). This module is the only place a block result can
 * be constructed: `BlockResult` carries a property keyed by a `unique symbol`
 * that only this file can name, so the type checker — not a text pattern —
 * prevents a second block path from appearing elsewhere in `src/`. A
 * `grep -R "block: true" src` outside this file stays as a cheap early
 * warning alongside the type, because a literal search alone would pass a
 * site written `return { block: someBoolean, reason }`.
 */

import { appendFileSync, mkdirSync } from "node:fs";
import { homedir } from "node:os";
import { dirname, join } from "node:path";

export type Logger = { error?: (message: string) => void };

const BLOCK_TAG: unique symbol = Symbol("unmanaged-repo-guard.block");

/** Only `createAuditLog`'s `block` helper below can produce this shape. */
export type BlockResult = { readonly [BLOCK_TAG]: true; block: true; reason: string };

/** Which of the guard's three block sites fired (plan KTD7). */
export type BlockPath = "unresolvable-target" | "unmanaged-verdict" | "config-failure";

export type AuditEntry = {
  tool: string;
  path: BlockPath;
  verdict: string;
  repo: string;
  host: string;
  hostKind: string;
  cli: string;
};

export type AuditAppend = (entry: AuditEntry) => void;

export type AuditLogDeps = {
  logger?: Logger;
  /** Injectable for tests: a recording fake that never touches the filesystem. */
  append?: AuditAppend;
};

// Keep one line well under 4 KB so concurrent appends from separate omp
// processes stay within the platform's atomic-write guarantee for a single
// `write(2)` on an O_APPEND file descriptor.
const MAX_FIELD_LENGTH = 200;

function truncate(value: string): string {
  return value.length > MAX_FIELD_LENGTH ? `${value.slice(0, MAX_FIELD_LENGTH)}…` : value;
}

function auditLogPath(): string {
  const stateHome = process.env["XDG_STATE_HOME"] || join(homedir(), ".local", "state");
  return join(stateHome, "unmanaged-repo-guard", "audit.jsonl");
}

function defaultAppend(logger?: Logger): AuditAppend {
  return (entry) => {
    try {
      const path = auditLogPath();
      mkdirSync(dirname(path), { recursive: true, mode: 0o700 });
      const line = `${JSON.stringify({
        timestamp: new Date().toISOString(),
        tool: truncate(entry.tool),
        path: entry.path,
        verdict: truncate(entry.verdict),
        repo: truncate(entry.repo),
        host: truncate(entry.host),
        hostKind: truncate(entry.hostKind),
        cli: truncate(entry.cli),
      })}\n`;
      // Append mode, creating the file 0600 if it does not exist yet. A
      // failed append must never change the verdict — the caller already
      // has its block result before this runs.
      appendFileSync(path, line, { mode: 0o600 });
    } catch (error) {
      const detail = error instanceof Error ? error.message : String(error);
      logger?.error?.(`unmanaged-repo-guard: audit log append failed: ${detail}`);
    }
  };
}

/**
 * The seam: the only factory that can hand out a `block` helper capable of
 * producing `BlockResult`. Both `createGuard` and the extension entry point
 * (plan U5 step 4 — the config-failure handler lives outside `createGuard`)
 * import this directly rather than threading it through one deps object.
 */
export function createAuditLog(deps: AuditLogDeps = {}) {
  const append = deps.append ?? defaultAppend(deps.logger);
  return {
    append,
    /** Appends one audit line, then builds the block result carrying `reason`. */
    block(entry: AuditEntry, reason: string): BlockResult {
      append(entry);
      return { [BLOCK_TAG]: true, block: true, reason };
    },
  };
}
