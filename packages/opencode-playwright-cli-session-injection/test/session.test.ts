import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { describe, test } from "node:test";

import { PlaywrightCliSessionInjectionPlugin } from "../src/index.ts";

// The plugin only writes one env var and never touches a socket or the
// filesystem, so these are pure-logic exercises with no harness. The plugin
// ignores its `PluginInput`, so a minimal `{} as never` stands in for it.

const envVarName = "PLAYWRIGHT_CLI_SESSION";

type ShellEnvInput = { cwd?: string };
type ShellEnvOutput = { env: Record<string, string> };

async function runShellEnv(input: ShellEnvInput, output: ShellEnvOutput): Promise<void> {
  const hooks = await PlaywrightCliSessionInjectionPlugin({} as never);
  const hook = hooks["shell.env"];
  assert.ok(hook, "plugin must register a shell.env hook");
  await hook(input as never, output as never);
}

// Independent re-derivation of the value the plugin is expected to produce:
// "opencode-" + first 8 hex chars of the SHA-1 of the RAW cwd (no slugify —
// plan 007 removed it).
function expectedSession(cwd: string): string {
  return `opencode-${createHash("sha1").update(cwd).digest("hex").slice(0, 8)}`;
}

describe("PlaywrightCliSessionInjectionPlugin shell.env", () => {
  test("sets PLAYWRIGHT_CLI_SESSION to opencode-<hash8>", async () => {
    const output: ShellEnvOutput = { env: {} };
    await runShellEnv({ cwd: "/home/h82/dotfiles" }, output);
    assert.match(output.env[envVarName], /^opencode-[0-9a-f]{8}$/);
  });

  test("is deterministic — the same cwd yields the same session", async () => {
    const first: ShellEnvOutput = { env: {} };
    const second: ShellEnvOutput = { env: {} };
    await runShellEnv({ cwd: "/some/project/path" }, first);
    await runShellEnv({ cwd: "/some/project/path" }, second);
    assert.equal(first.env[envVarName], second.env[envVarName]);
  });

  test("derives distinct sessions for cwds differing only by separator (plan-007 regression guard)", async () => {
    // With the old slugify step both `/a/b.c` and `/a/b-c` collapsed to the
    // same slug and collided; hashing the RAW cwd keeps them distinct.
    const dot: ShellEnvOutput = { env: {} };
    const dash: ShellEnvOutput = { env: {} };
    await runShellEnv({ cwd: "/a/b.c" }, dot);
    await runShellEnv({ cwd: "/a/b-c" }, dash);
    assert.notEqual(dot.env[envVarName], dash.env[envVarName]);
  });

  test("leaves output.env untouched when cwd is absent", async () => {
    const output: ShellEnvOutput = { env: {} };
    await runShellEnv({}, output);
    assert.deepEqual(output.env, {});
  });

  test("matches an independently computed sha1 of the raw cwd", async () => {
    const cwd = "/home/h82/dotfiles";
    const output: ShellEnvOutput = { env: {} };
    await runShellEnv({ cwd }, output);
    assert.equal(output.env[envVarName], expectedSession(cwd));
  });
});
