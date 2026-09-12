/**
 * Command surface for the orchestration hook.
 *
 * `hook` and `guard` fail open: every error, unknown flag, and unparsable
 * argument still yields that harness's no-op output and exit 0. A SessionStart
 * hook that errors delays or blocks session start, and a PreToolUse hook that
 * errors breaks every tool call in the session. Both are worse than the thing
 * the hook failed to do. Every other subcommand uses ordinary CLI conventions —
 * diagnostics on stderr and a non-zero exit — so an operator's typo and a
 * session failure never share one code path.
 *
 * This surface is for operators and tests. No MCP tool, skill, or slash command
 * wraps it.
 */

import { execFileSync } from "node:child_process";
import { StringDecoder } from "node:string_decoder";
import { readFileSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";
import {
  composeContext,
  deliveryEnvelope,
  emptyOutput,
  type Harness,
  isHarness,
} from "./envelope.js";
import { decide, type ToolEvent } from "./gate.js";
import { scanInvocations } from "./command-scan.js";
import { isPayloadBody, payload } from "./payload.js";
import { resolveRole, type RoleEnv } from "./role.js";
import { fetchGuide, resolveOrcaCommand } from "./orca.js";

/** Bounds the whole `hook` run, so a slow stdin drain and a slow Orca call cannot sum past it. */
const HOOK_DEADLINE_MS = 8_000;
/** Stops at the event's own newline; this is the backstop for a producer that sends none. */
const STDIN_DEADLINE_MS = 3_000;
/**
 * The guard's own stdin bound, deliberately much smaller than the SessionStart
 * one: this path runs on EVERY tool call, so the budget is a latency cost the
 * user pays all day rather than once at session start.
 */
const GUARD_STDIN_DEADLINE_MS = 500;

// Dot notation, not a bracket read: `bun build --define` substitutes this exact
// expression at compile time, which is what puts the id inside the binary. The
// deployed hook runs with an empty environment, so a runtime read is always
// empty and `--version` would say nothing useful.
const BUILD_ID: string = process.env.DOTFILES_HOOK_BUILD_ID ?? "dev";

export interface Io {
  stdout: (text: string) => void;
  stderr: (text: string) => void;
  env: NodeJS.ProcessEnv;
  /** Overrides the production bounds. Tests set these; the hook path does not. */
  deadlines?: { hookMs?: number; stdinMs?: number; guardStdinMs?: number } | undefined;
  /**
   * Supplies the event body instead of reading the real stdin. Tests set it;
   * the deployed hook never does, so the production path stays the one the
   * built-binary gate exercises.
   */
  stdin?: string | undefined;
}

function flagValue(argv: readonly string[], name: string): string | undefined {
  const index = argv.indexOf(name);
  if (index < 0) return undefined;
  return argv[index + 1];
}

/** The harness this invocation names, or null when it names none this binary serves. */
function requestedHarness(argv: readonly string[]): Harness | null {
  const requested = flagValue(argv, "--harness") ?? "";
  return isHarness(requested) ? requested : null;
}

/**
 * Consume the event JSON the harness writes to stdin.
 *
 * Codex pipes one JSON line and may keep the descriptor open afterwards, so a
 * byte-counting read would wait on an EOF that never comes and hold up session
 * start. Stop at the newline; the timer is only the backstop.
 */
async function drainStdin(deadlineMs: number): Promise<void> {
  await readStdin(deadlineMs, (chunk) => chunk.includes(0x0a));
}

/**
 * Read stdin until `isComplete` accepts what has arrived, EOF, or the deadline.
 *
 * `hook` stops at the first newline and throws the bytes away. `guard` needs
 * the bytes and cannot stop at a newline: a pretty-printed event body has one
 * after every field, and stopping there would truncate the JSON into garbage
 * that parses as nothing — which fails open, so the gate would silently stop
 * denying.
 */
async function readStdin(
  deadlineMs: number,
  isComplete: (chunk: Buffer, text: string) => boolean,
): Promise<string> {
  if (process.stdin.isTTY) return "";
  return await new Promise<string>((resolve) => {
    // A multi-byte character can straddle two chunks; decoding each chunk on
    // its own would corrupt it and change the text the scanner sees.
    const decoder = new StringDecoder("utf8");
    let text = "";
    let done = false;
    const onData = (chunk: Buffer) => {
      text += decoder.write(chunk);
      if (isComplete(chunk, text)) finish();
    };
    const finish = () => {
      if (done) return;
      done = true;
      clearTimeout(timer);
      // Every listener, not just "data": process.stdin is a singleton, so a
      // leaked "end" or "error" closure accumulates across calls.
      process.stdin.removeListener("data", onData);
      process.stdin.removeListener("end", finish);
      process.stdin.removeListener("error", finish);
      process.stdin.pause();
      resolve(text + decoder.end());
    };
    const timer = setTimeout(finish, deadlineMs);
    process.stdin.on("data", onData);
    process.stdin.on("end", finish);
    process.stdin.on("error", finish);
    process.stdin.resume();
  });
}

/**
 * The parsed document, or null while it is still incomplete or malformed.
 *
 * Returning the value rather than a boolean is what keeps the guard to ONE
 * parse: the completion check already built the object graph, and discarding it
 * to rebuild it a line later doubles the cost on a per-tool-call path. The
 * cheap suffix test in front skips the throw-and-catch entirely for the common
 * partial chunk.
 */
function parseWhenComplete(text: string): unknown {
  const trimmed = text.trimEnd();
  if (!trimmed.endsWith("}") && !trimmed.endsWith("]")) return null;
  try {
    return JSON.parse(trimmed);
  } catch {
    return null;
  }
}

function unameS(): string | undefined {
  try {
    return execFileSync("uname", ["-s"], { encoding: "utf8" }).trim();
  } catch {
    return undefined;
  }
}

function readOrchestrationSkill(env: NodeJS.ProcessEnv): string {
  const home = env["HOME"] ?? homedir();
  try {
    return readFileSync(join(home, ".agents", "skills", "orchestration", "SKILL.md"), "utf8");
  } catch {
    return "";
  }
}

async function runHook(argv: readonly string[], io: Io): Promise<number> {
  // The clock starts here, before the drain, because the budget bounds the
  // WHOLE run. Starting it after the drain resolved would hand the Orca call a
  // full budget on top of however long the drain took, so a slow producer and
  // a slow CLI could sum past the bound the harness's own hook timeout sits
  // above.
  const started = Date.now();
  const harness = requestedHarness(argv);

  // Codex pipes the event JSON and would see a broken pipe if this exited
  // first. Drain before any decision, including the not-Orca-managed one.
  await drainStdin(io.deadlines?.stdinMs ?? STDIN_DEADLINE_MS);

  // An unnamed or unknown harness takes the quieter of the two empty outputs:
  // a stray byte on a Codex session's stdout becomes injected model context.
  if (harness === null) {
    io.stdout(emptyOutput("codex"));
    return 0;
  }

  const role = resolveRole(io.env as RoleEnv);

  let leadParts: { skill: string; guide: string } | null = null;
  if (role === "lead") {
    const skill = readOrchestrationSkill(io.env);
    if (skill !== "") {
      const command = resolveOrcaCommand({
        configured: io.env["ORCA_CLI_COMMAND"],
        platform: unameS,
      });
      const budget = io.deadlines?.hookMs ?? HOOK_DEADLINE_MS;
      const remaining = budget - (Date.now() - started);
      const guide = await fetchGuide({ command, deadlineMs: remaining });
      if (guide !== null) leadParts = { skill, guide };
    }
  }

  const context = composeContext(harness, role, () => leadParts);
  io.stdout(context === null ? emptyOutput(harness) : deliveryEnvelope(harness, context));
  return 0;
}

/**
 * What a harness receives from `guard` when nothing is denied.
 *
 * `{}` on every harness, not `emptyOutput`'s empty string for Codex.
 * SessionStart treats bare Codex stdout as model context, which is why that
 * path emits nothing; a tool-use response is parsed as a decision document
 * instead, and an empty body risks a deserialization error on a path that must
 * never fail loudly. `{}` is "no decision" everywhere.
 *
 * Antigravity would also accept an explicit allow here, and it must not get
 * one: an allow from a hook overrides that harness's own permission prompt, so
 * this gate would quietly auto-approve every tool call it did not deny. Saying
 * nothing leaves the user's permission rules to decide.
 */
function guardAllowOutput(): string {
  return "{}";
}

/**
 * The denial, in the document shape the harness actually reads.
 *
 * A response in the wrong shape is silently ignored, which reads as a gate that
 * denies nothing at all — the failure the whole real-binary gate exists to
 * catch, and one no diff shows.
 */
function guardDenyOutput(harness: Harness, reason: string): string {
  if (harness === "agy") return JSON.stringify({ decision: "deny", reason });
  return JSON.stringify({
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      permissionDecision: "deny",
      permissionDecisionReason: reason,
    },
  });
}

