import { chmodSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";
import { DatabaseSync } from "node:sqlite";
import { describe, expect, it } from "vite-plus/test";
import { main, type Io } from "../src/cli.js";
import { PREAMBLE } from "../src/envelope.js";

// The binary reads its two bodies from managed files, so every case here points
// the resolver at a fixture pair rather than at whatever this host applied.
const FIXTURES = join(dirname(fileURLToPath(import.meta.url)), "fixtures", "payload");
const EVERYONE = readFileSync(join(FIXTURES, "everyone.md"), "utf8");
const COORDINATOR = readFileSync(join(FIXTURES, "coordinator.md"), "utf8");

function capture(env: NodeJS.ProcessEnv = {}): { io: Io; out: string[]; err: string[] } {
  const out: string[] = [];
  const err: string[] = [];
  env = { DOTFILES_ORCHESTRATION_HOOK_PAYLOAD_DIR: FIXTURES, ...env };
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
const ORCA_WORKER = {
  ORCA_TERMINAL_HANDLE: "term_abc",
  ORCA_AGENT_TEAMS_LEADER_PANE: "%1",
  TMUX_PANE: "%9",
};
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
      for (const half of ["SKILL BODY", "GUIDE BODY", EVERYONE, COORDINATOR]) {
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
    expect(parsed.hookSpecificOutput.additionalContext).toContain(EVERYONE);
    expect(parsed.hookSpecificOutput.additionalContext).not.toContain(COORDINATOR);
  });
});

