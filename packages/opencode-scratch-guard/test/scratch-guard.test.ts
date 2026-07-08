import assert from "node:assert/strict";
import { mkdirSync, mkdtempSync, rmSync } from "node:fs";
import { homedir } from "node:os";
import { join, resolve } from "node:path";
import { afterAll, beforeAll, describe, test } from "bun:test";

import {
  computeScratchDir,
  deniedRoots,
  isDeniedPath,
  makeBashDenyRegex,
  parseMode,
  ScratchGuardPlugin,
} from "../src/index.ts";

// The exported helpers are pure (no I/O, no env reads), so these exercise the
// deny/inject logic directly. Only the plugin factory touches the filesystem,
// covered separately by the integration block with a cleaned-up scratch dir.

describe("parseMode", () => {
  test("defaults to enforce for unset/empty/unknown", () => {
    assert.equal(parseMode(undefined), "enforce");
    assert.equal(parseMode(""), "enforce");
    assert.equal(parseMode("enforce"), "enforce");
    assert.equal(parseMode("nonsense"), "enforce");
  });

  test("recognises off/warn case-insensitively", () => {
    assert.equal(parseMode("off"), "off");
    assert.equal(parseMode("0"), "off");
    assert.equal(parseMode("false"), "off");
    assert.equal(parseMode("OFF"), "off");
    assert.equal(parseMode("warn"), "warn");
    assert.equal(parseMode("  WARN  "), "warn");
  });
});

describe("deniedRoots", () => {
  test("linux denies the three shared temp roots", () => {
    assert.deepEqual([...deniedRoots("linux")], ["/tmp", "/var/tmp", "/dev/shm"]);
  });

  test("darwin also denies the /private realpath aliases", () => {
    const roots = deniedRoots("darwin");
    assert.ok(roots.includes("/private/tmp"));
    assert.ok(roots.includes("/private/var/tmp"));
  });

  test("win32 denies nothing (%TEMP% is already per-user)", () => {
    assert.deepEqual([...deniedRoots("win32")], []);
  });
});

describe("computeScratchDir", () => {
  test("linux prefers $XDG_RUNTIME_DIR", () => {
    assert.equal(
      computeScratchDir(
        { XDG_RUNTIME_DIR: "/run/user/1000" } as NodeJS.ProcessEnv,
        "linux",
        "/home/u",
      ),
      resolve("/run/user/1000", "agent-scratch"),
    );
  });

  test("linux falls back to ~/.cache (never /tmp) when XDG is unset", () => {
    assert.equal(
      computeScratchDir({} as NodeJS.ProcessEnv, "linux", "/home/u"),
      resolve("/home/u", ".cache", "agent-scratch"),
    );
  });

  test("darwin prefers $TMPDIR", () => {
    assert.equal(
      computeScratchDir({ TMPDIR: "/var/folders/x/T/" } as NodeJS.ProcessEnv, "darwin", "/Users/u"),
      resolve("/var/folders/x/T/", "agent-scratch"),
    );
  });

  test("win32 prefers %TEMP%, else a per-user AppData fallback", () => {
    const withTemp = computeScratchDir(
      { TEMP: "/win/temp" } as NodeJS.ProcessEnv,
      "win32",
      "/home/u",
    );
    assert.ok(withTemp.endsWith("agent-scratch"));
    assert.ok(withTemp.includes("/win/temp"));

    const noTemp = computeScratchDir({} as NodeJS.ProcessEnv, "win32", "/home/u");
    assert.ok(noTemp.endsWith("agent-scratch"));
    assert.ok(noTemp.includes("AppData"));
  });
});

describe("isDeniedPath (linux)", () => {
  const base = "/home/h82/project";
  const denied = (p: string) => isDeniedPath(p, "linux", base);

  test("blocks paths at or under a denied root", () => {
    assert.ok(denied("/tmp"));
    assert.ok(denied("/tmp/scratch.txt"));
    assert.ok(denied("/var/tmp/build/out"));
    assert.ok(denied("/dev/shm/ring"));
  });

  test("allows workspace, home, and look-alike paths", () => {
    assert.ok(!denied("/home/h82/project/file.ts"));
    assert.ok(!denied("/home/h82/tmp/x")); // a personal tmp dir, not the system one
    assert.ok(!denied("/tmpfoo/x")); // shares a prefix but is a different root
    assert.ok(!denied("scratch.txt")); // relative → resolves under the workspace base
  });

  test("win32 never denies (no shared temp to guard)", () => {
    assert.ok(!isDeniedPath("/tmp/x", "win32", base));
  });
});

describe("makeBashDenyRegex (linux)", () => {
  const re = makeBashDenyRegex("linux");

  const hits = (command: string) => (re ? re.exec(command)?.[0] : undefined);

  test("flags a denied root as an absolute path token", () => {
    assert.equal(hits("cat /tmp/x.log"), "/tmp");
    assert.equal(hits("cd /tmp && ls"), "/tmp");
    assert.equal(hits("echo hi > /tmp/out"), "/tmp");
    assert.equal(hits("TMPDIR=/tmp/foo cmd"), "/tmp");
    assert.equal(hits('touch "/tmp/x"'), "/tmp");
    assert.equal(hits("rm -rf /var/tmp/build"), "/var/tmp");
    assert.equal(hits("ls /dev/shm"), "/dev/shm");
  });

  test("ignores non-path and look-alike references", () => {
    assert.equal(hits("echo $TMPDIR"), undefined);
    assert.equal(hits("cat /home/h82/tmp/x"), undefined);
    assert.equal(hits("cat ./tmp/x"), undefined);
    assert.equal(hits("cat /tmpfs/x"), undefined);
    assert.equal(hits("grep tmp file.txt"), undefined);
    assert.equal(hits('f="$(mktemp)"; echo hi > "$f"'), undefined);
  });

  test("win32 has no bash deny regex", () => {
    assert.equal(makeBashDenyRegex("win32"), null);
  });
});