/**
 * The PreToolUse launch gate.
 *
 * Fails open on every path. A hook that errors on a per-tool-call surface would
 * break every tool call in the session, which is a far worse outcome than a
 * launch this gate misses — the standing rule still covers that case in text.
 */
async function runGuard(argv: readonly string[], io: Io): Promise<number> {
  const harness = requestedHarness(argv);

  const explained = flagValue(argv, "--explain");
  if (explained !== undefined) {
    const role = resolveRole(io.env as RoleEnv);
    const decision = decide({ tool_input: { command: explained } }, io.env);
    const invocations = scanInvocations(explained)
      .map((i) => `${i.program}${i.next === undefined ? "" : ` ${i.next}`}`)
      .join(", ");
    io.stdout(
      `role=${role}\nverdict=${decision.deny ? "deny" : "allow"}\n` +
        `invocations=${invocations === "" ? "(none)" : invocations}\n` +
        (decision.deny ? `reason=${decision.reason}\n` : ""),
    );
    return 0;
  }

  // Outside Orca the verdict is already known, so the body is drained but never
  // parsed. That is the common case on this per-tool-call path: an ordinary
  // session pays a drain, not a JSON decode, on every command it runs.
  const gated = resolveRole(io.env as RoleEnv) !== "none";

  let parsed: unknown = null;
  if (io.stdin !== undefined) {
    parsed = gated ? parseWhenComplete(io.stdin) : null;
  } else {
    const deadline = io.deadlines?.guardStdinMs ?? GUARD_STDIN_DEADLINE_MS;
    if (gated) {
      // The completion check hands back the document it already built, so the
      // event is parsed exactly once.
      await readStdin(deadline, (_chunk, text) => {
        parsed = parseWhenComplete(text);
        return parsed !== null;
      });
    } else {
      // Drain without decoding: outside Orca the verdict is already known. Stop
      // at a newline OR at a closing brace, because a producer that sends one
      // JSON line with no trailing newline would otherwise sit on the full
      // deadline on every single tool call.
      await readStdin(
        deadline,
        (chunk, text) => chunk.includes(0x0a) || text.trimEnd().endsWith("}"),
      );
    }
  }

  // An unnamed harness still drained stdin first, for the same reason.
  if (harness === null || !gated || typeof parsed !== "object" || parsed === null) {
    io.stdout(guardAllowOutput());
    return 0;
  }

  const decision = decide(parsed as ToolEvent, io.env);
  io.stdout(decision.deny ? guardDenyOutput(harness, decision.reason) : guardAllowOutput());
  return 0;
}

