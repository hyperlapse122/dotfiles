/**
 * Unmanaged-repository issue-filing guard (plan U5).
 *
 * Registers one `tool_call` pre-execution handler that blocks an issue write
 * whose target repository the user does not manage. This is a correctness
 * control against an agent following a conflicting skill instruction, not a
 * security boundary against a hostile one (plan KTD9).
 */

import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

import { createAuditLog } from "./audit.ts";
import type { AuditConfig, AuditFs } from "./audit.ts";
import { createBoundedExec } from "./exec.ts";
import type { Exec } from "./exec.ts";
import { createProber } from "./probe.ts";
import { composeReason } from "./reason.ts";
import { resolveCandidates } from "./target.ts";
import { classify } from "./triggers.ts";

type ToolCallEvent = { toolName: string; input: Record<string, unknown> };
type ToolCallContext = { hasUI?: boolean; cwd?: string };
type ToolCallResult = { block: true; reason: string } | undefined;
type ToolCallHandler = (event: ToolCallEvent, context?: ToolCallContext) => Promise<ToolCallResult>;

export type GuardConfig = { probeTimeoutMs: number; cacheTtlMs: number; auditLog: AuditConfig };

export type GuardDeps = {
  exec: Exec;
  now?: () => number;
  config: GuardConfig;
  /** Injected audit filesystem seam; defaults to the real one (plan U4). */
  auditFs?: AuditFs;
};

const MIN_MS = 1;
const MAX_MS = 3_600_000;
const MIN_AUDIT_BYTES = 1024;
const MAX_AUDIT_BYTES = 104_857_600;

/**
 * Testable core: everything the handler needs, injected. The exported default
 * wraps this with the deployed manifest's configuration and omp's `pi.exec`.
 */
export function createGuard(deps: GuardDeps): ToolCallHandler {
  const exec = createBoundedExec(deps.exec, deps.config.probeTimeoutMs);
  const prober = createProber({
    exec,
    now: deps.now ?? Date.now,
    cacheTtlMs: deps.config.cacheTtlMs,
  });
  const audit = createAuditLog({ config: deps.config.auditLog, now: deps.now, fs: deps.auditFs });

  return async function onToolCall(event, context) {
    const classification = classify(event.toolName, event.input ?? {});
    if (classification.kind !== "issue-write") return undefined;

    const cwdInput = event.input?.["cwd"];
    const cwd = typeof cwdInput === "string" ? cwdInput : context?.cwd;

    const { candidates, invalid } = await resolveCandidates(classification, cwd, exec);
    if (invalid) {
      const attempted = classification.repo ?? "an unresolved repository";
      audit.record({
        tool: event.toolName,
        outcome: "invalid-target",
        attempted,
        host: null,
        repo: null,
        detail: null,
      });
      return {
        block: true,
        reason: composeReason(
          {
            verdict: "indeterminate",
            detail: "the target repository could not be resolved or failed validation",
            repo: attempted,
          },
          context?.hasUI === true,
        ),
      };
    }

    const outcome = await prober.evaluate(candidates);
    if (outcome.verdict === "managed") return undefined;

    audit.record({
      tool: event.toolName,
      outcome: outcome.verdict,
      attempted: outcome.repo,
      host: candidates[0]?.host ?? null,
      repo: outcome.repo,
      detail: outcome.detail,
    });
    return { block: true, reason: composeReason(outcome, context?.hasUI === true) };
  };
}

export function readConfig(manifestPath: string): GuardConfig {
  const parsed: unknown = JSON.parse(readFileSync(manifestPath, "utf8"));
  const block =
    typeof parsed === "object" && parsed !== null
      ? (parsed as Record<string, unknown>)["unmanagedRepoGuard"]
      : null;
  if (typeof block !== "object" || block === null) {
    throw new Error("manifest is missing the unmanagedRepoGuard block");
  }
  const record = block as Record<string, unknown>;
  const probeTimeoutMs = record["probeTimeoutMs"];
  const cacheTtlMs = record["cacheTtlMs"];
  for (const [name, value] of [
    ["probeTimeoutMs", probeTimeoutMs],
    ["cacheTtlMs", cacheTtlMs],
  ] as const) {
    if (typeof value !== "number" || !Number.isFinite(value) || value < MIN_MS || value > MAX_MS) {
      throw new Error(`${name} must be a number of milliseconds in ${MIN_MS}..${MAX_MS}`);
    }
  }

  const auditBlock = record["auditLog"];
  if (typeof auditBlock !== "object" || auditBlock === null) {
    throw new Error("unmanagedRepoGuard is missing the auditLog block");
  }
  const auditRecord = auditBlock as Record<string, unknown>;
  const enabled = auditRecord["enabled"];
  if (typeof enabled !== "boolean") {
    throw new Error("unmanagedRepoGuard.auditLog.enabled must be a boolean");
  }
  const maxBytes = auditRecord["maxBytes"];
  if (
    typeof maxBytes !== "number" ||
    !Number.isFinite(maxBytes) ||
    maxBytes < MIN_AUDIT_BYTES ||
    maxBytes > MAX_AUDIT_BYTES
  ) {
    throw new Error(
      `unmanagedRepoGuard.auditLog.maxBytes must be a number of bytes in ${MIN_AUDIT_BYTES}..${MAX_AUDIT_BYTES}`,
    );
  }

  return {
    probeTimeoutMs: probeTimeoutMs as number,
    cacheTtlMs: cacheTtlMs as number,
    auditLog: { enabled, maxBytes },
  };
}

type OmpExtensionApi = {
  exec: Exec;
  on: (event: "tool_call", handler: ToolCallHandler) => void;
  logger?: { error?: (message: string) => void };
};

export default function unmanagedRepoGuard(pi: OmpExtensionApi): void {
  const manifestPath = join(dirname(dirname(fileURLToPath(import.meta.url))), "package.json");

  let handler: ToolCallHandler;
  try {
    handler = createGuard({ exec: pi.exec.bind(pi), config: readConfig(manifestPath) });
  } catch (error) {
    // omp isolates a factory throw per extension: it would simply mean this
    // extension registers nothing, leaving every issue write unguarded with no
    // signal. A guard that cannot configure itself must still refuse, so
    // register a handler that blocks every recognised issue write outright.
    const detail = error instanceof Error ? error.message : String(error);
    pi.logger?.error?.(`unmanaged-repo-guard: disabled by configuration error: ${detail}`);
    handler = async (event, context) => {
      if (classify(event.toolName, event.input ?? {}).kind !== "issue-write") return undefined;
      return {
        block: true,
        reason: `Blocked: the unmanaged-repository guard could not load its configuration (${detail}), so it cannot verify whether the user manages this repository. This gate is fail-closed. ${
          context?.hasUI === true
            ? "Tell the user the guard is misconfigured and let them decide; do not retry."
            : "Do not file. Record the finding in the committed residual-record file and report the misconfiguration."
        }`,
      };
    };
  }

  pi.on("tool_call", handler);
}