describe("omp hook delivery", () => {
  it("delivers the complete lead envelope in order", async () => {
    const home = mkdtempSync(join(tmpdir(), "orchestration-hook-omp-lead-"));
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
      expect(await main(["hook", "--harness", "omp"], io)).toBe(0);
      const context = out.join("");
      const order = [
        context.indexOf(PREAMBLE),
        context.indexOf("SKILL BODY"),
        context.indexOf("GUIDE BODY"),
        context.indexOf(EVERYONE),
        context.indexOf(COORDINATOR),
      ];
      expect(order.every((i) => i >= 0)).toBe(true);
      expect([...order].sort((a, b) => a - b)).toEqual(order);
    } finally {
      rmSync(home, { recursive: true, force: true });
    }
  });
  it("delivers the complete lead envelope to an interactive Orca terminal without pane variables", async () => {
    const home = mkdtempSync(join(tmpdir(), "orchestration-hook-omp-interactive-"));
    try {
      mkdirSync(join(home, ".agents", "skills", "orchestration"), { recursive: true });
      writeFileSync(join(home, ".agents/skills/orchestration/SKILL.md"), "SKILL BODY\n");
      const cli = join(home, "orca-stub");
      writeFileSync(cli, '#!/usr/bin/env bash\nprintf "GUIDE BODY\\n"\n');
      chmodSync(cli, 0o755);

      const { io, out } = capture({
        HOME: home,
        ORCA_CLI_COMMAND: cli,
        ORCA_TERMINAL_HANDLE: "term_interactive",
      });
      expect(await main(["hook", "--harness", "omp"], io)).toBe(0);
      const context = out.join("");
      expect(context).toContain("SKILL BODY");
      expect(context).toContain("GUIDE BODY");
      expect(context).toContain(COORDINATOR);
    } finally {
      rmSync(home, { recursive: true, force: true });
    }
  });

  it("identifies a worker by active database record when pane variables are absent", async () => {
    const home = mkdtempSync(join(tmpdir(), "orchestration-hook-omp-db-worker-"));
    try {
      const orcaDir = join(home, ".config", "orca");
      mkdirSync(orcaDir, { recursive: true });
      const db = new DatabaseSync(join(orcaDir, "orchestration.db"));
      db.exec(
        "CREATE TABLE worker_dispatches (dispatch_id TEXT PRIMARY KEY, agent_terminal_handle TEXT, state TEXT);",
      );
      db.exec(
        "CREATE TABLE dispatch_contexts (id TEXT PRIMARY KEY, assignee_handle TEXT, status TEXT);",
      );
      db.exec("INSERT INTO worker_dispatches VALUES ('d1', 'term_db_worker', 'ready');");
      db.close();

      const { io, out } = capture({
        HOME: home,
        ORCA_TERMINAL_HANDLE: "term_db_worker",
      });
      expect(await main(["hook", "--harness", "omp"], io)).toBe(0);
      const context = out.join("");
      expect(context).toContain(PREAMBLE);
      expect(context).toContain(EVERYONE);
      expect(context).not.toContain(COORDINATOR);
    } finally {
      rmSync(home, { recursive: true, force: true });
    }
  });

  it("delivers the everyone envelope to a worker", async () => {
    const { io, out } = capture(ORCA_WORKER);
    expect(await main(["hook", "--harness", "omp"], io)).toBe(0);
    const context = out.join("");
    expect(context).toContain(PREAMBLE);
    expect(context).toContain(EVERYONE);
    expect(context).not.toContain(COORDINATOR);
  });

  it("returns no output outside Orca", async () => {
    const { io, out } = capture();
    expect(await main(["hook", "--harness", "omp"], io)).toBe(0);
    expect(out.join("")).toBe("");
  });

  it("returns a no-op when the skill is empty", async () => {
    const home = mkdtempSync(join(tmpdir(), "orchestration-hook-omp-empty-skill-"));
    try {
      mkdirSync(join(home, ".agents", "skills", "orchestration"), { recursive: true });
      writeFileSync(join(home, ".agents/skills/orchestration/SKILL.md"), "");
      const { io, out } = capture({
        HOME: home,
        ORCA_TERMINAL_HANDLE: "term_abc",
        ORCA_AGENT_TEAMS_LEADER_PANE: "%7",
        TMUX_PANE: "%7",
      });
      expect(await main(["hook", "--harness", "omp"], io)).toBe(0);
      expect(out.join("")).toBe("");
    } finally {
      rmSync(home, { recursive: true, force: true });
    }
  });

  it("returns a no-op when the guide fetch fails", async () => {
    const home = mkdtempSync(join(tmpdir(), "orchestration-hook-omp-guide-fail-"));
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
      expect(await main(["hook", "--harness", "omp"], io)).toBe(0);
      expect(out.join("")).toBe("");
    } finally {
      rmSync(home, { recursive: true, force: true });
    }
  });

  it("delivers a complete envelope on a later invocation once the guide arrives", async () => {
    // The pre-model hook fires before every invocation, so an envelope that
    // could not be composed at the first opportunity is not lost — it lands
    // whole at the first opportunity that can compose it.
    const home = mkdtempSync(join(tmpdir(), "orchestration-hook-omp-late-"));
    try {
      mkdirSync(join(home, ".agents", "skills", "orchestration"), { recursive: true });
      writeFileSync(join(home, ".agents/skills/orchestration/SKILL.md"), "SKILL BODY\n");
      const cli = join(home, "orca-stub");
      const marker = join(home, "seen-once");
      writeFileSync(
        cli,
        `#!/usr/bin/env bash\nif [ -e ${JSON.stringify(marker)} ]; then printf "GUIDE BODY\\n"; else : > ${JSON.stringify(marker)}; exit 3; fi\n`,
      );
      chmodSync(cli, 0o755);
      const env = {
        HOME: home,
        ORCA_CLI_COMMAND: cli,
        ORCA_TERMINAL_HANDLE: "term_abc",
        ORCA_AGENT_TEAMS_LEADER_PANE: "%7",
        TMUX_PANE: "%7",
      };

      const first = capture(env);
      expect(await main(["hook", "--harness", "omp"], first.io)).toBe(0);
      expect(first.out.join("")).toBe("");

      const second = capture(env);
      expect(await main(["hook", "--harness", "omp"], second.io)).toBe(0);
      const context = second.out.join("");
      expect(context).toContain("GUIDE BODY");
      expect(context).toContain(COORDINATOR);
    } finally {
      rmSync(home, { recursive: true, force: true });
    }
  });

  it("lists omp among the accepted harness values", async () => {
    const { io, err } = capture();
    expect(await main(["nonesuch"], io)).toBe(2);
    expect(err.join(" ")).toContain("omp");
  });
});

