import { chmodSync, mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { describe, expect, it } from "vite-plus/test";
import { main, type Io } from "../src/cli.js";
import { payload } from "../src/payload.js";
import { PREAMBLE } from "../src/envelope.js";

function capture(env: NodeJS.ProcessEnv = {}): { io: Io; out: string[]; err: string[] } {
  const out: string[] = [];
  const err: string[] = [];
  return {
    // Vitest leaves stdin non-TTY with no writer, so the drain would sit on its
    // full production backstop in every hook case. The bound itself is covered
    // by the deployed-binary gate, not here.
    io: {
      stdout: (t) => out.push(t),
      stderr: (t) => err.push(t),
      env,
      deadlines: { stdinMs: 0, hookMs: 500 },
    },
    out,
    err,
  };
}

const ORCA_WORKER = { ORCA_TERMINAL_HANDLE: "term_abc" };

describe("hook fail-open contract", () => {
  it("gives Claude Code an empty JSON object outside Orca, on stdout only", async () => {
    const { io, out, err } = capture({});
    expect(await main(["hook", "--harness", "claude"], io)).toBe(0);
    expect(out.join("")).toBe("{}");
    expect(err.join("")).toBe("");
  });

  it("gives Codex nothing at all outside Orca", async () => {
    const { io, out, err } = capture({});
    expect(await main(["hook", "--harness", "codex"], io)).toBe(0);
    expect(out.join("")).toBe("");
    expect(err.join("")).toBe("");
  });

  it("exits 0 and stays silent on an unknown harness", async () => {
    const { io, out, err } = capture(ORCA_WORKER);
    expect(await main(["hook", "--harness", "nonesuch"], io)).toBe(0);
    expect(out.join("")).toBe("");
    expect(err.join("")).toBe("");
  });

  it("exits 0 when --harness is missing entirely", async () => {
    const { io, err } = capture(ORCA_WORKER);
    expect(await main(["hook"], io)).toBe(0);
    expect(err.join("")).toBe("");
  });

  it("exits 0 on an unparsable extra flag", async () => {
    const { io, err } = capture(ORCA_WORKER);
    expect(await main(["hook", "--harness", "claude", "--nope"], io)).toBe(0);
    expect(err.join("")).toBe("");
  });

  it("charges the stdin drain against the whole-run budget, not on top of it", async () => {
    // The drain and the Orca call share one budget. If the clock started after
    // the drain resolved, a slow producer plus a slow CLI would sum past the
    // bound the harness's own hook timeout sits above.
    const { io } = capture({
      ORCA_TERMINAL_HANDLE: "term_abc",
      ORCA_AGENT_TEAMS_LEADER_PANE: "%7",
      TMUX_PANE: "%7",
    });
    io.deadlines = { stdinMs: 120, hookMs: 60 };
    const started = Date.now();
    expect(await main(["hook", "--harness", "claude"], io)).toBe(0);
    // The drain alone already outruns the budget, so the run must end there
    // rather than starting a fresh 60 ms for the lead path.
    expect(Date.now() - started).toBeLessThan(400);
  });

  it("drives the whole lead path and assembles all four halves", async () => {
    // The lead branch wires readOrchestrationSkill + resolveOrcaCommand +
    // fetchGuide together. Each is unit-tested on its own; without this case the
    // assembled path is only exercised by the CI gate against the built binary.
    const home = mkdtempSync(join(tmpdir(), "orchestration-hook-lead-"));
    try {
      mkdirSync(join(home, ".agents", "skills", "orchestration"), { recursive: true });
      writeFileSync(join(home, ".agents/skills/orchestration/SKILL.md"), "SKILL BODY\n");
      const cli = join(home, "orca-stub");
      writeFileSync(cli, '#!/usr/bin/env bash\nprintf "GUIDE BODY\\n"\n');
      chmodSync(cli, 0o755);

      const { io, out } = capture({
        HOME: home,
        ORCA_CLI_COMMAND: cli,
        ORCA_TERMINAL_HANDLE: "term_abc",
        ORCA_AGENT_TEAMS_LEADER_PANE: "%7",
        TMUX_PANE: "%7",
      });
      expect(await main(["hook", "--harness", "claude"], io)).toBe(0);
      const parsed = JSON.parse(out.join("")) as {
        hookSpecificOutput: { additionalContext: string };
      };
      const context = parsed.hookSpecificOutput.additionalContext;
      for (const half of [
        "SKILL BODY",
        "GUIDE BODY",
        payload("everyone"),
        payload("coordinator"),
      ]) {
        expect(context).toContain(half);
      }
    } finally {
      rmSync(home, { recursive: true, force: true });
    }
  });

  it("delivers nothing to a lead whose Orca CLI fails", async () => {
    const home = mkdtempSync(join(tmpdir(), "orchestration-hook-lead-fail-"));
    try {
      mkdirSync(join(home, ".agents", "skills", "orchestration"), { recursive: true });
      writeFileSync(join(home, ".agents/skills/orchestration/SKILL.md"), "SKILL BODY\n");
      const cli = join(home, "orca-stub");
      writeFileSync(cli, "#!/usr/bin/env bash\nexit 3\n");
      chmodSync(cli, 0o755);

      const { io, out } = capture({
        HOME: home,
        ORCA_CLI_COMMAND: cli,
        ORCA_TERMINAL_HANDLE: "term_abc",
        ORCA_AGENT_TEAMS_LEADER_PANE: "%7",
        TMUX_PANE: "%7",
      });
      expect(await main(["hook", "--harness", "claude"], io)).toBe(0);
      expect(out.join("")).toBe("{}");
    } finally {
      rmSync(home, { recursive: true, force: true });
    }
  });

  it("emits a SessionStart envelope for an Orca-managed worker", async () => {
    const { io, out } = capture(ORCA_WORKER);
    await main(["hook", "--harness", "claude"], io);
    const parsed = JSON.parse(out.join("")) as {
      hookSpecificOutput: { hookEventName: string; additionalContext: string };
    };
    expect(parsed.hookSpecificOutput.hookEventName).toBe("SessionStart");
    expect(parsed.hookSpecificOutput.additionalContext).toContain(payload("everyone"));
    expect(parsed.hookSpecificOutput.additionalContext).not.toContain(payload("coordinator"));
  });
});

describe("agy hook delivery", () => {
  it("delivers the complete lead envelope in order", async () => {
    const home = mkdtempSync(join(tmpdir(), "orchestration-hook-agy-lead-"));
    try {
      mkdirSync(join(home, ".agents", "skills", "orchestration"), { recursive: true });
      writeFileSync(join(home, ".agents/skills/orchestration/SKILL.md"), "SKILL BODY\n");
      const cli = join(home, "orca-stub");
      writeFileSync(cli, '#!/usr/bin/env bash\nprintf "GUIDE BODY\\n"\n');
      chmodSync(cli, 0o755);

      const { io, out } = capture({
        HOME: home,
        ORCA_CLI_COMMAND: cli,
        ORCA_TERMINAL_HANDLE: "term_abc",
        ORCA_AGENT_TEAMS_LEADER_PANE: "%7",
        TMUX_PANE: "%7",
      });
      expect(await main(["hook", "--harness", "agy"], io)).toBe(0);
      const parsed = JSON.parse(out.join("")) as {
        hookSpecificOutput: { additionalContext: string };
      };
      const context = parsed.hookSpecificOutput.additionalContext;
      const order = [
        context.indexOf(PREAMBLE),
        context.indexOf("SKILL BODY"),
        context.indexOf("GUIDE BODY"),
        context.indexOf(payload("everyone")),
        context.indexOf(payload("coordinator")),
      ];
      expect(order.every((i) => i >= 0)).toBe(true);
      expect([...order].sort((a, b) => a - b)).toEqual(order);
    } finally {
      rmSync(home, { recursive: true, force: true });
    }
  });

  it("delivers the everyone envelope to a worker", async () => {
    const { io, out } = capture(ORCA_WORKER);
    expect(await main(["hook", "--harness", "agy"], io)).toBe(0);
    const parsed = JSON.parse(out.join("")) as {
      hookSpecificOutput: { additionalContext: string };
    };
    expect(parsed.hookSpecificOutput.additionalContext).toContain(PREAMBLE);
    expect(parsed.hookSpecificOutput.additionalContext).toContain(payload("everyone"));
    expect(parsed.hookSpecificOutput.additionalContext).not.toContain(payload("coordinator"));
  });

  it("returns a parseable no-op outside Orca", async () => {
    const { io, out } = capture();
    expect(await main(["hook", "--harness", "agy"], io)).toBe(0);
    expect(JSON.parse(out.join(""))).toEqual({});
  });

  it("returns a no-op when the skill is empty", async () => {
    const home = mkdtempSync(join(tmpdir(), "orchestration-hook-agy-empty-skill-"));
    try {
      mkdirSync(join(home, ".agents", "skills", "orchestration"), { recursive: true });
      writeFileSync(join(home, ".agents/skills/orchestration/SKILL.md"), "");
      const { io, out } = capture({
        HOME: home,
        ORCA_TERMINAL_HANDLE: "term_abc",
        ORCA_AGENT_TEAMS_LEADER_PANE: "%7",
        TMUX_PANE: "%7",
      });
      expect(await main(["hook", "--harness", "agy"], io)).toBe(0);
      expect(JSON.parse(out.join(""))).toEqual({});
    } finally {
      rmSync(home, { recursive: true, force: true });
    }
  });

  it("returns a no-op when the guide fetch fails", async () => {
    const home = mkdtempSync(join(tmpdir(), "orchestration-hook-agy-guide-fail-"));
    try {
      mkdirSync(join(home, ".agents", "skills", "orchestration"), { recursive: true });
      writeFileSync(join(home, ".agents/skills/orchestration/SKILL.md"), "SKILL BODY\n");
      const cli = join(home, "orca-stub");
      writeFileSync(cli, "#!/usr/bin/env bash\nexit 3\n");
      chmodSync(cli, 0o755);
      const { io, out } = capture({
        HOME: home,
        ORCA_CLI_COMMAND: cli,
        ORCA_TERMINAL_HANDLE: "term_abc",
        ORCA_AGENT_TEAMS_LEADER_PANE: "%7",
        TMUX_PANE: "%7",
      });
      expect(await main(["hook", "--harness", "agy"], io)).toBe(0);
      expect(JSON.parse(out.join(""))).toEqual({});
    } finally {
      rmSync(home, { recursive: true, force: true });
    }
  });

  it("lists agy among the accepted harness values", async () => {
    const { io, err } = capture();
    expect(await main(["nonesuch"], io)).toBe(2);
    expect(err.join(" ")).toContain("agy");
  });
});

describe("print-payload", () => {
  it("prints the everyone body by default", async () => {
    const { io, out } = capture();
    expect(await main(["print-payload"], io)).toBe(0);
    expect(out.join("")).toBe(payload("everyone"));
  });

  it("prints the coordinator body on request", async () => {
    const { io, out } = capture();
    expect(await main(["print-payload", "--body", "coordinator"], io)).toBe(0);
    expect(out.join("")).toBe(payload("coordinator"));
  });

  it("fails loudly on an unknown body", async () => {
    const { io, out, err } = capture();
    expect(await main(["print-payload", "--body", "nonesuch"], io)).toBe(2);
    expect(out.join("")).toBe("");
    expect(err.join("")).toContain("nonesuch");
  });
});

describe("role", () => {
  it("prints the resolved role and the three inputs it read", async () => {
    const { io, out } = capture({
      ORCA_TERMINAL_HANDLE: "term_abc",
      ORCA_AGENT_TEAMS_LEADER_PANE: "%7",
      TMUX_PANE: "%7",
    });
    expect(await main(["role"], io)).toBe(0);
    const text = out.join("");
    expect(text).toContain("role=lead");
    expect(text).toContain("ORCA_TERMINAL_HANDLE=term_abc");
    expect(text).toContain("ORCA_AGENT_TEAMS_LEADER_PANE=%7");
    expect(text).toContain("TMUX_PANE=%7");
  });

  it("fails loudly on an unknown option, unlike hook", async () => {
    const { io, err } = capture();
    expect(await main(["role", "--nope"], io)).toBe(2);
    expect(err.join("")).toContain("--nope");
  });
});

describe("version and unknown commands", () => {
  it("prints a build identifier", async () => {
    const { io, out } = capture();
    expect(await main(["--version"], io)).toBe(0);
    expect(out.join("").trim()).not.toBe("");
  });

  it("fails open on a bare invocation, the shape a harness can produce by accident", async () => {
    // If a harness ignores the exec-form args array it spawns the binary with
    // no arguments; the usage branch would answer a SessionStart with exit 2
    // and stderr.
    const { io, out, err } = capture();
    expect(await main([], io)).toBe(0);
    expect(out.join("")).toBe("");
    expect(err.join("")).toBe("");
  });

  it("fails loudly on an unknown command", async () => {
    const { io, err } = capture();
    expect(await main(["nonesuch"], io)).toBe(2);
    expect(err.join("")).toContain("nonesuch");
  });
});

function guardIo(env: NodeJS.ProcessEnv, stdin?: string) {
  const out: string[] = [];
  const err: string[] = [];
  return {
    io: { stdout: (t: string) => out.push(t), stderr: (t: string) => err.push(t), env, stdin },
    out,
    err,
  };
}

const LEAD_ENV = {
  ORCA_TERMINAL_HANDLE: "term_abc",
  ORCA_AGENT_TEAMS_LEADER_PANE: "%3",
  TMUX_PANE: "%3",
};

function event(command: string): string {
  return JSON.stringify({
    hook_event_name: "PreToolUse",
    tool_name: "Bash",
    tool_input: { command },
  });
}

describe("guard fail-open contract", () => {
  it("allows with a JSON no-op body on both harnesses", async () => {
    for (const harness of ["claude", "codex"]) {
      const { io, out, err } = guardIo({}, event("codex exec x"));
      expect(await main(["guard", "--harness", harness], io)).toBe(0);
      expect(out.join(""), harness).toBe("{}");
      expect(err.join(""), harness).toBe("");
    }
  });

  it("allows on a body that is not JSON", async () => {
    const { io, out } = guardIo(LEAD_ENV, "not json");
    expect(await main(["guard", "--harness", "claude"], io)).toBe(0);
    expect(out.join("")).toBe("{}");
  });

  it("allows on a JSON body that is not an object", async () => {
    const { io, out } = guardIo(LEAD_ENV, "[1,2,3]");
    expect(await main(["guard", "--harness", "claude"], io)).toBe(0);
    expect(out.join("")).toBe("{}");
  });

  it("allows on an empty body", async () => {
    const { io, out } = guardIo(LEAD_ENV, "");
    expect(await main(["guard", "--harness", "claude"], io)).toBe(0);
    expect(out.join("")).toBe("{}");
  });

  it("allows when --harness is missing or unknown", async () => {
    for (const argv of [["guard"], ["guard", "--harness", "nonesuch"]]) {
      const { io, out, err } = guardIo(LEAD_ENV, event("codex exec x"));
      expect(await main(argv, io)).toBe(0);
      expect(out.join("")).toBe("{}");
      expect(err.join("")).toBe("");
    }
  });
});

describe("guard decisions", () => {
  it("denies a launch in an Orca-managed session", async () => {
    const { io, out } = guardIo(LEAD_ENV, event("codex exec x"));
    expect(await main(["guard", "--harness", "claude"], io)).toBe(0);
    const parsed = JSON.parse(out.join("")) as {
      hookSpecificOutput: { hookEventName: string; permissionDecision: string };
    };
    expect(parsed.hookSpecificOutput.hookEventName).toBe("PreToolUse");
    expect(parsed.hookSpecificOutput.permissionDecision).toBe("deny");
  });

  it("allows the same launch outside Orca", async () => {
    const { io, out } = guardIo({}, event("codex exec x"));
    expect(await main(["guard", "--harness", "claude"], io)).toBe(0);
    expect(out.join("")).toBe("{}");
  });

  it("parses a pretty-printed body rather than stopping at the first newline", async () => {
    const pretty = JSON.stringify(
      { hook_event_name: "PreToolUse", tool_name: "Bash", tool_input: { command: "codex exec x" } },
      null,
      2,
    );
    expect(pretty).toContain("\n");
    const { io, out } = guardIo(LEAD_ENV, pretty);
    expect(await main(["guard", "--harness", "claude"], io)).toBe(0);
    expect(out.join("")).toContain("deny");
  });

  it("explains a verdict without reading stdin", async () => {
    const { io, out } = guardIo(LEAD_ENV);
    expect(await main(["guard", "--harness", "claude", "--explain", "codex exec x"], io)).toBe(0);
    expect(out.join("")).toContain("verdict=deny");
    expect(out.join("")).toContain("role=lead");
  });

  it("explains an allow verdict", async () => {
    const { io, out } = guardIo(LEAD_ENV);
    expect(await main(["guard", "--harness", "claude", "--explain", "git status"], io)).toBe(0);
    expect(out.join("")).toContain("verdict=allow");
  });
});