describe("ScratchGuardPlugin integration", () => {
  const saved = {
    xdg: process.env["XDG_RUNTIME_DIR"],
    mode: process.env["OPENCODE_SCRATCH_GUARD"],
  };
  let runtimeDir = "";

  const fakeInput = (directory: string) =>
    ({
      client: { app: { log: async () => ({}) } },
      directory,
    }) as unknown as Parameters<typeof ScratchGuardPlugin>[0];

  beforeAll(() => {
    // A per-user (never /tmp) throwaway runtime dir so the factory's mkdir of
    // <XDG_RUNTIME_DIR>/agent-scratch is contained and deterministic.
    mkdirSync(join(homedir(), ".cache"), { recursive: true });
    runtimeDir = mkdtempSync(join(homedir(), ".cache", "scratch-guard-test-"));
    process.env["XDG_RUNTIME_DIR"] = runtimeDir;
    delete process.env["OPENCODE_SCRATCH_GUARD"]; // default → enforce
  });

  afterAll(() => {
    if (saved.xdg === undefined) delete process.env["XDG_RUNTIME_DIR"];
    else process.env["XDG_RUNTIME_DIR"] = saved.xdg;
    if (saved.mode === undefined) delete process.env["OPENCODE_SCRATCH_GUARD"];
    else process.env["OPENCODE_SCRATCH_GUARD"] = saved.mode;
    if (runtimeDir) rmSync(runtimeDir, { recursive: true, force: true });
  });

  test("shell.env injects TMPDIR = the per-user scratch dir", async () => {
    const hooks = await ScratchGuardPlugin(fakeInput(process.cwd()));
    const shellEnv = hooks["shell.env"];
    assert.ok(shellEnv, "plugin must register a shell.env hook in enforce mode");
    const output = { env: {} as Record<string, string> };
    await shellEnv({ cwd: process.cwd() } as never, output as never);
    assert.equal(output.env["TMPDIR"], resolve(runtimeDir, "agent-scratch"));
  });

  test("tool.execute.before throws on a write under /tmp", async () => {
    const hooks = await ScratchGuardPlugin(fakeInput("/home/h82/project"));
    const hook = hooks["tool.execute.before"];
    assert.ok(hook, "plugin must register a tool.execute.before hook in enforce mode");
    await assert.rejects(
      () =>
        hook(
          { tool: "write", sessionID: "s", callID: "c" } as never,
          { args: { filePath: "/tmp/scratch.txt" } } as never,
        ),
      /shared system temp/,
    );
  });

  test("tool.execute.before allows a write inside the workspace", async () => {
    const hooks = await ScratchGuardPlugin(fakeInput("/home/h82/project"));
    const hook = hooks["tool.execute.before"];
    assert.ok(hook);
    await hook(
      { tool: "write", sessionID: "s", callID: "c" } as never,
      { args: { filePath: "/home/h82/project/file.ts" } } as never,
    );
  });

  test("tool.execute.before throws on a bash command writing to /tmp", async () => {
    const hooks = await ScratchGuardPlugin(fakeInput(process.cwd()));
    const hook = hooks["tool.execute.before"];
    assert.ok(hook);
    await assert.rejects(
      () =>
        hook(
          { tool: "bash", sessionID: "s", callID: "c" } as never,
          { args: { command: "echo hi > /tmp/out.txt" } } as never,
        ),
      /Blocked/,
    );
  });

  test("tool.execute.before allows a bash command using $TMPDIR", async () => {
    const hooks = await ScratchGuardPlugin(fakeInput(process.cwd()));
    const hook = hooks["tool.execute.before"];
    assert.ok(hook);
    await hook(
      { tool: "bash", sessionID: "s", callID: "c" } as never,
      { args: { command: 'f="$(mktemp)"; echo hi > "$f"' } } as never,
    );
  });

  test("warn mode attaches output.message instead of throwing", async () => {
    process.env["OPENCODE_SCRATCH_GUARD"] = "warn";
    try {
      const hooks = await ScratchGuardPlugin(fakeInput(process.cwd()));
      const hook = hooks["tool.execute.before"];
      assert.ok(hook);
      const output = { args: { command: "cat /tmp/x" } } as {
        args: Record<string, unknown>;
        message?: string;
      };
      await hook({ tool: "bash", sessionID: "s", callID: "c" } as never, output as never);
      assert.match(output.message ?? "", /shared system temp/);
    } finally {
      delete process.env["OPENCODE_SCRATCH_GUARD"];
    }
  });

  test("off mode registers no hooks at all", async () => {
    process.env["OPENCODE_SCRATCH_GUARD"] = "off";
    try {
      const hooks = await ScratchGuardPlugin(fakeInput(process.cwd()));
      assert.equal(hooks["shell.env"], undefined);
      assert.equal(hooks["tool.execute.before"], undefined);
    } finally {
      delete process.env["OPENCODE_SCRATCH_GUARD"];
    }
  });
});