describe("managed payload files", () => {
  // Every case in this block builds a HOME with a real payload directory, so
  // the default resolution is exercised, not just the test override.
  function seedHome(label: string, bodies: Partial<Record<"everyone" | "coordinator", string>>) {
    const home = mkdtempSync(join(tmpdir(), `orchestration-hook-${label}-`));
    mkdirSync(join(home, ".agents", "skills", "orchestration"), { recursive: true });
    writeFileSync(join(home, ".agents/skills/orchestration/SKILL.md"), "SKILL BODY\n");
    const cli = join(home, "orca-stub");
    writeFileSync(cli, '#!/usr/bin/env bash\nprintf "GUIDE BODY\\n"\n');
    chmodSync(cli, 0o755);
    const dir = join(home, ".local", "share", "orchestration-hook");
    mkdirSync(dir, { recursive: true });
    for (const [body, text] of Object.entries(bodies)) {
      writeFileSync(join(dir, `${body}.md`), text as string);
    }
    // An explicit empty override falls back to HOME, which is the whole point.
    const env = {
      HOME: home,
      DOTFILES_ORCHESTRATION_HOOK_PAYLOAD_DIR: "",
      ORCA_CLI_COMMAND: cli,
      ORCA_TERMINAL_HANDLE: "term_abc",
      ORCA_AGENT_TEAMS_LEADER_PANE: "%7",
      TMUX_PANE: "%7",
    };
    return { home, dir, env };
  }

  it("emits the lead envelope with both bodies when both files are present", async () => {
    const { home, env } = seedHome("both", { everyone: EVERYONE, coordinator: COORDINATOR });
    try {
      const { io, out } = capture(env);
      expect(await main(["hook", "--harness", "claude"], io)).toBe(0);
      const parsed = JSON.parse(out.join("")) as {
        hookSpecificOutput: { additionalContext: string };
      };
      expect(parsed.hookSpecificOutput.additionalContext).toContain(EVERYONE);
      expect(parsed.hookSpecificOutput.additionalContext).toContain(COORDINATOR);
    } finally {
      rmSync(home, { recursive: true, force: true });
    }
  });

  it("emits no context and exits 0 when the coordinator file is missing", async () => {
    const { home, env } = seedHome("no-coordinator", { everyone: EVERYONE });
    try {
      const { io, out, err } = capture(env);
      expect(await main(["hook", "--harness", "claude"], io)).toBe(0);
      expect(out.join("")).toBe("{}");
      expect(err.join("")).toBe("");
    } finally {
      rmSync(home, { recursive: true, force: true });
    }
  });

  it("reads the same files for --harness omp", async () => {
    const { home, env } = seedHome("omp-files", { everyone: EVERYONE, coordinator: COORDINATOR });
    try {
      const { io, out } = capture(env);
      expect(await main(["hook", "--harness", "omp"], io)).toBe(0);
      const context = out.join("");
      expect(context).toContain(EVERYONE);
      expect(context).toContain(COORDINATOR);
    } finally {
      rmSync(home, { recursive: true, force: true });
    }
  });

  it("treats an empty payload file as missing", async () => {
    const { home, env } = seedHome("empty-file", { everyone: EVERYONE, coordinator: "" });
    try {
      const { io, out } = capture(env);
      expect(await main(["hook", "--harness", "claude"], io)).toBe(0);
      expect(out.join("")).toBe("{}");
    } finally {
      rmSync(home, { recursive: true, force: true });
    }
  });

  it("treats an unreadable payload file as missing, not as an error", async () => {
    const { home, dir, env } = seedHome("unreadable", {
      everyone: EVERYONE,
      coordinator: COORDINATOR,
    });
    try {
      chmodSync(join(dir, "coordinator.md"), 0o000);
      // Root ignores the mode bits, so the case would assert nothing there.
      if (process.getuid?.() === 0) return;
      const { io, out, err } = capture(env);
      expect(await main(["hook", "--harness", "claude"], io)).toBe(0);
      expect(out.join("")).toBe("{}");
      expect(err.join("")).toBe("");
    } finally {
      rmSync(home, { recursive: true, force: true });
    }
  });

  it("delivers nothing to a worker whose everyone file is missing", async () => {
    const { home, env } = seedHome("no-everyone", { coordinator: COORDINATOR });
    try {
      const { io, out } = capture({ ...env, TMUX_PANE: "%9" });
      expect(await main(["hook", "--harness", "claude"], io)).toBe(0);
      expect(out.join("")).toBe("{}");
    } finally {
      rmSync(home, { recursive: true, force: true });
    }
  });
});

