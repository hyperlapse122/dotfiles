import { spawnSync } from "node:child_process";
import { mkdtemp, mkdir, readFile, symlink, writeFile } from "node:fs/promises";
import { homedir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { describe, expect, test } from "vite-plus/test";
import { reconcileSettings } from "../src/reconcile.js";
import * as reconcile from "../src/reconcile.js";

const packageRoot = dirname(dirname(fileURLToPath(import.meta.url)));
const cliPath = join(packageRoot, "src", "cli.ts");

async function scratch(): Promise<string> {
  const base = process.env.XDG_RUNTIME_DIR ?? join(homedir(), ".cache");
  const root = join(base, "settings-reconcile-tests");
  await mkdir(root, { recursive: true, mode: 0o700 });
  return mkdtemp(join(root, "case-"));
}

describe("settings reconciliation", () => {
  test("overlays declared leaves and preserves undeclared values idempotently", async () => {
    const home = await scratch();
    await writeFile(join(home, "config.toml"), 'provider = "custom"\n[thinking]\neffort = "low"\n');
    await reconcileSettings(home, "config.toml", {
      default_model: "kimi-code/k3",
      thinking: { enabled: true, effort: "max" },
    });
    const once = await readFile(join(home, "config.toml"), "utf8");
    expect(once).toContain('provider = "custom"');
    expect(once).toContain('default_model = "kimi-code/k3"');
    expect(once).toContain('effort = "max"');
    await reconcileSettings(home, "config.toml", {
      default_model: "kimi-code/k3",
      thinking: { enabled: true, effort: "max" },
    });
    expect(await readFile(join(home, "config.toml"), "utf8")).toBe(once);
  });

  test("refuses malformed and symlink targets", async () => {
    const home = await scratch();
    await writeFile(join(home, "config.toml"), "[broken\n");
    await expect(reconcileSettings(home, "config.toml", { a: true })).rejects.toThrow();
    const other = join(home, "other.toml");
    await writeFile(other, "safe = true\n");
    await symlink(other, join(home, "tui.toml"));
    await expect(
      reconcileSettings(home, "tui.toml", { upgrade: { auto_install: false } }),
    ).rejects.toThrow(/symlink/);
  });

  test("rejects a table/scalar conflict before any mutation", async () => {
    const home = await scratch();
    await writeFile(join(home, "config.toml"), 'key = "scalar"\n');
    await expect(reconcileSettings(home, "config.toml", { key: { nested: true } })).rejects.toThrow(
      /conflicts with scalar/,
    );
    expect(await readFile(join(home, "config.toml"), "utf8")).toBe('key = "scalar"\n');
  });
});

describe("contract surface", () => {
  test("exports only the settings contract", () => {
    expect(reconcile.SETTINGS_CONTRACT).toBe("settings-reconcile/v1");
    expect(reconcile).not.toHaveProperty("PLUGIN_CONTRACT");
    expect(reconcile).not.toHaveProperty("reconcilePlugin");
  });
});

describe("command surface", () => {
  test("contracts emits only the settings contract", () => {
    const result = spawnSync("bun", [cliPath, "contracts"], { encoding: "utf8" } as const);
    expect(result.status).toBe(0);
    expect(result.stdout).toBe(JSON.stringify({ settings: reconcile.SETTINGS_CONTRACT }) + "\n");
    expect(result.stdout).not.toContain("plugin");
  });

  test("rejects the removed plugin command via usage handling", () => {
    const result = spawnSync("bun", [cliPath, "plugin", "/tmp/kimi", "/src", "release"], {
      encoding: "utf8",
    } as const);
    expect(result.status).toBe(2);
    expect(result.stderr).toMatch(/Usage/);
    expect(result.stderr).not.toMatch(/plugin/);
  });

  test("settings converges a declared leaf end to end", async () => {
    const home = await scratch();
    const declared = join(home, "declared.json");
    await writeFile(declared, JSON.stringify({ provider: "managed" }));
    const result = spawnSync("bun", [cliPath, "settings", home, "config.toml", declared], {
      encoding: "utf8",
    } as const);
    expect(result.status).toBe(0);
    expect(await readFile(join(home, "config.toml"), "utf8")).toContain('provider = "managed"');
  });
});
