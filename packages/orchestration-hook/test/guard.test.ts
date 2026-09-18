import { mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";
import { DatabaseSync } from "node:sqlite";
import { describe, expect, it } from "vite-plus/test";
import { decide, denyReason, isInjected, SUBAGENT_TOOLS } from "../src/guard.js";

// The bodies are managed files the deployed binary reads at run time, so the
// tests read a fixture pair rather than whatever this host last applied.
const FIXTURES = join(dirname(fileURLToPath(import.meta.url)), "fixtures", "payload");
const ABSENT = join(FIXTURES, "absent");

// Real PreToolUse events captured from a live session, redacted only.
// Deny-path tests use these rather than a hand-written event; a synthetic
// event is reserved for the parser edge cases below (malformed, missing
// tool_name, non-string tool_name).
const EVENTS_DIR = join(dirname(fileURLToPath(import.meta.url)), "fixtures");
const CLAUDE_AGENT_EVENT = JSON.parse(
  readFileSync(join(EVENTS_DIR, "pretooluse-claude-agent.json"), "utf8"),
) as { tool_name: string };
const CODEX_SPAWN_AGENT_EVENT = JSON.parse(
  readFileSync(join(EVENTS_DIR, "pretooluse-codex-spawn-agent.json"), "utf8"),
) as { tool_name: string };

function stagedLeadHome(skill = "SKILL BODY\n"): string {
  const home = mkdtempSync(join(tmpdir(), "guard-lead-"));
  mkdirSync(join(home, ".agents", "skills", "orchestration"), { recursive: true });
  writeFileSync(join(home, ".agents/skills/orchestration/SKILL.md"), skill);
  return home;
}

function leadEnv(home: string, payloadDir: string = FIXTURES): NodeJS.ProcessEnv {
  return {
    HOME: home,
    DOTFILES_ORCHESTRATION_HOOK_PAYLOAD_DIR: payloadDir,
    ORCA_TERMINAL_HANDLE: "term_abc",
  };
}

// TMUX_PANE alone (no ORCA_AGENT_TEAMS_LEADER_PANE) resolves to role "worker"
// via resolveRole's tmux-teammate-pane branch, deterministically and without a
// database — and, critically, without tripping the guard's agent-teams
// exemption below, which keys off ORCA_AGENT_TEAMS_LEADER_PANE alone.
const WORKER_ENV: NodeJS.ProcessEnv = {
  DOTFILES_ORCHESTRATION_HOOK_PAYLOAD_DIR: FIXTURES,
  ORCA_TERMINAL_HANDLE: "term_worker",
  TMUX_PANE: "%9",
};

describe("SUBAGENT_TOOLS", () => {
  it("names the tool captured from a live session per harness", () => {
    expect(SUBAGENT_TOOLS.claude).toEqual(["Agent", "Task"]);
    // Codex reports "collaborationspawn_agent", the namespace-qualified name,
    // rather than the bare "spawn_agent".
    expect(SUBAGENT_TOOLS.codex).toEqual(["collaborationspawn_agent"]);
    expect(SUBAGENT_TOOLS.omp).toEqual(["task"]);
  });
});

describe("isInjected", () => {
  it("is false for role none regardless of staged files", () => {
    expect(isInjected("none", leadEnv(stagedLeadHome()))).toBe(false);
  });

  it("is true for a worker with everyone.md staged", () => {
    expect(isInjected("worker", WORKER_ENV)).toBe(true);
  });

  it("is false for a worker with no everyone.md staged", () => {
    expect(
      isInjected("worker", { ...WORKER_ENV, DOTFILES_ORCHESTRATION_HOOK_PAYLOAD_DIR: ABSENT }),
    ).toBe(false);
  });

  it("is true for a lead with everyone.md, coordinator.md, and a non-empty skill staged", () => {
    const home = stagedLeadHome();
    try {
      expect(isInjected("lead", leadEnv(home))).toBe(true);
    } finally {
      rmSync(home, { recursive: true, force: true });
    }
  });

  it("is false for a lead with no coordinator.md staged", () => {
    const home = stagedLeadHome();
    try {
      expect(isInjected("lead", leadEnv(home, ABSENT))).toBe(false);
    } finally {
      rmSync(home, { recursive: true, force: true });
    }
  });

  it("is false for a lead whose skill file is empty", () => {
    const home = stagedLeadHome("");
    try {
      expect(isInjected("lead", leadEnv(home))).toBe(false);
    } finally {
      rmSync(home, { recursive: true, force: true });
    }
  });

  it("is false whenever ORCA_AGENT_TEAMS_LEADER_PANE is present, fully staged or not", () => {
    const home = stagedLeadHome();
    try {
      const env = { ...leadEnv(home), ORCA_AGENT_TEAMS_LEADER_PANE: "%3" };
      expect(isInjected("lead", env)).toBe(false);
      expect(isInjected("worker", { ...WORKER_ENV, ORCA_AGENT_TEAMS_LEADER_PANE: "%1" })).toBe(
        false,
      );
    } finally {
      rmSync(home, { recursive: true, force: true });
    }
  });
});

describe("denyReason", () => {
  it("names the tool, the orchestration skill, and the Orca dispatch path", () => {
    const reason = denyReason("Agent");
    expect(reason).toContain("`Agent`");
    expect(reason).toContain("`orchestration` skill");
    expect(reason).toContain("Orca dispatch");
  });
});

describe("decide", () => {
  it("denies each harness's own subagent tool names for an injected lead", () => {
    const home = stagedLeadHome();
    try {
      const env = leadEnv(home);
      // Claude Code and Codex use the captured events unedited; omp has no
      // required fixture in this unit's scope, so its case stays synthetic.
      expect(decide(CLAUDE_AGENT_EVENT, "claude", env)).toEqual({
        deny: true,
        reason: denyReason("Agent"),
      });
      expect(decide({ tool_name: "Task" }, "claude", env).deny).toBe(true);
      expect(decide(CODEX_SPAWN_AGENT_EVENT, "codex", env)).toEqual({
        deny: true,
        reason: denyReason("collaborationspawn_agent"),
      });
      expect(decide({ tool_name: "task" }, "omp", env).deny).toBe(true);
    } finally {
      rmSync(home, { recursive: true, force: true });
    }
  });

  it("denies for an injected worker too", () => {
    expect(decide(CLAUDE_AGENT_EVENT, "claude", WORKER_ENV).deny).toBe(true);
    expect(decide({ tool_name: "Task" }, "claude", WORKER_ENV).deny).toBe(true);
    expect(decide(CODEX_SPAWN_AGENT_EVENT, "codex", WORKER_ENV).deny).toBe(true);
    expect(decide({ tool_name: "task" }, "omp", WORKER_ENV).deny).toBe(true);
  });

  it("allows another harness's subagent tool name", () => {
    const home = stagedLeadHome();
    try {
      const env = leadEnv(home);
      expect(decide({ tool_name: "collaborationspawn_agent" }, "claude", env).deny).toBe(false);
      expect(decide({ tool_name: "task" }, "claude", env).deny).toBe(false);
      expect(decide({ tool_name: "Agent" }, "codex", env).deny).toBe(false);
      expect(decide({ tool_name: "Task" }, "codex", env).deny).toBe(false);
      expect(decide({ tool_name: "Agent" }, "omp", env).deny).toBe(false);
    } finally {
      rmSync(home, { recursive: true, force: true });
    }
  });

  it("does not deny Codex's bare spawn_agent name", () => {
    const home = stagedLeadHome();
    try {
      // Codex reports "collaborationspawn_agent", never the bare "spawn_agent". A
      // guard that matched the bare name would deny nothing in a real session.
      expect(decide({ tool_name: "spawn_agent" }, "codex", leadEnv(home)).deny).toBe(false);
    } finally {
      rmSync(home, { recursive: true, force: true });
    }
  });

  it("allows Bash, TaskCreate, a missing tool_name, and a non-string tool_name", () => {
    const home = stagedLeadHome();
    try {
      const env = leadEnv(home);
      expect(decide({ tool_name: "Bash" }, "claude", env).deny).toBe(false);
      expect(decide({ tool_name: "TaskCreate" }, "claude", env).deny).toBe(false);
      expect(decide({}, "claude", env).deny).toBe(false);
      expect(decide({ tool_name: 42 }, "claude", env).deny).toBe(false);
      expect(decide({ tool_name: null }, "claude", env).deny).toBe(false);
    } finally {
      rmSync(home, { recursive: true, force: true });
    }
  });

  it("allows role none outside Orca", () => {
    expect(decide({ tool_name: "Agent" }, "claude", {}).deny).toBe(false);
  });

  it("allows a worker with no everyone.md staged", () => {
    expect(
      decide({ tool_name: "Agent" }, "claude", {
        ...WORKER_ENV,
        DOTFILES_ORCHESTRATION_HOOK_PAYLOAD_DIR: ABSENT,
      }).deny,
    ).toBe(false);
  });

  it("allows a lead with no coordinator.md or an empty skill file", () => {
    const home = stagedLeadHome();
    try {
      expect(decide({ tool_name: "Agent" }, "claude", leadEnv(home, ABSENT)).deny).toBe(false);
    } finally {
      rmSync(home, { recursive: true, force: true });
    }
    const emptySkillHome = stagedLeadHome("");
    try {
      expect(decide({ tool_name: "Agent" }, "claude", leadEnv(emptySkillHome)).deny).toBe(false);
    } finally {
      rmSync(emptySkillHome, { recursive: true, force: true });
    }
  });

  it("allows Agent in an Orca agent-teams session, even fully staged", () => {
    const home = stagedLeadHome();
    try {
      const env = { ...leadEnv(home), ORCA_AGENT_TEAMS_LEADER_PANE: "%3", TMUX_PANE: "%3" };
      expect(decide(CLAUDE_AGENT_EVENT, "claude", env).deny).toBe(false);
    } finally {
      rmSync(home, { recursive: true, force: true });
    }
  });

  it("denies for a lead resolved through the interactive-coordinator fallback (no pane variables)", () => {
    // resolveRole's own fallback: ORCA_TERMINAL_HANDLE set, no pane variables,
    // and no matching worker record in the orchestration database.
    const home = stagedLeadHome();
    try {
      const env = leadEnv(home);
      expect(env.ORCA_AGENT_TEAMS_LEADER_PANE).toBeUndefined();
      expect(env.TMUX_PANE).toBeUndefined();
      expect(decide(CLAUDE_AGENT_EVENT, "claude", env).deny).toBe(true);
    } finally {
      rmSync(home, { recursive: true, force: true });
    }
  });

  it("denies for a worker resolved through the orchestration database (no pane variables)", () => {
    const home = mkdtempSync(join(tmpdir(), "guard-db-worker-"));
    try {
      const orcaDir = join(home, ".config", "orca");
      mkdirSync(orcaDir, { recursive: true });
      const db = new DatabaseSync(join(orcaDir, "orchestration.db"));
      db.exec(
        "CREATE TABLE worker_dispatches (dispatch_id TEXT PRIMARY KEY, agent_terminal_handle TEXT, state TEXT);",
      );
      db.exec("INSERT INTO worker_dispatches VALUES ('d1', 'term_db_worker', 'ready');");
      db.close();
      const dir = join(home, ".local", "share", "orchestration-hook");
      mkdirSync(dir, { recursive: true });
      writeFileSync(join(dir, "everyone.md"), "EVERYONE\n");

      const env: NodeJS.ProcessEnv = {
        HOME: home,
        DOTFILES_ORCHESTRATION_HOOK_PAYLOAD_DIR: "",
        ORCA_TERMINAL_HANDLE: "term_db_worker",
      };
      expect(decide(CLAUDE_AGENT_EVENT, "claude", env).deny).toBe(true);
    } finally {
      rmSync(home, { recursive: true, force: true });
    }
  });
});
