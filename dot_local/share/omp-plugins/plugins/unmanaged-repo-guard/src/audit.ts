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

import { closeSync, constants, lstatSync, mkdirSync, openSync, writeSync } from "node:fs";
import { homedir } from "node:os";
import { dirname, join } from "node:path";
const { O_APPEND, O_CREAT, O_NOFOLLOW, O_WRONLY } = constants;

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
      // Refuse a planted symlink leaf: the guard constrains an LLM-driven
      // agent with bash access, so a co-resident process pre-creating
      // ~/.local/state/.../audit.jsonl as a symlink must not redirect the
      // audit write. O_NOFOLLOW also makes the open itself reject a link.
      try {
        const st = lstatSync(path);
        if (st.isSymbolicLink()) return;
      } catch {
        // No existing entry — the open below creates it.
      }
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
      // O_NOFOLLOW rejects a symlink target at open; mode 0o600 on create.
      // A failed append must never change the verdict — the caller already
      // has its block result before this runs.
      const fd = openSync(path, O_APPEND | O_CREAT | O_WRONLY | O_NOFOLLOW, 0o600);
      try {
        writeSync(fd, line);
      } finally {
        closeSync(fd);
      }
    } catch (error) {
      const detail = error instanceof Error ? error.message : String(error);
      // A broken logger must never turn an already-handled append failure
      // into an unhandled throw that escapes the block path.
      try {
        logger?.error?.(`unmanaged-repo-guard: audit log append failed: ${detail}`);
      } catch {
        /* swallow: logging must never escape the audit append */
      }
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
