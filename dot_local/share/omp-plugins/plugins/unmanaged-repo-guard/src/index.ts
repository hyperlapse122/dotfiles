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
import type { AuditAppend, BlockResult, Logger } from "./audit.ts";
import { createBoundedExec } from "./exec.ts";
import type { Exec } from "./exec.ts";
import { createProber } from "./probe.ts";
import { composeReason } from "./reason.ts";
import { resolveCandidates } from "./target.ts";
import { classify } from "./triggers.ts";

type ToolCallEvent = { toolName: string; input: Record<string, unknown> };
type ToolCallContext = { hasUI?: boolean; cwd?: string };
type ToolCallResult = BlockResult | undefined;
type ToolCallHandler = (event: ToolCallEvent, context?: ToolCallContext) => Promise<ToolCallResult>;

export type GuardConfig = { probeTimeoutMs: number; cacheTtlMs: number };

export type GuardDeps = {
  exec: Exec;
  now?: () => number;
  config: GuardConfig;
  logger?: Logger;
  /** Injectable for tests: a recording fake that never touches the filesystem. */
  auditAppend?: AuditAppend;
};

const MIN_MS = 1;
const MAX_MS = 3_600_000;

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
  const auditLog = createAuditLog({ logger: deps.logger, append: deps.auditAppend });

  return async function onToolCall(event, context) {
    const classification = classify(event.toolName, event.input ?? {});
    if (classification.kind !== "issue-write") return undefined;

    const cwdInput = event.input?.["cwd"];
    const cwd = typeof cwdInput === "string" ? cwdInput : context?.cwd;

    const { candidates, invalid } = await resolveCandidates(classification, cwd, exec);
    if (invalid) {
      const repo = classification.repo ?? "an unresolved repository";
      return auditLog.block(
        {
          tool: event.toolName,
          path: "unresolvable-target",
          verdict: "indeterminate",
          repo,
          host: classification.host ?? "unknown",
          hostKind: classification.hostKind ?? "unknown",
          cli: classification.cli ?? "mcp",
        },
        composeReason(
          {
            verdict: "indeterminate",
            detail: "the target repository could not be resolved or failed validation",
            repo,
          },
          context?.hasUI === true,
        ),
      );
    }

    const outcome = await prober.evaluate(candidates);
    if (outcome.verdict === "managed") return undefined;

    return auditLog.block(
      {
        tool: event.toolName,
        path: "unmanaged-verdict",
        verdict: outcome.verdict,
        repo: outcome.repo,
        host: candidates[0]?.host ?? classification.host ?? "unknown",
        hostKind: candidates[0]?.hostKind ?? classification.hostKind ?? "unknown",
        cli: classification.cli ?? "mcp",
      },
      composeReason(outcome, context?.hasUI === true),
    );
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
  return { probeTimeoutMs: probeTimeoutMs as number, cacheTtlMs: cacheTtlMs as number };
}

type OmpExtensionApi = {
  exec: Exec;
  on: (event: "tool_call", handler: ToolCallHandler) => void;
  logger?: Logger;
};

export default function unmanagedRepoGuard(pi: OmpExtensionApi): void {
  const manifestPath = join(dirname(dirname(fileURLToPath(import.meta.url))), "package.json");

  let handler: ToolCallHandler;
  try {
    handler = createGuard({ exec: pi.exec.bind(pi), config: readConfig(manifestPath), logger: pi.logger });
  } catch (error) {
    // omp isolates a factory throw per extension: it would simply mean this
    // extension registers nothing, leaving every issue write unguarded with no
    // signal. A guard that cannot configure itself must still refuse, so
    // register a handler that blocks every recognised issue write outright.
    const detail = error instanceof Error ? error.message : String(error);
    try {
      pi.logger?.error?.(`unmanaged-repo-guard: disabled by configuration error: ${detail}`);
    } catch {
      // A broken logger must never prevent the fail-closed fallback below
      // from registering — that would silently leave every issue write
      // unguarded, the exact failure this catch block exists to prevent.
    }
    const auditLog = createAuditLog({ logger: pi.logger });
    handler = async (event, context) => {
      const classification = classify(event.toolName, event.input ?? {});
      if (classification.kind !== "issue-write") return undefined;
      return auditLog.block(
        {
          tool: event.toolName,
          path: "config-failure",
          verdict: "indeterminate",
          repo: classification.repo ?? "unknown",
          host: classification.host ?? "unknown",
          hostKind: classification.hostKind ?? "unknown",
          cli: classification.cli ?? "mcp",
        },
        `Blocked: the unmanaged-repository guard could not load its configuration (${detail}), so it cannot verify whether the user manages this repository. This gate is fail-closed. ${
          context?.hasUI === true
            ? "Tell the user the guard is misconfigured and let them decide; do not retry."
            : "Do not file. Record the finding in the committed residual-record file and report the misconfiguration."
        }`,
      );
    };
  }

  pi.on("tool_call", handler);
}
