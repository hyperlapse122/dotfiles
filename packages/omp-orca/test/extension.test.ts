import { chmodSync, existsSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { describe, expect, it } from "vite-plus/test";
import extension, {
  MANAGED_BLOCK_END,
  MANAGED_BLOCK_START,
  invokeHook,
  type BeforeAgentStartEvent,
  type BeforeAgentStartHandler,
  type BeforeAgentStartResult,
  type ExtensionAPI,
  type ToolCallEvent,
  type ToolCallHandler,
  type ToolCallResult,
} from "../src/index.js";
function fakeApi(): {
  api: ExtensionAPI;
  handler: (event: BeforeAgentStartEvent) => Promise<BeforeAgentStartResult>;
  toolCallHandler: (event: ToolCallEvent) => Promise<ToolCallResult | undefined>;
} {
  let handler: BeforeAgentStartHandler | undefined;
  let toolCall: ToolCallHandler | undefined;
  const api: ExtensionAPI = {
    on(
      event: "before_agent_start" | "tool_call",
      next: BeforeAgentStartHandler | ToolCallHandler,
    ) {
      if (event === "before_agent_start") {
        handler = next as BeforeAgentStartHandler;
      } else if (event === "tool_call") {
        toolCall = next as ToolCallHandler;
      }
    },
  };
  return {
    api,
    handler: async (event) =>
      handler ? await handler(event) : Promise.reject(new Error("handler missing")),
    toolCallHandler: async (event) =>
      toolCall ? await toolCall(event) : Promise.reject(new Error("toolCallHandler missing")),
  };
}

function hookScript(dir: string, body: string): string {
  const path = join(dir, "hook");
  writeFileSync(path, `#!/usr/bin/env bash\n${body}\n`);
  chmodSync(path, 0o755);
  return path;
}

describe("extension adapter", () => {
  it("runs the staged hook with the current role environment", async () => {
    const dir = mkdtempSync(join(tmpdir(), "dotfiles-orca-extension-"));
    const marker = join(dir, "env");
    const binary = hookScript(
      dir,
      `printf '%s|%s|%s' "$ORCA_TERMINAL_HANDLE" "$ORCA_AGENT_TEAMS_LEADER_PANE" "$TMUX_PANE" > ${JSON.stringify(marker)}\nprintf 'CONTEXT'`,
    );
    const previous = {
      binary: process.env.DOTFILES_ORCHESTRATION_HOOK,
      terminal: process.env.ORCA_TERMINAL_HANDLE,
      leader: process.env.ORCA_AGENT_TEAMS_LEADER_PANE,
      pane: process.env.TMUX_PANE,
    };
    process.env.DOTFILES_ORCHESTRATION_HOOK = binary;
    process.env.ORCA_TERMINAL_HANDLE = "term_test";
    process.env.ORCA_AGENT_TEAMS_LEADER_PANE = "%7";
    process.env.TMUX_PANE = "%9";
    try {
      const { api, handler } = fakeApi();
      await extension(api);
      const result = await handler({ prompt: "x", systemPrompt: ["BASE"] });
      expect(readFileSync(marker, "utf8")).toBe("term_test|%7|%9");
      expect(result.systemPrompt).toEqual([
        "BASE",
        `${MANAGED_BLOCK_START}\nCONTEXT\n${MANAGED_BLOCK_END}`,
      ]);
    } finally {
      if (previous.binary === undefined) delete process.env.DOTFILES_ORCHESTRATION_HOOK;
      else process.env.DOTFILES_ORCHESTRATION_HOOK = previous.binary;
      if (previous.terminal === undefined) delete process.env.ORCA_TERMINAL_HANDLE;
      else process.env.ORCA_TERMINAL_HANDLE = previous.terminal;
      if (previous.leader === undefined) delete process.env.ORCA_AGENT_TEAMS_LEADER_PANE;
      else process.env.ORCA_AGENT_TEAMS_LEADER_PANE = previous.leader;
      if (previous.pane === undefined) delete process.env.TMUX_PANE;
      else process.env.TMUX_PANE = previous.pane;
      rmSync(dir, { recursive: true, force: true });
    }
  });

  it("replaces one prior managed block without touching other prompt text", async () => {
    const dir = mkdtempSync(join(tmpdir(), "dotfiles-orca-extension-replace-"));
    const binary = hookScript(dir, "printf 'NEW'");
    const previous = process.env.DOTFILES_ORCHESTRATION_HOOK;
    process.env.DOTFILES_ORCHESTRATION_HOOK = binary;
    try {
      const { api, handler } = fakeApi();
      await extension(api);
      const old = `${MANAGED_BLOCK_START}\nOLD\n${MANAGED_BLOCK_END}`;
      const result = await handler({ prompt: "x", systemPrompt: ["BASE", old, "TAIL", old] });
      expect(result.systemPrompt).toEqual([
        "BASE",
        "TAIL",
        `${MANAGED_BLOCK_START}\nNEW\n${MANAGED_BLOCK_END}`,
      ]);
      expect(
        result.systemPrompt.join("\n").match(new RegExp(MANAGED_BLOCK_START, "g")),
      ).toHaveLength(1);
    } finally {
      if (previous === undefined) delete process.env.DOTFILES_ORCHESTRATION_HOOK;
      else process.env.DOTFILES_ORCHESTRATION_HOOK = previous;
      rmSync(dir, { recursive: true, force: true });
    }
  });
  it("injects coordinator lead context including skill and guide into system prompt", async () => {
    const dir = mkdtempSync(join(tmpdir(), "dotfiles-orca-extension-lead-"));
    const leadContext = [
      "--- orchestration SKILL.md ---",
      "SKILL CONTENT",
      "--- version-matched Orca orchestration guide ---",
      "GUIDE CONTENT",
      "<!-- orchestration-coordinator:begin -->",
      "COORDINATOR RULES",
      "<!-- orchestration-coordinator:end -->",
    ].join("\n");
    const binary = hookScript(dir, `cat <<'EOF'\n${leadContext}\nEOF`);
    const previous = process.env.DOTFILES_ORCHESTRATION_HOOK;
    process.env.DOTFILES_ORCHESTRATION_HOOK = binary;
    try {
      const { api, handler } = fakeApi();
      await extension(api);
      const result = await handler({ prompt: "start goal", systemPrompt: ["USER_INSTRUCTIONS"] });
      expect(result.systemPrompt).toHaveLength(2);
      expect(result.systemPrompt[0]).toBe("USER_INSTRUCTIONS");
      const injected = result.systemPrompt[1];
      expect(injected).toContain(MANAGED_BLOCK_START);
      expect(injected).toContain("--- orchestration SKILL.md ---");
      expect(injected).toContain("orchestration-coordinator:begin");
      expect(injected).toContain(MANAGED_BLOCK_END);
    } finally {
      if (previous === undefined) delete process.env.DOTFILES_ORCHESTRATION_HOOK;
      else process.env.DOTFILES_ORCHESTRATION_HOOK = previous;
      rmSync(dir, { recursive: true, force: true });
    }
  });
});

describe("bounded hook process", () => {
  it("terminates a child that ignores SIGTERM", async () => {
    const dir = mkdtempSync(join(tmpdir(), "dotfiles-orca-extension-stubborn-"));
    const marker = join(dir, "pid");
    try {
      const binary = hookScript(
        dir,
        `trap '' TERM\nprintf '%s' "$$" > '${marker}'\nwhile :; do sleep 1; done`,
      );
      const result = await invokeHook(binary, { ...process.env }, 100);
      expect(result.diagnostic).toContain("timed out");
      const pid = Number(readFileSync(marker, "utf8"));
      await new Promise((resolve) => setTimeout(resolve, 350));
      try {
        expect(() => process.kill(pid, 0)).toThrow();
      } finally {
        try {
          process.kill(-pid, "SIGKILL");
        } catch {
          /* Already exited. */
        }
      }
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  it("keeps the original system prompt when the hook fails", async () => {
    const dir = mkdtempSync(join(tmpdir(), "dotfiles-orca-extension-diagnostic-"));
    const previous = process.env.DOTFILES_ORCHESTRATION_HOOK;
    process.env.DOTFILES_ORCHESTRATION_HOOK = hookScript(dir, "printf 'partial'; exit 3");
    try {
      const { api, handler } = fakeApi();
      await extension(api);
      const result = await handler({
        prompt: "x",
        systemPrompt: ["BASE", `${MANAGED_BLOCK_START}\nSTALE LEAD\n${MANAGED_BLOCK_END}`],
      });
      expect(result.systemPrompt).toEqual(["BASE"]);
    } finally {
      if (previous === undefined) delete process.env.DOTFILES_ORCHESTRATION_HOOK;
      else process.env.DOTFILES_ORCHESTRATION_HOOK = previous;
      rmSync(dir, { recursive: true, force: true });
    }
  });

  it("returns a diagnostic for a failed child", async () => {
    const dir = mkdtempSync(join(tmpdir(), "dotfiles-orca-extension-fail-"));
    try {
      const binary = hookScript(dir, "printf 'partial'; exit 3");
      const result = await invokeHook(binary, { ...process.env }, 500);
      expect(result.context).toBeNull();
      expect(result.diagnostic).toContain("exit 3");
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  it("reports an empty managed response without claiming partial context", async () => {
    const dir = mkdtempSync(join(tmpdir(), "dotfiles-orca-empty-"));
    try {
      const binary = hookScript(dir, "exit 0");
      const managed = await invokeHook(binary, {
        ...process.env,
        ORCA_TERMINAL_HANDLE: "term_test",
      });
      expect(managed.context).toBeNull();
      expect(managed.diagnostic).toContain("no orchestration context");
      const outside = await invokeHook(binary, { ...process.env, ORCA_TERMINAL_HANDLE: "" });
      expect(outside).toEqual({ context: null });
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });

  it("returns a diagnostic when the child exceeds its bound", async () => {
    const dir = mkdtempSync(join(tmpdir(), "dotfiles-orca-extension-timeout-"));
    try {
      const binary = hookScript(dir, "sleep 30");
      const started = Date.now();
      const result = await invokeHook(binary, { ...process.env }, 50);
      expect(result.context).toBeNull();
      expect(result.diagnostic).toContain("timed out");
      expect(Date.now() - started).toBeLessThan(1_000);
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });
});

describe("tool_call guard", () => {
  it("blocks task when the guard returns a deny document", async () => {
    const dir = mkdtempSync(join(tmpdir(), "dotfiles-orca-deny-"));
    const previous = process.env.DOTFILES_ORCHESTRATION_HOOK;
    const denyDoc = JSON.stringify({
      hookSpecificOutput: {
        hookEventName: "PreToolUse",
        permissionDecision: "deny",
        permissionDecisionReason: "Orca dispatch required for task",
      },
    });
    process.env.DOTFILES_ORCHESTRATION_HOOK = hookScript(dir, `printf '%s\\n' '${denyDoc}'`);
    try {
      const { api, toolCallHandler } = fakeApi();
      await extension(api);
      const result = await toolCallHandler({ toolName: "task" });
      expect(result).toEqual({
        block: true,
        reason: "Orca dispatch required for task",
      });
    } finally {
      if (previous === undefined) delete process.env.DOTFILES_ORCHESTRATION_HOOK;
      else process.env.DOTFILES_ORCHESTRATION_HOOK = previous;
      rmSync(dir, { recursive: true, force: true });
    }
  });

  it("does not block task when the guard prints nothing, not json, or exits non-zero", async () => {
    const dir = mkdtempSync(join(tmpdir(), "dotfiles-orca-allow-"));
    const previous = process.env.DOTFILES_ORCHESTRATION_HOOK;
    try {
      process.env.DOTFILES_ORCHESTRATION_HOOK = hookScript(dir, "exit 0");
      const api1 = fakeApi();
      await extension(api1.api);
      expect(await api1.toolCallHandler({ toolName: "task" })).toBeUndefined();

      process.env.DOTFILES_ORCHESTRATION_HOOK = hookScript(dir, "printf 'not json\\n'");
      const api2 = fakeApi();
      await extension(api2.api);
      expect(await api2.toolCallHandler({ toolName: "task" })).toBeUndefined();

      process.env.DOTFILES_ORCHESTRATION_HOOK = hookScript(dir, "printf 'error'; exit 3");
      const api3 = fakeApi();
      await extension(api3.api);
      expect(await api3.toolCallHandler({ toolName: "task" })).toBeUndefined();
    } finally {
      if (previous === undefined) delete process.env.DOTFILES_ORCHESTRATION_HOOK;
      else process.env.DOTFILES_ORCHESTRATION_HOOK = previous;
      rmSync(dir, { recursive: true, force: true });
    }
  });

  it("does not block task when the guard sleeps past the bound", async () => {
    const dir = mkdtempSync(join(tmpdir(), "dotfiles-orca-guard-timeout-"));
    const previousHook = process.env.DOTFILES_ORCHESTRATION_HOOK;
    const previousTimeout = process.env.DOTFILES_ORCHESTRATION_GUARD_TIMEOUT_MS;
    const binary = hookScript(dir, "sleep 30");
    process.env.DOTFILES_ORCHESTRATION_HOOK = binary;
    process.env.DOTFILES_ORCHESTRATION_GUARD_TIMEOUT_MS = "50";
    try {
      const started = Date.now();
      const { api, toolCallHandler } = fakeApi();
      await extension(api);
      const result = await toolCallHandler({ toolName: "task" });
      expect(result).toBeUndefined();
      expect(Date.now() - started).toBeLessThan(1_000);
    } finally {
      if (previousHook === undefined) delete process.env.DOTFILES_ORCHESTRATION_HOOK;
      else process.env.DOTFILES_ORCHESTRATION_HOOK = previousHook;
      if (previousTimeout === undefined) delete process.env.DOTFILES_ORCHESTRATION_GUARD_TIMEOUT_MS;
      else process.env.DOTFILES_ORCHESTRATION_GUARD_TIMEOUT_MS = previousTimeout;
      rmSync(dir, { recursive: true, force: true });
    }
  });

  it("never spawns the guard for non-task tools", async () => {
    const dir = mkdtempSync(join(tmpdir(), "dotfiles-orca-no-spawn-"));
    const marker = join(dir, "spawned");
    const previous = process.env.DOTFILES_ORCHESTRATION_HOOK;
    const denyDoc = JSON.stringify({
      hookSpecificOutput: {
        hookEventName: "PreToolUse",
        permissionDecision: "deny",
        permissionDecisionReason: "should not be called",
      },
    });
    process.env.DOTFILES_ORCHESTRATION_HOOK = hookScript(
      dir,
      `touch ${JSON.stringify(marker)}\nprintf '%s\\n' '${denyDoc}'`,
    );
    try {
      const { api, toolCallHandler } = fakeApi();
      await extension(api);
      const result = await toolCallHandler({ toolName: "bash" });
      expect(result).toBeUndefined();
      expect(existsSync(marker)).toBe(false);
    } finally {
      if (previous === undefined) delete process.env.DOTFILES_ORCHESTRATION_HOOK;
      else process.env.DOTFILES_ORCHESTRATION_HOOK = previous;
      rmSync(dir, { recursive: true, force: true });
    }
  });
});
