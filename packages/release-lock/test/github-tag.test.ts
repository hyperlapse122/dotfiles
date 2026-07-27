import { afterEach, describe, expect, test } from "vite-plus/test";
import { resolveGitHubTag, ResolutionError } from "../src/github-tag.js";
import { versionFromTag } from "../src/platforms.js";
import type { ToolSpec } from "../src/types.js";

const realFetch = globalThis.fetch;

function stubTags(names: string[]): void {
  globalThis.fetch = (async () =>
    new Response(JSON.stringify(names.map((name) => ({ name }))), {
      status: 200,
      headers: { "content-type": "application/json" },
    })) as typeof globalThis.fetch;
}

afterEach(() => {
  globalThis.fetch = realFetch;
});

describe("resolveGitHubTag", () => {
  const spec = (overrides: Partial<ToolSpec> = {}): ToolSpec => ({
    kind: "githubTag",
    source: "owner/repo",
    ...overrides,
  });

  test("records the newest tag verbatim, version-only", async () => {
    stubTags(["v4.19.2", "v4.19.1"]);

    const locked = await resolveGitHubTag("tool", spec(), undefined);

    expect(locked.version).toBe("v4.19.2");
    expect(locked.artifacts).toBeUndefined();
  });

  test("applies the registry tag transform so consumers read the version verbatim", async () => {
    stubTags(["v1.3.9"]);

    const locked = await resolveGitHubTag(
      "tool",
      spec({ versionTransform: versionFromTag }),
      undefined,
    );

    expect(locked.version).toBe("1.3.9");
  });

  test("an empty tag list fails with the source named", async () => {
    stubTags([]);

    await expect(resolveGitHubTag("tool", spec(), undefined)).rejects.toThrow(/owner\/repo/);
  });

  test("a non-200 response fails with the source named", async () => {
    globalThis.fetch = (async () =>
      new Response("nope", { status: 404 })) as typeof globalThis.fetch;

    await expect(resolveGitHubTag("tool", spec(), undefined)).rejects.toBeInstanceOf(
      ResolutionError,
    );
    await expect(resolveGitHubTag("tool", spec(), undefined)).rejects.toThrow(/owner\/repo/);
  });
});
