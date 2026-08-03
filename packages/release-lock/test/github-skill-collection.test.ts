import { afterEach, describe, expect, test } from "vite-plus/test";
import { resolveGitHubSkillCollection } from "../src/github-skill-collection.js";
import { ResolutionError, type ToolSpec } from "../src/types.js";

const realFetch = globalThis.fetch;
const SHA_1 = "1".repeat(40);
const SHA_2 = "2".repeat(40);
const SHA_3 = "3".repeat(40);

interface StubResponse {
  readonly body: unknown;
  readonly status?: number;
  readonly headers?: Record<string, string>;
  readonly rawBody?: string;
}

function commit(sha: string, message: string): unknown {
  return { sha, commit: { message } };
}

function tree(
  entries: readonly unknown[] = [
    { path: "skills/figma-zeta", mode: "040000", type: "tree" },
    { path: "skills/figma-zeta/SKILL.md", mode: "100644", type: "blob" },
    { path: "skills/figma-alpha", mode: "040000", type: "tree" },
    { path: "skills/figma-alpha/SKILL.md", mode: "100644", type: "blob" },
    { path: "skills/figma-alpha/references/guide.md", mode: "100644", type: "blob" },
  ],
  truncated = false,
): unknown {
  return { truncated, tree: entries };
}

function stubGitHub(routes: Record<string, StubResponse>, requests: Request[] = []): Request[] {
  globalThis.fetch = (async (input, init) => {
    const request = new Request(input, init);
    requests.push(request);
    const url = new URL(request.url);
    const route = routes[`${url.pathname}${url.search}`];
    if (!route) throw new Error(`unexpected fetch: ${url.pathname}${url.search}`);
    return new Response(route.rawBody ?? JSON.stringify(route.body), {
      status: route.status ?? 200,
      headers: { "content-type": "application/json", ...route.headers },
    });
  }) as typeof globalThis.fetch;
  return requests;
}

function routes(
  commits: readonly unknown[],
  selectedTree: unknown = tree(),
): Record<string, StubResponse> {
  return {
    "/repos/owner/repo/commits?path=skills%2F&per_page=100": { body: commits },
    [`/repos/owner/repo/git/trees/${SHA_1}?recursive=1`]: { body: selectedTree },
    [`/repos/owner/repo/git/trees/${SHA_2}?recursive=1`]: { body: selectedTree },
    [`/repos/owner/repo/git/trees/${SHA_3}?recursive=1`]: { body: selectedTree },
  };
}

afterEach(() => {
  globalThis.fetch = realFetch;
});

