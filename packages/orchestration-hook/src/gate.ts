/**
 * The launch gate: decides whether a tool call may start another agent CLI.
 *
 * Cross-model and cross-harness calling goes through Orca. That rule was text
 * only — nothing stopped an agent from running `codex` from a shell and
 * starting a peer Orca never sees. This module is the enforced half.
 *
 * Two boundaries matter and are easy to conflate:
 *
 *   - WHO is gated. Any session Orca manages, which is every role but `none`.
 *     A worker starting its own peer is the same bypass as the lead doing it.
 *   - WHAT is gated. A launch, not a program. `codex plugin add` runs during
 *     `chezmoi apply`, and denying it would break provisioning on this very
 *     repository. The allowed surface is named rather than negotiated per call.
 *
 * Every path that is not a proven launch allows. A wrong allow leaves the
 * standing rule exactly where it already was; a wrong deny wedges a tool call.
 */

import { scanInvocations, type Invocation } from "./command-scan.js";
import type { Harness } from "./envelope.js";
import { resolveRole, type RoleEnv } from "./role.js";

/**
 * The agent CLIs whose launch belongs to Orca.
 *
 * `codex-bin` is the tokscale wrapper's public link to the real Codex binary.
 * It exists on every provisioned host today, so omitting it would leave a
 * one-word bypass of this whole gate.
 */
export const BLOCKED_PROGRAMS: readonly string[] = ["codex", "codex-bin", "claude", "omp"];

/**
 * Subcommands that manage a CLI rather than start an agent with it.
 *
 * One shared set, not a per-program table: the three CLIs spell these the same
 * way, and a per-program table would invite drift between a name one CLI has
 * and the same name another gains later. Anything absent is a launch, so the
 * unknown case denies.
 */
const NON_LAUNCH_SUBCOMMANDS: ReadonlySet<string> = new Set([
  "plugin",
  "plugins",
  "mcp",
  "login",
  "logout",
  "doctor",
  "update",
  "completion",
  "config",
  "help",
  "version",
]);

/**
 * Flags that ask the CLI about itself instead of starting it.
 *
 * Flags only: a bare `help` word is a subcommand and is matched by
 * NON_LAUNCH_SUBCOMMANDS before this set is ever consulted.
 */
const NON_LAUNCH_FLAGS: ReadonlySet<string> = new Set(["--version", "-V", "--help", "-h"]);

/**
 * What each harness calls its shell tool, as observed in the captured
 * PreToolUse fixtures under `test/fixtures/`.
 *
 * Reference only — `decide` never consults it. Codex renames this handler
 * between versions: rust-v0.154.0 ships `exec_command` under `unified_exec` and
 * carries no `shell` handler at all. A gate keyed on the name would therefore
 * stop denying after an upgrade with every test still green, so the scan keys
 * on the event carrying a command instead. The list is kept because it records
 * that hazard and pins the fixture.
 */
export const SHELL_TOOL_NAMES: Record<Harness, readonly string[]> = {
  claude: ["Bash"],
  codex: ["exec_command", "unified_exec", "shell", "local_shell"],
};

export interface ToolEvent {
  tool_name?: unknown;
  tool_input?: unknown;
}

export type Decision = { deny: true; reason: string } | { deny: false };

/**
 * The command this event would run, or null when it carries none.
 *
 * Accepts a string and an argv array because the two harnesses differ and a
 * future one may differ again.
 */
export function extractCommand(event: ToolEvent): string | readonly string[] | null {
  const input = event.tool_input;
  if (typeof input !== "object" || input === null) return null;
  const command = (input as { command?: unknown }).command;
  if (typeof command === "string") return command;
  if (Array.isArray(command) && command.every((part) => typeof part === "string")) {
    return command as readonly string[];
  }
  return null;
}

/**
 * Whether this invocation of a blocked program would start an agent.
 *
 * A subcommand only counts in the subcommand POSITION. Reading the first
 * non-flag token anywhere let a flag's value stand in for one, and requiring
 * only that SOME argument be `--version` let `claude -p --version` through
 * while `-p` started an agent.
 */
export function isLaunch(invocation: Invocation): boolean {
  const { args } = invocation;
  if (args.length === 0) return true;

  const first = args[0]!;
  if (!first.startsWith("-")) return !NON_LAUNCH_SUBCOMMANDS.has(first);

  // Flags only: every one of them must be a self-describing probe. One flag
  // that is not turns the whole invocation back into a launch.
  return !args.every((arg) => NON_LAUNCH_FLAGS.has(arg));
}

function denyReason(program: string): string {
  return (
    `Launching \`${program}\` from a shell is not available in an Orca-managed session. ` +
    "Cross-model and cross-harness calling goes through Orca, under the `orchestration` " +
    "skill's dispatch workflow, so the peer this would start is one Orca cannot supervise. " +
    "Open that skill and dispatch the work as an Orca task instead. " +
    "If Orca itself is unreachable, report the failed command and its error and continue " +
    "with your own reasoning — do not route around this gate. " +
    `Managing the CLI is still available: \`${program} --version\`, \`${program} plugin\`, ` +
    `\`${program} mcp\`, and \`${program} update\` are not affected.`
  );
}

/** Decide whether this tool call may proceed. */
export function decide(event: ToolEvent, env: RoleEnv): Decision {
  if (resolveRole(env) === "none") return { deny: false };

  const command = extractCommand(event);
  if (command === null) return { deny: false };

  // Carrying a command is the test, not the tool's name. `SHELL_TOOL_NAMES`
  // documents what each harness calls its shell tool today; it deliberately
  // does not gate the scan, because a renamed or absent name would then make
  // the gate allow everything while every test stayed green.
  for (const invocation of scanInvocations(command)) {
    if (!BLOCKED_PROGRAMS.includes(invocation.program)) continue;
    if (isLaunch(invocation)) return { deny: true, reason: denyReason(invocation.program) };
  }
  return { deny: false };
}
