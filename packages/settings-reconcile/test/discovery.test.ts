import { describe, expect, it } from "vitest";
import { mkdir, writeFile } from "node:fs/promises";
import { join } from "node:path";
import { tmpdir } from "node:os";
import {
  discoverCheckouts,
  discoverGardenCheckouts,
  discoverWorktrees,
  parseGardenYamlContent,
} from "../src/discovery.js";

describe("discovery", () => {
  it("parses garden.yaml content with root and trees", () => {
    const yaml = `
garden:
  root: ~/src
trees:
  dotfiles:
    path: github.com/hyperlapse122/dotfiles
  pacs:
    path: git.example.com/products/pacs
`;
    const paths = parseGardenYamlContent(yaml);
    expect(paths.length).toBe(2);
    expect(paths.some((p) => p.endsWith("github.com/hyperlapse122/dotfiles"))).toBe(true);
    expect(paths.some((p) => p.endsWith("git.example.com/products/pacs"))).toBe(true);
  });

  it("handles srcRootOverride correctly", () => {
    const yaml = `
trees:
  my-repo:
    path: github.com/org/my-repo
`;
    const override = "/custom/src/root";
    const paths = parseGardenYamlContent(yaml, override);
    expect(paths).toEqual(["/custom/src/root/github.com/org/my-repo"]);
  });

  it("discovers garden checkouts from file", async () => {
    const base = join(tmpdir(), `test-garden-${Date.now()}-${Math.random().toString(36).slice(2)}`);
    const gardenFile = join(base, "garden.yaml");
    await mkdir(base, { recursive: true });
    await writeFile(
      gardenFile,
      `
trees:
  repo-a:
    path: github.com/example/repo-a
`,
    );

    const paths = await discoverGardenCheckouts(gardenFile, "/mock/src");
    expect(paths).toEqual(["/mock/src/github.com/example/repo-a"]);
  });

  it("discovers worktrees at flat and nested depth", async () => {
    const base = join(tmpdir(), `test-worktrees-${Date.now()}-${Math.random().toString(36).slice(2)}`);
    const wtFlat = join(base, "flat-branch");
    const wtNested = join(base, "dotfiles", "skimmer");
    const notWt = join(base, "ignored-dir");

    await mkdir(join(wtFlat, ".git"), { recursive: true });
    await mkdir(join(wtNested, ".git"), { recursive: true });
    await mkdir(notWt, { recursive: true });

    const discovered = await discoverWorktrees(base);
    expect(discovered).toContain(wtFlat);
    expect(discovered).toContain(wtNested);
    expect(discovered).not.toContain(notWt);
  });

  it("merges explicit paths and discovered paths", async () => {
    const base = join(tmpdir(), `test-disc-${Date.now()}-${Math.random().toString(36).slice(2)}`);
    const gardenFile = join(base, "garden.yaml");
    const srcDir = join(base, "src");
    const wtDir = join(base, "worktrees");

    await mkdir(srcDir, { recursive: true });
    await mkdir(wtDir, { recursive: true });

    await writeFile(
      gardenFile,
      `
trees:
  r1:
    path: r1
`,
    );

    const explicit = "/explicit/repo";
    const checkouts = await discoverCheckouts({
      explicitPaths: [explicit],
      all: true,
      gardenFile,
      srcDir,
      worktreesDir: wtDir,
    });

    expect(checkouts).toContain(explicit);
    expect(checkouts).toContain(join(srcDir, "r1"));
  });
});
