import { mkdir, mkdtemp, readFile, writeFile } from "node:fs/promises";
import { join } from "node:path";
import { homedir } from "node:os";
import { afterEach, describe, expect, test } from "vite-plus/test";
import { DEFAULT_LOCK_PATH, runCli } from "../src/cli.js";
import { resolveGitHubRelease } from "../src/github.js";
import { resolveGitHubTag } from "../src/github-tag.js";
import { resolveGitHubSkillCollection } from "../src/github-skill-collection.js";
import { resolveGitLabRelease } from "../src/gitlab.js";
import { resolveNpmPackage } from "../src/npm.js";
import { resolveVendorManifest } from "../src/vendor-manifest.js";
import { RESOLVERS, resolveAll } from "../src/resolve-all.js";
import type { LockedArtifact, LockedSkillCollection, Registry, ReleaseLock } from "../src/types.js";

const realFetch = globalThis.fetch;

afterEach(() => {
  globalThis.fetch = realFetch;
});

async function scratch(): Promise<string> {
  const base = process.env["XDG_RUNTIME_DIR"] ?? join(homedir(), ".cache");
  const root = join(base, "release-lock-cli-tests");
  await mkdir(root, { recursive: true, mode: 0o700 });
  return mkdtemp(join(root, "case-"));
}

function locked(version: string): ReleaseLock {
  const failed: LockedSkillCollection = {
    kind: "githubSkillCollection",
    source: "owner/failed",
    version: "1.0.0",
    revision: "f".repeat(40),
    skills: ["figma-alpha", "figma-zeta"],
  };
  return {
    releases: {
      tools: {
        good: { kind: "githubRelease", source: "owner/good", version },
        failed,
        retired: { kind: "githubRelease", source: "owner/retired", version: "v1" },
      },
    },
  };
}

function resolution(failures: string[] = []): {
  lock: ReleaseLock;
  failures: string[];
} {
  return {
    lock: {
      releases: {
        tools: {
          good: { kind: "githubRelease", source: "owner/good", version: "v2" },
        },
      },
    },
    failures,
  };
}

