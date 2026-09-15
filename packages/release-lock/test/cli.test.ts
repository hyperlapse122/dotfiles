import { mkdir, mkdtemp, readFile, writeFile } from "node:fs/promises";
import { join } from "node:path";
import { homedir } from "node:os";
import { afterEach, describe, expect, test } from "vite-plus/test";
import { DEFAULT_LOCK_PATH, runCli } from "../src/cli.js";

test("prunes retired tools without resolving or changing retained releases", async () => {
  const dir = await scratch();
  const path = join(dir, "prune.json");
  const retained = {
    kind: "githubRelease",
    source: "openai/codex",
    version: "unchanged",
    artifacts: {},
  };
  await writeFile(
    path,
    JSON.stringify({ releases: { tools: { codex: retained, retired: retained } } }),
  );
  let resolved = false;
  expect(
    await runCli(["--prune-retired", "--out", path], {
      resolve: async () => {
        resolved = true;
        throw new Error("must not fetch");
      },
    }),
  ).toBe(0);
  expect(resolved).toBe(false);
  expect(JSON.parse(await readFile(path, "utf8"))).toEqual({
    releases: { tools: { codex: retained } },
  });
  expect(await runCli(["--prune-retired", "--only", "codex"], { stderr: capture() })).toBe(2);
});
import { resolveGitHubRelease } from "../src/github.js";
import { resolveGitHubTag } from "../src/github-tag.js";
import { resolveGitLabRelease } from "../src/gitlab.js";
import { resolveNpmPackage } from "../src/npm.js";
import { resolveVendorManifest } from "../src/vendor-manifest.js";
import { RESOLVERS, resolveAll } from "../src/resolve-all.js";
import type { LockedArtifact, Registry, ReleaseLock } from "../src/types.js";

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
  return {
    releases: {
      tools: {
        good: { kind: "githubRelease", source: "owner/good", version },
        failed: { kind: "githubRelease", source: "owner/failed", version: "1.0.0" },
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
  headers?: Record<string, string>;
}

/** Route fetch by the `/repos/<source>/` in the URL; anything unmatched throws. */
function stubFetchBySource(stubs: Record<string, SourceStub>): void {
  globalThis.fetch = (async (input) => {
    const url = input instanceof Request ? input.url : String(input);
    for (const [source, stub] of Object.entries(stubs)) {
      if (!url.includes(`/repos/${source}/`)) continue;
      if (stub.status !== 200) {
        const init: ResponseInit = { status: stub.status };
        if (stub.headers) init.headers = stub.headers;
        return new Response("nope", init);
      }
      const init: ResponseInit = {
        status: 200,
        headers: stub.headers
          ? { "content-type": "application/json", ...stub.headers }
          : { "content-type": "application/json" },
      };
      return new Response(JSON.stringify({ tag_name: stub.tagName, assets: [] }), init);
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

  test("a source that keeps returning 5xx stays in failures while other sources resolve", async () => {
    const registry: Registry = {
      good: { kind: "githubRelease", source: "owner/good" },
      failed: { kind: "githubRelease", source: "owner/failed" },
    };
    stubFetchBySource({
      "owner/good": { status: 200, tagName: "v1" },
      "owner/failed": { status: 503, headers: { "retry-after": "0" } },
    });

    const { lock, failures } = await resolveAll(undefined, registry);

    expect(Object.keys(lock.releases.tools)).toEqual(["good"]);
    expect(lock.releases.tools["good"]?.version).toBe("v1");
    expect(failures).toHaveLength(1);
    expect(failures[0]).toContain("owner/failed");
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
  test.each(["file", "stdout", "out", "failure"])(
    "--only resolves one registered tool and preserves unselected entries: %s",
    async (mode) => {
      const path = join(await scratch(), "releases.json");
      const prior = {
        releases: {
          tools: {
            codex: { kind: "vendorManifest", source: "https://vendor.invalid", version: "1.2.0" },
            retired: {
              kind: "githubRelease",
              source: "owner/retired",
              version: "v1",
              artifacts: {
                "freebsd-amd64": { url: "https://example.invalid/retired", sha256: "b".repeat(64) },
              },
            },
          },
        },
      };
      const before = JSON.stringify(prior);
      await writeFile(path, before);
      const resolve: typeof resolveAll = async (_token, registry) => {
        expect(Object.keys(registry ?? {})).toEqual(["codex"]);
        return {
          lock: {
            releases: {
              tools:
                mode === "failure"
                  ? {}
                  : {
                      codex: { kind: "githubRelease", source: "openai/codex", version: "1.2.2" },
                    },
            },
          },
          failures: mode === "failure" ? ["unavailable"] : [],
        };
      };
      const stdout = capture();
      const args =
        mode === "stdout"
          ? ["--stdout", "--only", "codex"]
          : mode === "out"
            ? ["--only", "codex", "--out", path]
            : ["--only", "codex"];
      const exit = await runCli(args, { defaultPath: path, stdout, stderr: capture(), resolve });
      expect(exit).toBe(mode === "failure" ? 1 : 0);
      const written = JSON.parse(
        mode === "stdout" ? stdout.values.join("") : await readFile(path, "utf8"),
      );
      expect(written.releases.tools.retired).toEqual(prior.releases.tools.retired);
      expect(written.releases.tools.codex.version).toBe(mode === "failure" ? "1.2.0" : "1.2.2");
      if (mode === "failure")
        expect(written.releases.tools.codex).toEqual(prior.releases.tools.codex);
      if (mode === "stdout") expect(await readFile(path, "utf8")).toBe(before);
    },
  );

  test.each([
    ["--only", "unknown-tool"],
    ["--only"],
    ["--only", ""],
    ["--only", "codex", "--only", "codex"],
    ["--only", "codex", "--stdout", "--out", "lock.json"],
    ["--stdout", "--stdout"],
    ["--out", "first", "--out", "second"],
    ["--only", "toString"],
  ])("invalid selection %j performs no reads, writes, or resolution", async (...args) => {
    const path = join(await scratch(), "releases.json");
    const before = "malformed lock must not be read";
    await writeFile(path, before);
    let resolved = false;
    expect(
      await runCli(args, {
        defaultPath: path,
        stderr: capture(),
        resolve: async () => {
          resolved = true;
          return resolution();
        },
      }),
    ).toBe(2);
    expect(resolved).toBe(false);
    expect(await readFile(path, "utf8")).toBe(before);
  });

  test.each([null, "sha256:nothex"])(
    "CLI resolution records a null checksum for exact release digest %j",
    async (digest) => {
      const path = join(await scratch(), "releases.json");
      globalThis.fetch = (async () =>
        Response.json({
          tag_name: "1.1.28",
          assets: [
            { name: "tool", browser_download_url: "https://example.invalid/1.1.28/tool", digest },
          ],
        })) as typeof fetch;
      const registry: Registry = {
        pinned: {
          kind: "githubRelease",
          source: "owner/pinned",
          exactTag: "1.1.28",
          asset: ({ os, arch }) => (os === "linux" && arch === "amd64" ? "tool" : null),
        },
      };
      expect(
        await runCli([], {
          defaultPath: path,
          stderr: capture(),
          resolve: () => resolveAll(undefined, registry),
        }),
      ).toBe(0);
      const lock = JSON.parse(await readFile(path, "utf8")) as ReleaseLock;
      expect(lock.releases.tools["pinned"]?.artifacts?.["linux-amd64"]?.sha256).toBeNull();
    },
  );

  test.each(["ok", "missing release", "wrong tag", "missing asset"])(
    "exact pin through resolver and CLI: %s",
    async (scenario) => {
      const path = join(await scratch(), "releases.json");
      const prior = {
        kind: "vendorManifest",
        source: "https://vendor.invalid/manifests",
        version: "1.2.2",
        artifacts: {
          "linux-amd64": {
            url: "https://vendor.invalid/1.2.2/tool",
            sha256: null,
            sha512: "b".repeat(128),
          },
        },
      };
      await writeFile(path, JSON.stringify({ releases: { tools: { pinned: prior } } }));
      const registry: Registry = {
        pinned: {
          kind: "githubRelease",
          source: "owner/pinned",
          exactTag: "1.1.28",
          asset: ({ os, arch }) => (os === "linux" && arch === "amd64" ? "tool" : null),
        },
        good: { kind: "githubRelease", source: "owner/good" },
      };
      const urls: string[] = [];
      globalThis.fetch = (async (input) => {
        const url = input instanceof Request ? input.url : String(input);
        urls.push(url);
        if (url.endsWith("/owner/pinned/releases/tags/1.1.28")) {
          if (scenario === "missing release") return new Response("absent", { status: 404 });
          return Response.json({
            tag_name: scenario === "wrong tag" ? "1.2.2" : "1.1.28",
            assets:
              scenario === "missing asset"
                ? []
                : [
                    {
                      name: "tool",
                      browser_download_url: "https://example.invalid/1.1.28/tool",
                      digest: `sha256:${"a".repeat(64)}`,
                    },
                  ],
          });
        }
        return Response.json({
          tag_name: "1.2.2",
          assets: [
            {
              name: "tool",
              browser_download_url: "https://example.invalid/1.2.2/tool",
              digest: `sha256:${"a".repeat(64)}`,
            },
          ],
        });
      }) as typeof fetch;
      const stderr = capture();
      const exit = await runCli([], {
        defaultPath: path,
        stderr,
        resolve: () => resolveAll(undefined, registry),
      });
      const written = JSON.parse(await readFile(path, "utf8")) as ReleaseLock;
      expect(written.releases.tools.good?.version).toBe("1.2.2");
      expect(urls.sort()).toEqual([
        "https://api.github.com/repos/owner/good/releases/latest",
        "https://api.github.com/repos/owner/pinned/releases/tags/1.1.28",
      ]);
      if (scenario === "ok") {
        expect(exit).toBe(0);
        expect(written.releases.tools.pinned?.version).toBe("1.1.28");
        expect(stderr.values).toEqual([]);
      } else {
        expect(exit).toBe(1);
        expect(written.releases.tools.pinned).toEqual(prior);
        expect(stderr.values.join("")).toContain("owner/pinned");
      }
    },
  );

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
      kind: "githubRelease",
      source: "owner/failed",
      version: "1.0.0",
    });
    expect(written.releases.tools["retired"]?.version).toBe("v1");
  });

  test("a source that keeps returning 5xx stays in failures while other sources resolve, and the CLI exit code is 1", async () => {
    const path = join(await scratch(), "releases.json");
    await writeFile(path, `${JSON.stringify(locked("v1"))}\n`);
    const stdout = capture();
    const stderr = capture();
    const registry: Registry = {
      good: { kind: "githubRelease", source: "owner/good" },
      failed: { kind: "githubRelease", source: "owner/failed" },
    };
    stubFetchBySource({
      "owner/good": { status: 200, tagName: "v2" },
      "owner/failed": { status: 503, headers: { "retry-after": "0" } },
    });

    const exit = await runCli([], {
      defaultPath: path,
      stdout,
      stderr,
      resolve: () => resolveAll(undefined, registry),
    });

    expect(exit).toBe(1);
    expect(stderr.values.join("")).toContain("owner/failed");
    const written = JSON.parse(await readFile(path, "utf8")) as ReleaseLock;
    expect(written.releases.tools["good"]?.version).toBe("v2");
    expect(written.releases.tools["failed"]?.version).toBe("1.0.0");
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

  test("covers AE1: a stubbed fetch failure prunes that tool's stale freebsd-amd64 key while its other artifacts and the succeeding tool's fresh data survive", async () => {
    const path = join(await scratch(), "releases.json");
    const flakyArtifacts: Record<string, LockedArtifact> = {
      "linux-amd64": { url: "https://example.com/flaky/linux-amd64", sha256: "a".repeat(64) },
      "darwin-arm64": { url: "https://example.com/flaky/darwin-arm64", sha256: "b".repeat(64) },
      "freebsd-amd64": { url: "https://example.com/flaky/freebsd-amd64", sha256: "c".repeat(64) },
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