describe("print-payload", () => {
  it("prints the everyone body by default", async () => {
    const { io, out } = capture();
    expect(await main(["print-payload"], io)).toBe(0);
    expect(out.join("")).toBe(EVERYONE);
  });

  it("prints the coordinator body on request", async () => {
    const { io, out } = capture();
    expect(await main(["print-payload", "--body", "coordinator"], io)).toBe(0);
    expect(out.join("")).toBe(COORDINATOR);
  });

  it("fails loudly on an unknown body", async () => {
    const { io, out, err } = capture();
    expect(await main(["print-payload", "--body", "nonesuch"], io)).toBe(2);
    expect(out.join("")).toBe("");
    expect(err.join("")).toContain("nonesuch");
  });

  it("fails loudly and names the path when the managed file is absent", async () => {
    const { io, out, err } = capture({
      DOTFILES_ORCHESTRATION_HOOK_PAYLOAD_DIR: join(FIXTURES, "absent"),
    });
    expect(await main(["print-payload"], io)).toBe(1);
    expect(out.join("")).toBe("");
    expect(err.join("")).toContain(join(FIXTURES, "absent", "everyone.md"));
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

// A lead resolved through resolveRole's interactive-coordinator fallback: no
// pane variables at all, so ORCA_AGENT_TEAMS_LEADER_PANE's presence cannot
// exempt the call from the guard the way it would in an agent-teams session.
const LEAD_ENV = {
  ORCA_TERMINAL_HANDLE: "term_abc",
};

// Captured, unedited (redaction only) real PreToolUse events from a live
// session — see the U2 report for the capture commands. The Bash event stays
// synthetic: it is the stale-declaration edge case, not a captured subagent
// launch.
const EVENT_FIXTURES = join(dirname(fileURLToPath(import.meta.url)), "fixtures");
const CLAUDE_AGENT_EVENT = readFileSync(join(EVENT_FIXTURES, "pretooluse-claude-agent.json"), "utf8");
const CODEX_SPAWN_AGENT_EVENT = readFileSync(
  join(EVENT_FIXTURES, "pretooluse-codex-spawn-agent.json"),
  "utf8",
);
const BASH_EVENT = JSON.stringify({ hook_event_name: "PreToolUse", tool_name: "Bash" });

function seedGuardLeadHome(label: string): string {
  const home = mkdtempSync(join(tmpdir(), `guard-cli-${label}-`));
  mkdirSync(join(home, ".agents", "skills", "orchestration"), { recursive: true });
  writeFileSync(join(home, ".agents/skills/orchestration/SKILL.md"), "SKILL BODY\n");
  return home;
}

describe("guard", () => {
  it("denies an injected Claude Code lead's Agent call, naming the orchestration skill and the Orca dispatch path (AE3)", async () => {
    const home = seedGuardLeadHome("deny");
    try {
      const { io, out, err } = capture({ ...LEAD_ENV, HOME: home });
      io.stdin = CLAUDE_AGENT_EVENT;
      expect(await main(["guard", "--harness", "claude"], io)).toBe(0);
      const parsed = JSON.parse(out.join("")) as {
        hookSpecificOutput: {
          hookEventName: string;
          permissionDecision: string;
          permissionDecisionReason: string;
        };
      };
      expect(parsed.hookSpecificOutput.hookEventName).toBe("PreToolUse");
      expect(parsed.hookSpecificOutput.permissionDecision).toBe("deny");
      expect(parsed.hookSpecificOutput.permissionDecisionReason).toContain("`orchestration` skill");
      expect(err.join("")).toBe("");
    } finally {
      rmSync(home, { recursive: true, force: true });
    }
  });

  it("allows the same environment when stdin is not JSON (AE3)", async () => {
    const home = seedGuardLeadHome("notjson");
    try {
      const { io, out, err } = capture({ ...LEAD_ENV, HOME: home });
      io.stdin = "not json";
      expect(await main(["guard", "--harness", "claude"], io)).toBe(0);
      expect(out.join("")).toBe("{}");
      expect(err.join("")).toBe("");
    } finally {
      rmSync(home, { recursive: true, force: true });
    }
  });

  it("allows outside Orca (AE4)", async () => {
    const { io, out, err } = capture({});
    io.stdin = CLAUDE_AGENT_EVENT;
    expect(await main(["guard", "--harness", "claude"], io)).toBe(0);
    expect(out.join("")).toBe("{}");
    expect(err.join("")).toBe("");
  });

  it("allows a stale cached declaration's Bash event even in an injected session (AE6)", async () => {
    const home = seedGuardLeadHome("bash");
    try {
      const { io, out, err } = capture({ ...LEAD_ENV, HOME: home });
      io.stdin = BASH_EVENT;
      expect(await main(["guard", "--harness", "claude"], io)).toBe(0);
      expect(out.join("")).toBe("{}");
      expect(err.join("")).toBe("");
    } finally {
      rmSync(home, { recursive: true, force: true });
    }
  });

  it("denies Codex's own subagent tool call and prints nothing on allow", async () => {
    const home = seedGuardLeadHome("codex");
    try {
      const { io, out } = capture({ ...LEAD_ENV, HOME: home });
      io.stdin = CODEX_SPAWN_AGENT_EVENT;
      expect(await main(["guard", "--harness", "codex"], io)).toBe(0);
      const parsed = JSON.parse(out.join("")) as {
        hookSpecificOutput: { permissionDecision: string };
      };
      expect(parsed.hookSpecificOutput.permissionDecision).toBe("deny");

      const allow = capture({ ...LEAD_ENV, HOME: home });
      allow.io.stdin = BASH_EVENT;
      expect(await main(["guard", "--harness", "codex"], allow.io)).toBe(0);
      expect(allow.out.join("")).toBe("");
      expect(allow.err.join("")).toBe("");
    } finally {
      rmSync(home, { recursive: true, force: true });
    }
  });

  it("denies omp's task tool call", async () => {
    const home = seedGuardLeadHome("omp");
    try {
      const { io, out } = capture({ ...LEAD_ENV, HOME: home });
      io.stdin = JSON.stringify({ hook_event_name: "PreToolUse", tool_name: "task" });
      expect(await main(["guard", "--harness", "omp"], io)).toBe(0);
      const parsed = JSON.parse(out.join("")) as {
        hookSpecificOutput: { permissionDecision: string };
      };
      expect(parsed.hookSpecificOutput.permissionDecision).toBe("deny");
    } finally {
      rmSync(home, { recursive: true, force: true });
    }
  });

  it("fails open on malformed stdin", async () => {
    const home = seedGuardLeadHome("malformed");
    try {
      const { io, out, err } = capture({ ...LEAD_ENV, HOME: home });
      io.stdin = "{not valid json";
      expect(await main(["guard", "--harness", "claude"], io)).toBe(0);
      expect(out.join("")).toBe("{}");
      expect(err.join("")).toBe("");
    } finally {
      rmSync(home, { recursive: true, force: true });
    }
  });

  it("fails open on empty stdin", async () => {
    const home = seedGuardLeadHome("empty-stdin");
    try {
      const { io, out, err } = capture({ ...LEAD_ENV, HOME: home });
      io.stdin = "";
      expect(await main(["guard", "--harness", "claude"], io)).toBe(0);
      expect(out.join("")).toBe("{}");
      expect(err.join("")).toBe("");
    } finally {
      rmSync(home, { recursive: true, force: true });
    }
  });

  it("prints nothing when --harness is missing or unknown, exiting 0 with empty stderr", async () => {
    for (const argv of [["guard"], ["guard", "--harness", "nonesuch"]]) {
      const { io, out, err } = capture(LEAD_ENV);
      io.stdin = CLAUDE_AGENT_EVENT;
      expect(await main(argv, io)).toBe(0);
      expect(out.join("")).toBe("");
      expect(err.join("")).toBe("");
    }
  });
});