describe("resolveGitHubSkillCollection", () => {
  const spec: ToolSpec = { kind: "githubSkillCollection", source: "owner/repo" };

  test("selects the highest SemVer and emits a deterministic typed collection", async () => {
    stubGitHub(
      routes([commit(SHA_1, "Skills v2.0.0 (#20)"), commit(SHA_2, "Skills v1.5.0 (#21)")]),
    );

    await expect(resolveGitHubSkillCollection("figmaSkills", spec, undefined)).resolves.toEqual({
      kind: "githubSkillCollection",
      source: "owner/repo",
      version: "2.0.0",
      revision: SHA_1,
      skills: ["figma-alpha", "figma-zeta"],
    });
  });

  test("uses SemVer rather than API chronology and follows complete pagination", async () => {
    stubGitHub({
      "/repos/owner/repo/commits?path=skills%2F&per_page=100": {
        body: [commit(SHA_1, "Skills v1.9.0 (#19)")],
        headers: {
          link: '<https://api.github.com/repos/owner/repo/commits?path=skills%2F&per_page=100&page=2>; rel="next"',
        },
      },
      "/repos/owner/repo/commits?path=skills%2F&per_page=100&page=2": {
        body: [commit(SHA_2, "Skills v2.0.0 (#20)")],
      },
      [`/repos/owner/repo/git/trees/${SHA_2}?recursive=1`]: { body: tree() },
    });

    const locked = await resolveGitHubSkillCollection("figmaSkills", spec, undefined);
    expect(locked).toMatchObject({ version: "2.0.0", revision: SHA_2 });
  });

  test("applies prerelease precedence and treats build-only variants as tied", async () => {
    stubGitHub(
      routes([
        commit(SHA_1, "Skills v2.0.0-beta.11 (#1)"),
        commit(SHA_2, "Skills v2.0.0-beta.2 (#2)"),
      ]),
    );
    await expect(
      resolveGitHubSkillCollection("figmaSkills", spec, undefined),
    ).resolves.toMatchObject({
      version: "2.0.0-beta.11",
      revision: SHA_1,
    });

    stubGitHub(
      routes([
        commit(SHA_1, "Skills v2.0.0+build.1 (#1)"),
        commit(SHA_2, "Skills v2.0.0+build.2 (#2)"),
      ]),
    );
    await expect(resolveGitHubSkillCollection("figmaSkills", spec, undefined)).rejects.toThrow(
      /ambiguous.*2\.0\.0/i,
    );
  });

  test("rejects distinct commits tied at highest precedence but deduplicates the same SHA", async () => {
    stubGitHub(routes([commit(SHA_1, "Skills v2.0.0 (#1)"), commit(SHA_2, "Skills v2.0.0 (#2)")]));
    await expect(resolveGitHubSkillCollection("figmaSkills", spec, undefined)).rejects.toThrow(
      /ambiguous.*2\.0\.0/i,
    );

    stubGitHub(routes([commit(SHA_1, "Skills v2.0.0 (#1)"), commit(SHA_1, "Skills v2.0.0 (#1)")]));
    await expect(
      resolveGitHubSkillCollection("figmaSkills", spec, undefined),
    ).resolves.toMatchObject({
      version: "2.0.0",
      revision: SHA_1,
    });
  });

  test("matches only an exact first-line subject with a valid SemVer", async () => {
    stubGitHub(
      routes([
        commit(SHA_1, "prefix Skills v9.0.0 (#1)"),
        commit(SHA_1, "Skills v8.0.0 (#1) suffix"),
        commit(SHA_1, "chore\nSkills v7.0.0 (#1)"),
        commit(SHA_1, "Skills vnot-semver (#1)"),
        commit(SHA_2, "Skills v1.2.3 (#42)\n\nrelease details"),
      ]),
    );

    await expect(
      resolveGitHubSkillCollection("figmaSkills", spec, undefined),
    ).resolves.toMatchObject({
      version: "1.2.3",
      revision: SHA_2,
    });
  });

  test("selects only safe immediate figma directories with regular SKILL.md files", async () => {
    stubGitHub(
      routes(
        [commit(SHA_1, "Skills v1.0.0 (#1)")],
        tree([
          { path: "skills/figma-good", mode: "040000", type: "tree" },
          { path: "skills/figma-good/SKILL.md", mode: "100755", type: "blob" },
          { path: "skills/figma-file", mode: "100644", type: "blob" },
          { path: "skills/group", mode: "040000", type: "tree" },
          { path: "skills/group/figma-nested", mode: "040000", type: "tree" },
          { path: "skills/other-skill", mode: "040000", type: "tree" },
          { path: "skills/other-skill/SKILL.md", mode: "100644", type: "blob" },
        ]),
      ),
    );

    await expect(
      resolveGitHubSkillCollection("figmaSkills", spec, undefined),
    ).resolves.toMatchObject({
      skills: ["figma-good"],
    });
  });

  test.each([
    ["missing regular SKILL.md", [{ path: "skills/figma-bad", mode: "040000", type: "tree" }]],
    [
      "symlinked SKILL.md",
      [
        { path: "skills/figma-bad", mode: "040000", type: "tree" },
        { path: "skills/figma-bad/SKILL.md", mode: "120000", type: "blob" },
      ],
    ],
    [
      "unsafe relative path",
      [
        { path: "skills/figma-bad", mode: "040000", type: "tree" },
        { path: "skills/figma-bad/SKILL.md", mode: "100644", type: "blob" },
        { path: "skills/figma-bad/../escape", mode: "100644", type: "blob" },
      ],
    ],
    [
      "Windows reserved path",
      [
        { path: "skills/figma-bad", mode: "040000", type: "tree" },
        { path: "skills/figma-bad/SKILL.md", mode: "100644", type: "blob" },
        { path: "skills/figma-bad/references/CON.md", mode: "100644", type: "blob" },
      ],
    ],
    [
      "case collision",
      [
        { path: "skills/figma-bad", mode: "040000", type: "tree" },
        { path: "skills/figma-bad/SKILL.md", mode: "100644", type: "blob" },
        { path: "skills/figma-bad/skill.md", mode: "100644", type: "blob" },
      ],
    ],
    [
      "unsupported submodule",
      [
        { path: "skills/figma-bad", mode: "040000", type: "tree" },
        { path: "skills/figma-bad/SKILL.md", mode: "100644", type: "blob" },
        { path: "skills/figma-bad/vendor", mode: "160000", type: "commit" },
      ],
    ],
  ])("rejects a selected subtree with %s", async (_label, entries) => {
    stubGitHub(routes([commit(SHA_1, "Skills v1.0.0 (#1)")], tree(entries)));
    await expect(resolveGitHubSkillCollection("figmaSkills", spec, undefined)).rejects.toThrow(
      /owner\/repo/,
    );
  });

  test("rejects unsafe figma names, duplicate paths, empty inventory, and truncated trees", async () => {
    for (const selectedTree of [
      tree([
        { path: "skills/figma-Bad", mode: "040000", type: "tree" },
        { path: "skills/figma-Bad/SKILL.md", mode: "100644", type: "blob" },
      ]),
      tree([
        { path: "skills/figma-good", mode: "040000", type: "tree" },
        { path: "skills/figma-good/SKILL.md", mode: "100644", type: "blob" },
        { path: "skills/figma-good/SKILL.md", mode: "100644", type: "blob" },
      ]),
      tree([]),
      tree([], true),
    ]) {
      stubGitHub(routes([commit(SHA_1, "Skills v1.0.0 (#1)")], selectedTree));
      await expect(resolveGitHubSkillCollection("figmaSkills", spec, undefined)).rejects.toThrow(
        /owner\/repo/,
      );
    }
  });

  test("names the source for no candidates, HTTP errors, and malformed JSON", async () => {
    stubGitHub(routes([]));
    await expect(resolveGitHubSkillCollection("figmaSkills", spec, undefined)).rejects.toThrow(
      /owner\/repo/,
    );

    stubGitHub({
      "/repos/owner/repo/commits?path=skills%2F&per_page=100": { body: null, status: 503 },
    });
    const httpError = await resolveGitHubSkillCollection("figmaSkills", spec, undefined).catch(
      (error: unknown) => error,
    );
    expect(httpError).toBeInstanceOf(ResolutionError);
    expect((httpError as Error).message).toContain("owner/repo");

    stubGitHub({
      "/repos/owner/repo/commits?path=skills%2F&per_page=100": { body: null, rawBody: "{" },
    });
    await expect(resolveGitHubSkillCollection("figmaSkills", spec, undefined)).rejects.toThrow(
      /owner\/repo/,
    );
  });

  test("uses the existing authenticated GitHub request headers on every request", async () => {
    const requests: Request[] = [];
    stubGitHub(routes([commit(SHA_1, "Skills v1.0.0 (#1)")]), requests);

    await resolveGitHubSkillCollection("figmaSkills", spec, "secret-token");

    expect(requests).toHaveLength(2);
    for (const request of requests) {
      expect(request.headers.get("authorization")).toBe("Bearer secret-token");
      expect(request.headers.get("accept")).toBe("application/vnd.github+json");
      expect(request.headers.get("user-agent")).toBe("h82-release-lock");
    }
  });
});