function capture(): { values: string[]; write(value: string): void } {
  const values: string[] = [];
  return { values, write: (value) => void values.push(value) };
}

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
      "githubSkillCollection",
      "githubTag",
      "gitlabRelease",
      "npm",
      "vendorManifest",
    ]);
  });

  test("wires each fetch-based kind to its resolver by identity", () => {
    expect(RESOLVERS.githubRelease).toBe(resolveGitHubRelease);
    expect(RESOLVERS.githubTag).toBe(resolveGitHubTag);
    expect(RESOLVERS.githubSkillCollection).toBe(resolveGitHubSkillCollection);
    expect(RESOLVERS.gitlabRelease).toBe(resolveGitLabRelease);
    expect(RESOLVERS.npm).toBe(resolveNpmPackage);
    expect(RESOLVERS.vendorManifest).toBe(resolveVendorManifest);
  });

  test("gitRef dispatches through its own wrapper, not another kind's resolver", () => {
    expect(typeof RESOLVERS.gitRef).toBe("function");
    for (const [kind, other] of Object.entries(RESOLVERS)) {
      if (kind === "gitRef") continue;
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

describe("runCli", () => {
  test("the default path points at the repository lock", async () => {
    expect(DEFAULT_LOCK_PATH.endsWith("/.chezmoidata/releases.json")).toBe(true);
    expect(JSON.parse(await readFile(DEFAULT_LOCK_PATH, "utf8"))).toHaveProperty("releases.tools");
  });

  test("default refresh carries failed entries forward in place", async () => {
    const path = join(await scratch(), "releases.json");
    await writeFile(path, `${JSON.stringify(locked("v1"))}\n`);
    const stdout = capture();
    const stderr = capture();

    const exit = await runCli([], {
      defaultPath: path,
      stdout,
      stderr,
      resolve: async () => resolution(["owner/failed: unavailable"]),
    });

    expect(exit).toBe(1);
    expect(stdout.values).toEqual([]);
    expect(stderr.values.join("")).toContain("owner/failed");
    const written = JSON.parse(await readFile(path, "utf8")) as ReleaseLock;
    expect(written.releases.tools["good"]?.version).toBe("v2");
    expect(written.releases.tools["failed"]).toEqual({
      kind: "githubSkillCollection",
      source: "owner/failed",
      version: "1.0.0",
      revision: "f".repeat(40),
      skills: ["figma-alpha", "figma-zeta"],
    });
    expect(written.releases.tools["retired"]?.version).toBe("v1");
  });

  test("a clean default refresh prunes retired entries", async () => {
    const path = join(await scratch(), "releases.json");
    await writeFile(path, `${JSON.stringify(locked("v1"))}\n`);

    expect(
      await runCli([], {
        defaultPath: path,
        stderr: capture(),
        resolve: async () => resolution(),
      }),
    ).toBe(0);

    const written = JSON.parse(await readFile(path, "utf8")) as ReleaseLock;
    expect(Object.keys(written.releases.tools)).toEqual(["good"]);
  });

  test("covers AE1: a stubbed fetch failure prunes that tool's stale windows-amd64 key while its other artifacts and the succeeding tool's fresh data survive", async () => {
    const path = join(await scratch(), "releases.json");
    const flakyArtifacts: Record<string, LockedArtifact> = {
      "linux-amd64": { url: "https://example.com/flaky/linux-amd64", sha256: "a".repeat(64) },
      "darwin-arm64": { url: "https://example.com/flaky/darwin-arm64", sha256: "b".repeat(64) },
      "windows-amd64": { url: "https://example.com/flaky/windows-amd64", sha256: "c".repeat(64) },
    };
    const committed: ReleaseLock = {
      releases: {
        tools: {
          flaky: {
            kind: "githubRelease",
            source: "owner/flaky",
            version: "v1",
            artifacts: flakyArtifacts,
          },
          steady: { kind: "githubRelease", source: "owner/steady", version: "v1" },
        },
      },
    };
    await writeFile(path, `${JSON.stringify(committed)}\n`);

    const exit = await runCli([], {
      defaultPath: path,
      stderr: capture(),
      resolve: async () => ({
        lock: {
          releases: {
            tools: { steady: { kind: "githubRelease", source: "owner/steady", version: "v2" } },
          },
        },
        failures: ["owner/flaky: rate limited"],
      }),
    });

    expect(exit).toBe(1);
    const written = JSON.parse(await readFile(path, "utf8")) as ReleaseLock;
    expect(written.releases.tools["flaky"]?.artifacts).toEqual({
      "linux-amd64": { url: "https://example.com/flaky/linux-amd64", sha256: "a".repeat(64) },
      "darwin-arm64": { url: "https://example.com/flaky/darwin-arm64", sha256: "b".repeat(64) },
    });
    expect(written.releases.tools["flaky"]?.version).toBe("v1");
    expect(written.releases.tools["steady"]?.version).toBe("v2");
  });

  test("--stdout emits a merged lock without modifying the input", async () => {
    const path = join(await scratch(), "releases.json");
    const before = `${JSON.stringify(locked("v1"))}\n`;
    await writeFile(path, before);
    const stdout = capture();

    const exit = await runCli(["--stdout"], {
      defaultPath: path,
      stdout,
      stderr: capture(),
      resolve: async () => resolution(["owner/failed: unavailable"]),
    });

    expect(exit).toBe(1);
    expect(await readFile(path, "utf8")).toBe(before);
    const emitted = JSON.parse(stdout.values.join("")) as ReleaseLock;
    expect(emitted.releases.tools["failed"]?.version).toBe("1.0.0");
  });

  test("--out refreshes the explicit destination", async () => {
    const root = await scratch();
    const defaultPath = join(root, "default.json");
    const destination = join(root, "other.json");
    await writeFile(defaultPath, `${JSON.stringify(locked("default"))}\n`);
    await writeFile(destination, `${JSON.stringify(locked("v1"))}\n`);

    const exit = await runCli(["--out", destination], {
      defaultPath,
      stderr: capture(),
      resolve: async () => resolution(["owner/failed: unavailable"]),
    });

    expect(exit).toBe(1);
    const written = JSON.parse(await readFile(destination, "utf8")) as ReleaseLock;
    expect(written.releases.tools["failed"]?.version).toBe("1.0.0");
    expect(await readFile(defaultPath, "utf8")).toContain("default");
  });

  test("missing input is a first run, but empty input fails loudly", async () => {
    const root = await scratch();
    const missing = join(root, "missing.json");
    expect(await runCli([], { defaultPath: missing, resolve: async () => resolution() })).toBe(0);
    expect(JSON.parse(await readFile(missing, "utf8"))).toEqual(resolution().lock);

    for (const [name, content] of [
      ["empty", ""],
      ["whitespace", " \n\t"],
    ] as const) {
      const malformed = join(root, `${name}.json`);
      await writeFile(malformed, content);
      await expect(
        runCli([], { defaultPath: malformed, resolve: async () => resolution() }),
      ).rejects.toThrow();
      expect(await readFile(malformed, "utf8")).toBe(content);
    }
  });

  test("invalid output flags fail before resolution", async () => {
    let resolved = false;
    const resolve = async (): Promise<ReturnType<typeof resolution>> => {
      resolved = true;
      return resolution();
    };

    expect(await runCli(["--out"], { stderr: capture(), resolve })).toBe(2);
    expect(await runCli(["--stdout", "--out", "lock.json"], { stderr: capture(), resolve })).toBe(
      2,
    );
    expect(resolved).toBe(false);
  });
});
