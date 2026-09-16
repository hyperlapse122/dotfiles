import { describe, expect, it } from "vitest";
import { mkdir, readFile, writeFile } from "node:fs/promises";
import { join } from "node:path";
import { tmpdir } from "node:os";
import {
  reconcileClaudeTrust,
  reconcileCodexTrust,
  reconcileTrust,
} from "../src/trust.js";

async function makeScratch(): Promise<string> {
  const dir = join(tmpdir(), `test-trust-${Date.now()}-${Math.random().toString(36).slice(2)}`);
  await mkdir(dir, { recursive: true, mode: 0o700 });
  return dir;
}

describe("trust reconciliation", () => {
  it("additively asserts claude trust and preserves existing projects", async () => {
    const scratch = await makeScratch();
    const claudeJson = join(scratch, ".claude.json");
    await writeFile(
      claudeJson,
      JSON.stringify(
        {
          numInvocations: 42,
          projects: {
            "/existing/project": {
              hasTrustDialogAccepted: true,
              customKey: "value",
            },
          },
        },
        null,
        2,
      ),
    );

    const ok = await reconcileClaudeTrust(claudeJson, ["/new/project/a", "/existing/project"]);
    expect(ok).toBe(true);

    const content = JSON.parse(await readFile(claudeJson, "utf8"));
    expect(content.numInvocations).toBe(42);
    expect(content.projects["/existing/project"].hasTrustDialogAccepted).toBe(true);
    expect(content.projects["/existing/project"].customKey).toBe("value");
    expect(content.projects["/new/project/a"].hasTrustDialogAccepted).toBe(true);
  });

  it("additively asserts codex trust into config.toml", async () => {
    const scratch = await makeScratch();
    const codexHome = join(scratch, ".codex");
    const codexConfig = join(codexHome, "config.toml");
    await mkdir(codexHome, { recursive: true, mode: 0o700 });
    await writeFile(codexConfig, 'model = "gpt-5"\n\n[projects."/existing/repo"]\ntrust_level = "trusted"\n');

    const ok = await reconcileCodexTrust(codexHome, codexConfig, ["/new/repo/b"]);
    expect(ok).toBe(true);

    const content = await readFile(codexConfig, "utf8");
    expect(content).toContain('model = "gpt-5"');
    expect(content).toContain('projects."/existing/repo"');
    expect(content).toContain('projects."/new/repo/b"');
    expect(content).toContain('trust_level = "trusted"');
  });

  it("reconciles trust end-to-end for explicit paths and discovered worktrees", async () => {
    const scratch = await makeScratch();
    const claudeJson = join(scratch, ".claude.json");
    const codexHome = join(scratch, ".codex");
    const codexConfig = join(codexHome, "config.toml");
    const wtDir = join(scratch, "worktrees");
    const wtPath = join(wtDir, "branch-1");

    await mkdir(join(wtPath, ".git"), { recursive: true });

    const result = await reconcileTrust({
      explicitPaths: ["/explicit/path"],
      all: true,
      claudeConfigFile: claudeJson,
      codexHome,
      codexConfigFile: codexConfig,
      worktreesDir: wtDir,
      gardenFile: join(scratch, "nonexistent-garden.yaml"),
    });

    expect(result.claudeOk).toBe(true);
    expect(result.codexOk).toBe(true);
    expect(result.pathsCount).toBe(2);

    const claudeContent = JSON.parse(await readFile(claudeJson, "utf8"));
    expect(claudeContent.projects["/explicit/path"].hasTrustDialogAccepted).toBe(true);
    expect(claudeContent.projects[wtPath].hasTrustDialogAccepted).toBe(true);

    const codexContent = await readFile(codexConfig, "utf8");
    expect(codexContent).toContain('projects."/explicit/path"');
    expect(codexContent).toContain(`projects."${wtPath}"`);
  });
});
