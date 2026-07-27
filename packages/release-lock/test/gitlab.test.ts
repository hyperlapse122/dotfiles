import { afterEach, describe, expect, test } from "vite-plus/test";
import { resolveGitLabRelease, ResolutionError } from "../src/gitlab.js";
import type { ToolSpec } from "../src/types.js";

const realFetch = globalThis.fetch;

const SPEC: ToolSpec = {
  kind: "gitlabRelease",
  source: "https://gitlab.example.invalid/api/v4/projects/34675721",
};

function stubRelease(body: unknown, status = 200): void {
  globalThis.fetch = (async () =>
    new Response(typeof body === "string" ? body : JSON.stringify(body), {
      status,
      headers: { "content-type": "application/json" },
    })) as typeof globalThis.fetch;
}

afterEach(() => {
  globalThis.fetch = realFetch;
});

describe("resolveGitLabRelease", () => {
  test("records the tag from releases/permalink/latest, version-only", async () => {
    stubRelease({ tag_name: "v1.109.0" });

    const locked = await resolveGitLabRelease("glab", SPEC);

    expect(locked.version).toBe("v1.109.0");
    expect(locked.artifacts).toBeUndefined();
  });

  test("a response without tag_name fails with the source named", async () => {
    stubRelease({ name: "v1.109.0" });

    await expect(resolveGitLabRelease("glab", SPEC)).rejects.toThrow(/34675721/);
  });

  test("a non-200 response fails with the source named", async () => {
    stubRelease("nope", 500);

    const error = await resolveGitLabRelease("glab", SPEC).catch((e: unknown) => e);
    expect(error).toBeInstanceOf(ResolutionError);
    expect((error as Error).message).toMatch(/34675721/);
  });
});
