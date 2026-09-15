import { DatabaseSync } from "node:sqlite";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { describe, expect, it } from "vite-plus/test";
import { isWorkerTerminal, resolveRole } from "../src/role.js";

// The precedence these cases pin protects tmux agent-teams teammate isolation
// while defaulting standard interactive Orca terminals to lead unless
// registered in worker_dispatches or dispatch_contexts.
describe("resolveRole", () => {
  it("is none when the Orca terminal handle is unset", () => {
    expect(resolveRole({})).toBe("none");
  });

  it("is none when the Orca terminal handle is an empty string", () => {
    expect(resolveRole({ ORCA_TERMINAL_HANDLE: "" })).toBe("none");
  });

  it("is none when both pane variables are set and equal but the handle is unset", () => {
    expect(resolveRole({ ORCA_AGENT_TEAMS_LEADER_PANE: "%7", TMUX_PANE: "%7" })).toBe("none");
  });
  it("is lead when both pane variables are empty strings and not a worker", () => {
    expect(
      resolveRole(
        {
          ORCA_TERMINAL_HANDLE: "term_abc",
          ORCA_AGENT_TEAMS_LEADER_PANE: "",
          TMUX_PANE: "",
        },
        { isWorker: () => false },
      ),
    ).toBe("lead");
  });

  it("is worker when both pane variables are empty strings but is an active worker", () => {
    expect(
      resolveRole(
        {
          ORCA_TERMINAL_HANDLE: "term_worker",
          ORCA_AGENT_TEAMS_LEADER_PANE: "",
          TMUX_PANE: "",
        },
        { isWorker: () => true },
      ),
    ).toBe("worker");
  });

  it("is worker when the leader pane is unset", () => {
    expect(resolveRole({ ORCA_TERMINAL_HANDLE: "term_abc", TMUX_PANE: "%7" })).toBe("worker");
  });

  it("is worker when TMUX_PANE is unset", () => {
    expect(
      resolveRole({ ORCA_TERMINAL_HANDLE: "term_abc", ORCA_AGENT_TEAMS_LEADER_PANE: "%7" }),
    ).toBe("worker");
  });

  it("is worker when the panes are set but unequal", () => {
    expect(
      resolveRole({
        ORCA_TERMINAL_HANDLE: "term_abc",
        ORCA_AGENT_TEAMS_LEADER_PANE: "%7",
        TMUX_PANE: "%9",
      }),
    ).toBe("worker");
  });

  it("is lead when the handle is set and both panes are non-empty and equal", () => {
    expect(
      resolveRole({
        ORCA_TERMINAL_HANDLE: "term_abc",
        ORCA_AGENT_TEAMS_LEADER_PANE: "%7",
        TMUX_PANE: "%7",
      }),
    ).toBe("lead");
  });
  it("treats a whitespace-only handle as present, defaulting to lead when not a worker", () => {
    expect(resolveRole({ ORCA_TERMINAL_HANDLE: " " }, { isWorker: () => false })).toBe("lead");
  });

  it("resolves lead for a standard Orca terminal without options when db is absent", () => {
    expect(resolveRole({ ORCA_TERMINAL_HANDLE: "term_default", HOME: "/nonexistent" })).toBe(
      "lead",
    );
  });

  it("identifies active worker terminals via SQLite database in isWorkerTerminal", () => {
    const dir = mkdtempSync(join(tmpdir(), "orca-test-"));
    try {
      const db = new DatabaseSync(join(dir, "orchestration.db"));
      db.exec(`
        CREATE TABLE worker_dispatches (
          dispatch_id TEXT PRIMARY KEY,
          agent_terminal_handle TEXT,
          state TEXT
        );
        CREATE TABLE dispatch_contexts (
          id TEXT PRIMARY KEY,
          assignee_handle TEXT,
          status TEXT
        );
        INSERT INTO worker_dispatches VALUES ('d1', 'term_worker_active', 'ready');
        INSERT INTO worker_dispatches VALUES ('d2', 'term_worker_settled', 'succeeded');
        INSERT INTO dispatch_contexts VALUES ('c1', 'term_context_active', 'dispatched');
      `);
      db.close();

      const env = { ORCA_USER_DATA_PATH: dir, ORCA_TERMINAL_HANDLE: "term_worker_active" };
      expect(isWorkerTerminal("term_worker_active", env)).toBe(true);
      expect(resolveRole(env)).toBe("worker");

      const contextEnv = { ORCA_USER_DATA_PATH: dir, ORCA_TERMINAL_HANDLE: "term_context_active" };
      expect(isWorkerTerminal("term_context_active", contextEnv)).toBe(true);
      expect(resolveRole(contextEnv)).toBe("worker");

      const settledEnv = { ORCA_USER_DATA_PATH: dir, ORCA_TERMINAL_HANDLE: "term_worker_settled" };
      expect(isWorkerTerminal("term_worker_settled", settledEnv)).toBe(false);
      expect(resolveRole(settledEnv)).toBe("lead");

      const unknownEnv = { ORCA_USER_DATA_PATH: dir, ORCA_TERMINAL_HANDLE: "term_interactive" };
      expect(isWorkerTerminal("term_interactive", unknownEnv)).toBe(false);
      expect(resolveRole(unknownEnv)).toBe("lead");
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });
});
