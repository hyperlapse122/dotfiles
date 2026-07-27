import { describe, expect, test } from "vite-plus/test";
import { parseLsRemoteSha, resolveGitRef, ResolutionError } from "../src/git-ref.js";
import type { ToolSpec } from "../src/types.js";

const SHA = "03369ee6d7cafbfcecc4346539b05b3dc0a603bb";

describe("parseLsRemoteSha", () => {
  test("extracts the 40-character commit sha from ls-remote output", () => {
    expect(parseLsRemoteSha("owner/repo", `${SHA}\trefs/heads/main\n`)).toBe(SHA);
  });

  test("unparseable output fails with the source named", () => {
    expect(() => parseLsRemoteSha("owner/repo", "")).toThrow(ResolutionError);
    expect(() => parseLsRemoteSha("owner/repo", "not-a-sha\trefs/heads/main\n")).toThrow(
      /owner\/repo/,
    );
  });
});

describe("resolveGitRef", () => {
  const spec: ToolSpec = { kind: "gitRef", source: "owner/repo", ref: "refs/heads/main" };

  test("resolves the ref through the injected exec, version-only", async () => {
    const exec = async (args: readonly string[]): Promise<string> => {
      expect(args).toEqual([
        "ls-remote",
        "https://github.com/owner/repo.git",
        "refs/heads/main",
      ]);
      return `${SHA}\trefs/heads/main\n`;
    };

    const locked = await resolveGitRef("tool", spec, exec);

    expect(locked.version).toBe(SHA);
    expect(locked.artifacts).toBeUndefined();
  });

  test("an exec failure surfaces the source", async () => {
    const exec = async (): Promise<string> => {
      throw new Error("spawn git ENOENT");
    };

    await expect(resolveGitRef("tool", spec, exec)).rejects.toThrow(/owner\/repo/);
  });
});
