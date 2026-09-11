import { readFileSync } from "node:fs";
import { join } from "node:path";
import { describe, expect, it } from "vite-plus/test";
import { decide, extractCommand, isLaunch, type ToolEvent } from "../src/gate.js";
import { scanInvocations } from "../src/command-scan.js";
import type { RoleEnv } from "../src/role.js";

const LEAD: RoleEnv = {
  ORCA_TERMINAL_HANDLE: "term_1",
  ORCA_AGENT_TEAMS_LEADER_PANE: "%3",
  TMUX_PANE: "%3",
};
const WORKER: RoleEnv = {
  ORCA_TERMINAL_HANDLE: "term_1",
  ORCA_AGENT_TEAMS_LEADER_PANE: "%3",
  TMUX_PANE: "%9",
};
const NONE: RoleEnv = {};

function bash(command: string | readonly string[]): ToolEvent {
  return { tool_name: "Bash", tool_input: { command } };
}

describe("decide", () => {
  it("allows everything when the session is not Orca-managed", () => {
    expect(decide("claude", bash("codex exec x"), NONE).deny).toBe(false);
  });

  it("denies a launch for a worker, not only the lead", () => {
    expect(decide("claude", bash("codex exec x"), WORKER).deny).toBe(true);
    expect(decide("claude", bash("codex exec x"), LEAD).deny).toBe(true);
  });

  it("treats an empty ORCA_TERMINAL_HANDLE as unset", () => {
    expect(decide("claude", bash("codex exec x"), { ORCA_TERMINAL_HANDLE: "" }).deny).toBe(false);
  });

  it("names the program, Orca, and the unreachable-Orca fallback in the reason", () => {
    const decision = decide("claude", bash("omp"), LEAD);
    expect(decision.deny).toBe(true);
    if (!decision.deny) return;
    expect(decision.reason).toContain("omp");
    expect(decision.reason).toContain("Orca");
    expect(decision.reason).toContain("do not route around this gate");
  });

  it("allows a tool call that carries no command", () => {
    expect(decide("claude", { tool_name: "Read", tool_input: { file_path: "/x" } }, LEAD).deny).toBe(
      false,
    );
  });

  it("scans an unrecognized tool that still carries a command", () => {
    // Codex renames its shell handler between versions; a name list alone
    // would stop denying with every test still green.
    const event = { tool_name: "some_future_exec", tool_input: { command: "omp" } };
    expect(decide("codex", event, LEAD).deny).toBe(true);
  });

  it("denies an argv-array command", () => {
    expect(decide("codex", bash(["bash", "-lc", "codex exec x"]), LEAD).deny).toBe(true);
  });

  it("allows an unrelated command", () => {
    expect(decide("claude", bash("git status"), LEAD).deny).toBe(false);
    expect(decide("claude", bash('echo "ask claude about it"'), LEAD).deny).toBe(false);
  });

  it("denies a launch hidden behind a shell wrapper", () => {
    expect(decide("claude", bash("bash -c 'codex exec x'"), LEAD).deny).toBe(true);
    expect(decide("claude", bash("git status && omp"), LEAD).deny).toBe(true);
  });

  it("allows the CLI-management surface", () => {
    for (const command of [
      "codex plugin add foo",
      "codex mcp list",
      "claude update",
      "claude --version",
      "omp --help",
      "command -v codex",
    ]) {
      expect(decide("claude", bash(command), LEAD).deny, command).toBe(false);
    }
  });

  it("denies a bare invocation and an exec", () => {
    for (const command of ["codex", "claude", "omp", "codex exec", 'claude -p "hi"']) {
      expect(decide("claude", bash(command), LEAD).deny, command).toBe(true);
    }
  });

  it("decides the captured Claude fixture by its own shape", () => {
    const fixture = JSON.parse(
      readFileSync(join(import.meta.dirname, "fixtures", "pretooluse-claude.json"), "utf8"),
    ) as ToolEvent;
    expect(extractCommand(fixture)).toBe("echo capture-probe");
    expect(decide("claude", fixture, LEAD).deny).toBe(false);

    const launching = { ...fixture, tool_input: { command: "codex exec x" } };
    expect(decide("claude", launching, LEAD).deny).toBe(true);
  });
});

describe("extractCommand", () => {
  it("accepts a string and an argv array, and rejects anything else", () => {
    expect(extractCommand({ tool_input: { command: "ls" } })).toBe("ls");
    expect(extractCommand({ tool_input: { command: ["ls", "-a"] } })).toEqual(["ls", "-a"]);
    expect(extractCommand({ tool_input: { command: 7 } })).toBeNull();
    expect(extractCommand({ tool_input: { command: ["ls", 7] } })).toBeNull();
    expect(extractCommand({ tool_input: null })).toBeNull();
    expect(extractCommand({})).toBeNull();
  });
});

describe("isLaunch", () => {
  const only = (command: string) => scanInvocations(command)[0]!;

  it("counts a bare program as a launch", () => {
    expect(isLaunch(only("codex"))).toBe(true);
  });

  it("counts a management subcommand as not a launch", () => {
    expect(isLaunch(only("codex plugin add x"))).toBe(false);
  });

  it("counts a version or help flag as not a launch", () => {
    expect(isLaunch(only("claude --version"))).toBe(false);
    expect(isLaunch(only("claude --help"))).toBe(false);
  });

  it("counts an unknown subcommand as a launch", () => {
    expect(isLaunch(only("codex exec"))).toBe(true);
    expect(isLaunch(only("codex resume"))).toBe(true);
  });

  it("counts flags that are not version or help as a launch", () => {
    expect(isLaunch(only('claude -p "hi"'))).toBe(true);
  });
});