function runPrintPayload(argv: readonly string[], io: Io): number {
  const body = flagValue(argv, "--body") ?? "everyone";
  if (!isPayloadBody(body)) {
    io.stderr(`orchestration-hook: unknown payload body ${JSON.stringify(body)}\n`);
    return 2;
  }
  io.stdout(payload(body));
  return 0;
}

function runRole(argv: readonly string[], io: Io): number {
  const unknown = argv.find((arg) => arg.startsWith("-"));
  if (unknown !== undefined) {
    io.stderr(`orchestration-hook: unknown option ${JSON.stringify(unknown)}\n`);
    return 2;
  }
  const env = io.env as RoleEnv;
  const lines = [
    `role=${resolveRole(env)}`,
    `ORCA_TERMINAL_HANDLE=${env.ORCA_TERMINAL_HANDLE ?? ""}`,
    `ORCA_AGENT_TEAMS_LEADER_PANE=${env.ORCA_AGENT_TEAMS_LEADER_PANE ?? ""}`,
    `TMUX_PANE=${env.TMUX_PANE ?? ""}`,
  ];
  io.stdout(`${lines.join("\n")}\n`);
  return 0;
}

export async function main(argv: readonly string[], io: Io): Promise<number> {
  const [command = "", ...rest] = argv;

  // A bare invocation fails open rather than printing usage. This is the one
  // shape a harness can produce by accident on the session-start path: if it
  // ignores the exec-form `args` array it spawns the binary with no arguments
  // at all, and the usage branch below would answer a SessionStart with a
  // non-zero exit and stderr — the single non-fail-open outcome there. An
  // operator who types the bare name loses a usage message; a session never
  // loses its start.
  if (argv.length === 0) {
    io.stdout(emptyOutput("codex"));
    return 0;
  }

  if (command === "guard") {
    try {
      return await runGuard(rest, io);
    } catch {
      // Fail open: this path runs on every tool call, so an internal fault must
      // never turn into a denied or broken tool call.
      io.stdout(guardAllowOutput());
      return 0;
    }
  }

  if (command === "hook") {
    try {
      return await runHook(rest, io);
    } catch {
      // Fail open: never let an internal fault reach session start as an error.
      io.stdout(emptyOutput(requestedHarness(rest) ?? "codex"));
      return 0;
    }
  }

  switch (command) {
    case "print-payload":
      return runPrintPayload(rest, io);
    case "role":
      return runRole(rest, io);
    case "--version":
    case "version":
      io.stdout(`${BUILD_ID}\n`);
      return 0;
    default:
      io.stderr(
        `orchestration-hook: unknown command ${JSON.stringify(command)}\n` +
          "usage: orchestration-hook <hook --harness <claude|codex|agy> | " +
          "guard --harness <claude|codex|agy> [--explain <command>] | " +
          "print-payload [--body <everyone|coordinator>] | role | --version>\n",
      );
      return 2;
  }
}

const isEntrypoint = process.argv[1] !== undefined && import.meta.main !== false;
if (isEntrypoint) {
  const io: Io = {
    stdout: (text) => process.stdout.write(text),
    stderr: (text) => process.stderr.write(text),
    env: process.env,
  };
  main(process.argv.slice(2), io)
    .then((code) => {
      process.exitCode = code;
    })
    .catch(() => {
      process.exitCode = 1;
    });
}
