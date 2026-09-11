import { describe, expect, it } from "vite-plus/test";
import { resolveRole } from "../src/role.js";

// The precedence these cases pin is the one the retired bash predicate was
// written to protect. Its own header recorded the hazard: comparing two unset
// pane variables matches empty against empty, which classified every teammate
// as the lead. Each leg therefore tests presence before equality.

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

  it("is worker when both pane variables are empty strings", () => {
    expect(
      resolveRole({
        ORCA_TERMINAL_HANDLE: "term_abc",
        ORCA_AGENT_TEAMS_LEADER_PANE: "",
        TMUX_PANE: "",
      }),
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

  it("treats a whitespace-only handle as present, not as unset", () => {
    // Whitespace is not the empty string, so the handle is present and the
    // session is Orca-managed. Deciding it here keeps the boundary explicit
    // rather than incidental.
    expect(resolveRole({ ORCA_TERMINAL_HANDLE: " " })).toBe("worker");
  });
});
