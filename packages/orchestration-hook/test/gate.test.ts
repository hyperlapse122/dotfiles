import { readFileSync } from "node:fs";
import { join } from "node:path";
import { describe, expect, it } from "vite-plus/test";
import { decide, extractCommand, isLaunch, SHELL_TOOL_NAMES, type ToolEvent } from "../src/gate.js";
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
    expect(decide(bash("codex exec x"), NONE).deny).toBe(false);
  });

  it("denies a launch for a worker, not only the lead", () => {
    expect(decide(bash("codex exec x"), WORKER).deny).toBe(true);
    expect(decide(bash("codex exec x"), LEAD).deny).toBe(true);
  });

  it("treats an empty ORCA_TERMINAL_HANDLE as unset", () => {
    expect(decide(bash("codex exec x"), { ORCA_TERMINAL_HANDLE: "" }).deny).toBe(false);
  });

  it("names the program, Orca, and the unreachable-Orca fallback in the reason", () => {
    const decision = decide(bash("omp"), LEAD);
    expect(decision.deny).toBe(true);
    if (!decision.deny) return;
    expect(decision.reason).toContain("omp");
    expect(decision.reason).toContain("Orca");
    expect(decision.reason).toContain("do not route around this gate");
  });

  it("allows a tool call that carries no command", () => {
    expect(decide({ tool_name: "Read", tool_input: { file_path: "/x" } }, LEAD).deny).toBe(false);
  });

  it("scans an unrecognized tool that still carries a command", () => {
    // Codex renames its shell handler between versions; a name list alone
    // would stop denying with every test still green.
    const event = { tool_name: "some_future_exec", tool_input: { command: "omp" } };
    expect(decide(event, LEAD).deny).toBe(true);
  });

  it("denies an argv-array command", () => {
    expect(decide(bash(["bash", "-lc", "codex exec x"]), LEAD).deny).toBe(true);
  });

  it("allows an unrelated command", () => {
    expect(decide(bash("git status"), LEAD).deny).toBe(false);
    expect(decide(bash('echo "ask claude about it"'), LEAD).deny).toBe(false);
  });

  it("denies a launch hidden behind a shell wrapper", () => {
    expect(decide(bash("bash -c 'codex exec x'"), LEAD).deny).toBe(true);
    expect(decide(bash("git status && omp"), LEAD).deny).toBe(true);
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
      expect(decide(bash(command), LEAD).deny, command).toBe(false);
    }
  });

  it("denies a bare invocation and an exec", () => {
    for (const command of ["codex", "claude", "omp", "codex exec", 'claude -p "hi"']) {
      expect(decide(bash(command), LEAD).deny, command).toBe(true);
    }
  });

  it("decides the captured Claude fixture by its own shape", () => {
    const fixture = JSON.parse(
      readFileSync(join(import.meta.dirname, "fixtures", "pretooluse-claude.json"), "utf8"),
    ) as ToolEvent;
    expect(extractCommand(fixture)).toBe("echo capture-probe");
    expect(decide(fixture, LEAD).deny).toBe(false);

    const launching = { ...fixture, tool_input: { command: "codex exec x" } };
    expect(decide(launching, LEAD).deny).toBe(true);
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

describe("SHELL_TOOL_NAMES", () => {
  it("lists the tool name the captured Claude fixture actually carries", () => {
    const fixture = JSON.parse(
      readFileSync(join(import.meta.dirname, "fixtures", "pretooluse-claude.json"), "utf8"),
    ) as { tool_name: string };
    expect(SHELL_TOOL_NAMES.claude).toContain(fixture.tool_name);
  });
});

describe("evasion", () => {
  // Each of these reached a blocked CLI while the gate allowed it. They are
  // regression cases, not hypotheticals.
  it("denies a launch hidden behind shell grammar", () => {
    for (const command of [
      "{ codex exec; }",
      "(codex exec)",
      "( codex exec )",
      "if true; then codex exec; fi",
      "for i in 1; do codex exec; done",
      "while true; do codex exec; done",
      "eval 'codex exec'",
      'eval "codex exec"',
    ]) {
      expect(decide(bash(command), LEAD).deny, command).toBe(true);
    }
  });

  it("denies a launch whose output is redirected", () => {
    expect(decide(bash("codex exec > /tmp/out"), LEAD).deny).toBe(true);
    expect(decide(bash("codex exec 2>&1 | tee log"), LEAD).deny).toBe(true);
  });

  it("still allows a management command whose output is redirected", () => {
    // Redirection is plumbing. Reading `>` as the subcommand denied a version
    // probe, which is the false-deny half of the same bug.
    for (const command of [
      "codex --version > /tmp/v",
      "claude --version 2>&1",
      "codex plugin add x > out",
      "claude update | tee log",
    ]) {
      expect(decide(bash(command), LEAD).deny, command).toBe(false);
    }
  });
});

describe("evasion, second pass", () => {
  // Every case here reached a blocked CLI while the gate allowed it.
  it("denies when an argument carries an unresolvable expansion", () => {
    // The program is already known; only the argument is opaque. Dropping the
    // whole segment there was the bypass.
    expect(decide(bash("codex exec $(date)"), LEAD).deny).toBe(true);
    expect(decide(bash('codex exec "${HOME}"'), LEAD).deny).toBe(true);
  });

  it("denies when a wrapper flag takes the value that hid the program", () => {
    for (const command of [
      "env -u FOO codex exec",
      "xargs -n 1 codex exec",
      "exec -a nm codex exec",
      "sudo -D /tmp codex exec",
    ]) {
      expect(decide(bash(command), LEAD).deny, command).toBe(true);
    }
  });

  it("denies the real binary behind the wrapper's public link", () => {
    expect(decide(bash("codex-bin exec"), LEAD).deny).toBe(true);
  });

  it("denies a launch flag paired with a version probe", () => {
    // `--version` present is not enough: `-p` starts an agent.
    expect(decide(bash("claude -p --version"), LEAD).deny).toBe(true);
  });

  it("applies the wrapper walk to an argv array too", () => {
    expect(decide(bash(["env", "codex", "exec"]), LEAD).deny).toBe(true);
    expect(decide(bash(["sudo", "-u", "me", "codex", "exec"]), LEAD).deny).toBe(true);
  });
});

describe("evasion, wrapper options", () => {
  it("denies a command carried inside env --split-string", () => {
    // The command lives INSIDE the option's value, so consuming that value as
    // an opaque argument lost the program entirely.
    for (const command of [
      'env -S "codex exec"',
      'env --split-string "codex exec"',
      'env -S"codex exec"',
      'env --split-string="codex exec"',
    ]) {
      expect(decide(bash(command), LEAD).deny, command).toBe(true);
    }
  });

  it("denies when a long wrapper option consumes the value that hid the program", () => {
    for (const command of [
      "xargs --max-args 1 codex exec",
      "sudo --user me codex exec",
      "nice --adjustment 5 codex exec",
      "stdbuf --output L codex exec",
      "timeout --kill-after 1 5 codex exec",
    ]) {
      expect(decide(bash(command), LEAD).deny, command).toBe(true);
    }
  });
});

describe("a heredoc body is data, not commands", () => {
  const patchBody = [
    "apply_patch <<'PATCH'",
    "*** Update File: src/envelope.ts",
    '-export type Harness = "claude" | "codex";',
    '+export type Harness = "claude" | "codex" | "agy";',
    "PATCH",
  ].join("\n");

  it("allows a patch whose content names blocked programs", () => {
    // The union's `|` sits outside quotes, so the splitter read it as two
    // pipeline stages naming bare programs and denied the very edit that
    // widens that union.
    expect(decide(bash(patchBody), LEAD).deny).toBe(false);
  });

  it("still denies a launch that follows the heredoc", () => {
    expect(decide(bash(`${patchBody}\ncodex exec x`), LEAD).deny).toBe(true);
  });

  it("reads an unquoted and a dash-suppressed delimiter the same way", () => {
    for (const opener of ["cat <<EOF", "cat <<-EOF", 'cat <<"EOF"']) {
      const command = [opener, "codex", "EOF"].join("\n");
      expect(decide(bash(command), LEAD).deny, opener).toBe(false);
    }
  });
});

describe("the Antigravity event shape", () => {
  function agy(name: string, args: Record<string, unknown>): ToolEvent {
    return { toolCall: { name, args } };
  }

  it("reads the command out of a nested tool call", () => {
    expect(extractCommand(agy("run_command", { CommandLine: "codex exec x" }))).toBe(
      "codex exec x",
    );
  });

  it("denies a launch carried in that shape", () => {
    expect(decide(agy("run_command", { CommandLine: "claude -p hi" }), LEAD).deny).toBe(true);
  });

  it("allows a tool whose args carry no command at all", () => {
    expect(decide(agy("list_dir", { DirectoryPath: "/tmp" }), LEAD).deny).toBe(false);
  });

  it("denies the Antigravity CLI under both published names", () => {
    for (const program of ["agy", "antigravity"]) {
      expect(decide(bash(`${program} -p hi`), LEAD).deny, program).toBe(true);
    }
  });

  it("leaves the CLI's own management commands alone", () => {
    for (const command of ["agy plugin list", "agy --version", "antigravity mcp"]) {
      expect(decide(bash(command), LEAD).deny, command).toBe(false);
    }
  });

  it("matches the captured fixtures", () => {
    const read = (name: string) =>
      JSON.parse(readFileSync(join(import.meta.dirname, "fixtures", name), "utf8")) as ToolEvent;
    expect(extractCommand(read("pretooluse-agy.json"))).toBe("echo capture-probe");
    expect(extractCommand(read("pretooluse-agy-nonshell.json"))).toBeNull();
    expect(SHELL_TOOL_NAMES.agy).toContain(
      (read("pretooluse-agy.json").toolCall as { name: string }).name,
    );
  });
});
