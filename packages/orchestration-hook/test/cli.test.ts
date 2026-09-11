import { describe, expect, it } from "vite-plus/test";
import { main, type Io } from "../src/cli.js";
import { payload } from "../src/payload.js";

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
      deadlines: { stdinMs: 20, hookMs: 500 },
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

  it("fails loudly on an unknown command", async () => {
    const { io, err } = capture();
    expect(await main(["nonesuch"], io)).toBe(2);
    expect(err.join("")).toContain("nonesuch");
  });
});
