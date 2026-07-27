import { afterEach, describe, expect, test } from "vite-plus/test";
import { resolveGitHubRelease } from "../src/github.js";
import { resolveGitHubTag } from "../src/github-tag.js";
import { resolveGitLabRelease } from "../src/gitlab.js";
import { resolveNpmPackage } from "../src/npm.js";
import { resolveVendorManifest } from "../src/vendor-manifest.js";
import { RESOLVERS, resolveAll } from "../src/resolve-all.js";
import type { Registry } from "../src/types.js";

const realFetch = globalThis.fetch;

afterEach(() => {
  globalThis.fetch = realFetch;
});

interface SourceStub {
  status: number;
  tagName?: string;
}

/** Route fetch by the `/repos/<source>/` in the URL; anything unmatched throws. */
function stubFetchBySource(stubs: Record<string, SourceStub>): void {
  globalThis.fetch = (async (input) => {
    const url = String(input);
    for (const [source, stub] of Object.entries(stubs)) {
      if (!url.includes(`/repos/${source}/`)) continue;
      if (stub.status !== 200) return new Response("nope", { status: stub.status });
      return new Response(JSON.stringify({ tag_name: stub.tagName, assets: [] }), {
        status: 200,
        headers: { "content-type": "application/json" },
      });
    }
    throw new Error(`unexpected fetch: ${url}`);
  }) as typeof globalThis.fetch;
}

describe("RESOLVERS dispatch", () => {
  test("maps every ResolverKind", () => {
    expect(Object.keys(RESOLVERS).sort()).toEqual([
      "gitRef",
      "githubRelease",
      "githubTag",
      "gitlabRelease",
      "npm",
      "vendorManifest",
    ]);
  });

  test("wires each fetch-based kind to its resolver by identity", () => {
    expect(RESOLVERS.githubRelease).toBe(resolveGitHubRelease);
    expect(RESOLVERS.githubTag).toBe(resolveGitHubTag);
    expect(RESOLVERS.gitlabRelease).toBe(resolveGitLabRelease);
    expect(RESOLVERS.npm).toBe(resolveNpmPackage);
    expect(RESOLVERS.vendorManifest).toBe(resolveVendorManifest);
  });

  test("gitRef dispatches through its own wrapper, not another kind's resolver", () => {
    expect(typeof RESOLVERS.gitRef).toBe("function");
    for (const other of [
      resolveGitHubRelease,
      resolveGitHubTag,
      resolveGitLabRelease,
      resolveNpmPackage,
      resolveVendorManifest,
    ]) {
      expect(RESOLVERS.gitRef).not.toBe(other);
    }
  });
});

describe("resolveAll", () => {
  test("emits { releases: { tools } } with sorted keys", async () => {
    const registry: Registry = {
      zed: { kind: "githubRelease", source: "owner/zed" },
      abc: { kind: "githubRelease", source: "owner/abc" },
    };
    stubFetchBySource({
      "owner/zed": { status: 200, tagName: "v1.0.0" },
      "owner/abc": { status: 200, tagName: "v2.0.0" },
    });

    const { lock, failures } = await resolveAll(undefined, registry);

    expect(failures).toEqual([]);
    expect(lock).toEqual({
      releases: {
        tools: {
          abc: { kind: "githubRelease", source: "owner/abc", version: "v2.0.0" },
          zed: { kind: "githubRelease", source: "owner/zed", version: "v1.0.0" },
        },
      },
    });
    expect(Object.keys(lock.releases.tools)).toEqual(["abc", "zed"]);
  });

  test("a source whose fetch 404s is omitted from the lock and recorded in failures", async () => {
    const registry: Registry = {
      good: { kind: "githubRelease", source: "owner/good" },
      bad: { kind: "githubRelease", source: "owner/bad" },
    };
    stubFetchBySource({
      "owner/good": { status: 200, tagName: "v1" },
      "owner/bad": { status: 404 },
    });

    const { lock, failures } = await resolveAll(undefined, registry);

    expect(Object.keys(lock.releases.tools)).toEqual(["good"]);
    expect(lock.releases.tools["good"]?.version).toBe("v1");
    expect(failures).toHaveLength(1);
    expect(failures[0]).toContain("owner/bad");
  });

  test("an empty registry resolves to an empty lock with no failures", async () => {
    const { lock, failures } = await resolveAll(undefined, {});
    expect(lock).toEqual({ releases: { tools: {} } });
    expect(failures).toEqual([]);
  });

  test("a non-Error rejection is stringified into failures rather than crashing", async () => {
    const registry: Registry = { bad: { kind: "githubRelease", source: "owner/bad" } };
    globalThis.fetch = (async () => {
      throw "boom";
    }) as typeof globalThis.fetch;

    const { lock, failures } = await resolveAll(undefined, registry);

    expect(lock).toEqual({ releases: { tools: {} } });
    expect(failures).toEqual(["boom"]);
  });
});
