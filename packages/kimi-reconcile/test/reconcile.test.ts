import { mkdtemp, mkdir, readFile, symlink, writeFile } from "node:fs/promises";
import { join } from "node:path";
import { homedir } from "node:os";
import { describe, expect, test } from "vite-plus/test";
import { reconcilePlugin, reconcileSettings } from "../src/reconcile.js";

async function scratch(): Promise<string> {
  const base = process.env.XDG_RUNTIME_DIR ?? join(homedir(), ".cache");
  const root = join(base, "kimi-reconcile-tests");
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
});

describe("plugin reconciliation", () => {
  test("updates only compound-engineering and preserves unrelated state", async () => {
    const root = await scratch();
    const home = join(root, "home");
    const source = join(root, "source");
    await mkdir(join(source, ".kimi-plugin"), { recursive: true });
    await writeFile(
      join(source, ".kimi-plugin", "plugin.json"),
      JSON.stringify({ name: "compound-engineering", version: "3.20.0", skills: "./skills/" }),
    );
    await mkdir(join(source, "skills"));
    await writeFile(join(source, "skills", "SKILL.md"), "new");
    await mkdir(join(home, "plugins", "managed", "other"), { recursive: true });
    await writeFile(join(home, "plugins", "managed", "other", "keep"), "yes");
    await writeFile(
      join(home, "plugins", "installed.json"),
      JSON.stringify({
        version: 1,
        plugins: [
          { id: "other", root: "/keep", enabled: true, unknown: { keep: true } },
          {
            id: "compound-engineering",
            root: "/old",
            source: "old",
            enabled: false,
            installedAt: "2026-01-01T00:00:00.000Z",
            capabilities: { commands: ["keep"] },
          },
        ],
      }),
    );
    await reconcilePlugin(home, source, "compound-engineering-v3.20.0");
    const statePath = join(home, "plugins", "installed.json");
    const stateText = await readFile(statePath, "utf8");
    const state = JSON.parse(stateText);
    expect(state.plugins.map((entry: { id: string }) => entry.id)).toEqual([
      "other",
      "compound-engineering",
    ]);
    expect(state.plugins[0].unknown).toEqual({ keep: true });
    expect(state.plugins[1]).toMatchObject({
      source: "local-path",
      originalSource: source,
      enabled: false,
      installedAt: "2026-01-01T00:00:00.000Z",
      capabilities: { commands: ["keep"] },
    });
    expect(await readFile(join(home, "plugins", "managed", "other", "keep"), "utf8")).toBe("yes");
    expect(
      await readFile(
        join(home, "plugins", "managed", "compound-engineering", "skills", "SKILL.md"),
        "utf8",
      ),
    ).toBe("new");
    expect(await reconcilePlugin(home, source, "compound-engineering-v3.20.0")).toBe(false);
    expect(await readFile(statePath, "utf8")).toBe(stateText);
  });

  test("restores the previous managed tree when state publication fails", async () => {
    const root = await scratch();
    const home = join(root, "home");
    const source = join(root, "source");
    await mkdir(join(source, ".kimi-plugin"), { recursive: true });
    await writeFile(
      join(source, ".kimi-plugin", "plugin.json"),
      JSON.stringify({ name: "compound-engineering", version: "3.20.0" }),
    );
    await writeFile(join(source, "new"), "new");
    const managed = join(home, "plugins", "managed", "compound-engineering");
    await mkdir(managed, { recursive: true });
    await writeFile(join(managed, "old"), "old");
    const statePath = join(home, "plugins", "installed.json");
    const state = JSON.stringify({ version: 1, plugins: [] });
    await writeFile(statePath, state);

    await expect(
      reconcilePlugin(home, source, "compound-engineering-v3.20.0", {
        beforeStateWrite: async () => {
          throw new Error("injected state failure");
        },
      }),
    ).rejects.toThrow("injected state failure");
    expect(await readFile(join(managed, "old"), "utf8")).toBe("old");
    expect(await readFile(statePath, "utf8")).toBe(state);
  });

  test("does not delete a concurrent managed-tree update during rollback", async () => {
    const root = await scratch();
    const home = join(root, "home");
    const source = join(root, "source");
    await mkdir(join(source, ".kimi-plugin"), { recursive: true });
    await writeFile(
      join(source, ".kimi-plugin", "plugin.json"),
      JSON.stringify({ name: "compound-engineering", version: "3.20.0" }),
    );
    await writeFile(join(source, "new"), "new");

    await expect(
      reconcilePlugin(home, source, "compound-engineering-v3.20.0", {
        beforeStateWrite: async (managed) => {
          await writeFile(join(managed, "concurrent"), "keep");
          throw new Error("injected concurrent update");
        },
      }),
    ).rejects.toThrow("Concurrent managed plugin change detected during rollback");
    expect(
      await readFile(
        join(home, "plugins", "managed", "compound-engineering", "concurrent"),
        "utf8",
      ),
    ).toBe("keep");
  });

  test("recovers an abandoned backup and removes abandoned staging", async () => {
    const root = await scratch();
    const home = join(root, "home");
    const source = join(root, "source");
    await mkdir(join(source, ".kimi-plugin"), { recursive: true });
    await writeFile(
      join(source, ".kimi-plugin", "plugin.json"),
      JSON.stringify({ name: "compound-engineering", version: "3.20.0" }),
    );
    await writeFile(join(source, "current"), "current");
    const managed = join(home, "plugins", "managed");
    const backup = join(managed, `.compound-engineering.${"a".repeat(64)}.backup`);
    const stage = join(managed, ".compound-engineering.interrupted.stage");
    await mkdir(backup, { recursive: true });
    await mkdir(stage);
    await writeFile(join(backup, "old"), "old");
    await writeFile(join(stage, "partial"), "partial");
    await writeFile(
      join(home, "plugins", "installed.json"),
      JSON.stringify({ version: 1, plugins: [] }),
    );

    await reconcilePlugin(home, source, "compound-engineering-v3.20.0");
    expect(await readFile(join(managed, "compound-engineering", "current"), "utf8")).toBe(
      "current",
    );
    await expect(readFile(join(stage, "partial"), "utf8")).rejects.toMatchObject({
      code: "ENOENT",
    });
  });

  test("rejects malformed state and a mismatched manifest without mutation", async () => {
    const root = await scratch();
    const home = join(root, "home");
    const source = join(root, "source");
    await mkdir(join(source, ".kimi-plugin"), { recursive: true });
    await writeFile(join(source, ".kimi-plugin", "plugin.json"), JSON.stringify({ name: "other" }));
    await mkdir(join(home, "plugins"), { recursive: true });
    const malformed = "{broken";
    await writeFile(join(home, "plugins", "installed.json"), malformed);
    await expect(reconcilePlugin(home, source, "release")).rejects.toThrow();
    expect(await readFile(join(home, "plugins", "installed.json"), "utf8")).toBe(malformed);
  });
});
