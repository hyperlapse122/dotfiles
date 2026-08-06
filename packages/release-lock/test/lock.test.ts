import { mkdtemp, mkdir, readFile, readdir, unlink, writeFile } from "node:fs/promises";
import { join } from "node:path";
import { homedir } from "node:os";
import { describe, expect, test } from "vite-plus/test";
import {
  mergeLocks,
  pruneRetiredPlatforms,
  readLock,
  serializeLock,
  sortTools,
  writeLock,
} from "../src/lock.js";
import type { LockedArtifact, LockedTool, ReleaseLock } from "../src/types.js";

async function scratch(): Promise<string> {
  const base = process.env["XDG_RUNTIME_DIR"] ?? join(homedir(), ".cache");
  const root = join(base, "release-lock-tests");
  await mkdir(root, { recursive: true, mode: 0o700 });
  return mkdtemp(join(root, "case-"));
}

function tool(version: string): LockedTool {
  return { kind: "githubRelease", source: "owner/repo", version };
}

/**
 * A committed tool whose `artifacts` map may carry a key retired from
 * `PlatformKey`'s current vocabulary — the shape a pre-narrowing lock
 * persisted to disk (KTD4 legitimately fixtures this as test input).
 */
function toolWithArtifacts(version: string, artifacts: Record<string, LockedArtifact>): LockedTool {
  return { ...tool(version), artifacts };
}

function lock(tools: Record<string, LockedTool>): ReleaseLock {
  return { releases: { tools } };
}

describe("mergeLocks", () => {
  test("a resolved tool overwrites its committed entry", () => {
    const merged = mergeLocks(lock({ gh: tool("v1") }), lock({ gh: tool("v2") }));
    expect(merged.releases.tools["gh"]?.version).toBe("v2");
  });

  test("a tool missing from the resolution keeps its committed entry", () => {
    const merged = mergeLocks(lock({ gh: tool("v1"), uv: tool("0.1") }), lock({ gh: tool("v2") }));
    expect(merged.releases.tools["uv"]?.version).toBe("0.1");
    expect(merged.releases.tools["gh"]?.version).toBe("v2");
  });

  test("a first run with no committed lock yields the resolution", () => {
    expect(Object.keys(mergeLocks(null, lock({ gh: tool("v1") })).releases.tools)).toEqual(["gh"]);
  });

  test("tools are sorted so an unchanged upstream serializes identically", () => {
    const merged = mergeLocks(lock({ uv: tool("1") }), lock({ ast: tool("1"), gh: tool("1") }));
    expect(Object.keys(merged.releases.tools)).toEqual(["ast", "gh", "uv"]);
  });
});

describe("pruneRetiredPlatforms", () => {
  test("covers AE1: a tool missing from resolution with a stale windows-amd64 key keeps its other artifacts and drops the stale key", () => {
    const existing = lock({
      foo: toolWithArtifacts("v1", {
        "linux-amd64": { url: "https://example.com/foo/linux-amd64", sha256: "a".repeat(64) },
        "darwin-arm64": { url: "https://example.com/foo/darwin-arm64", sha256: "b".repeat(64) },
        "windows-amd64": { url: "https://example.com/foo/windows-amd64", sha256: "c".repeat(64) },
      }),
    });

    const pruned = pruneRetiredPlatforms(mergeLocks(existing, lock({})));

    expect(pruned.releases.tools["foo"]?.artifacts).toEqual({
      "linux-amd64": { url: "https://example.com/foo/linux-amd64", sha256: "a".repeat(64) },
      "darwin-arm64": { url: "https://example.com/foo/darwin-arm64", sha256: "b".repeat(64) },
    });
  });

  test("covers AE2: a tool missing from resolution with no artifacts field prunes to a byte-identical entry", () => {
    const existing = lock({ foo: tool("v1") });

    const pruned = pruneRetiredPlatforms(mergeLocks(existing, lock({})));

    expect(pruned.releases.tools["foo"]).toEqual(tool("v1"));
  });

  test("a tool whose entire artifacts map is retired collapses to the same no-artifacts shape as covers AE2, not artifacts: {}", () => {
    const existing = lock({
      foo: toolWithArtifacts("v1", {
        "windows-amd64": { url: "https://example.com/foo/windows-amd64", sha256: "a".repeat(64) },
      }),
    });

    const pruned = pruneRetiredPlatforms(mergeLocks(existing, lock({})));

    expect(pruned.releases.tools["foo"]).toEqual(tool("v1"));
    expect(Object.keys(pruned.releases.tools["foo"] ?? {})).not.toContain("artifacts");
  });

  test("a stale key carrying emulated: true is dropped identically to a non-emulated stale key", () => {
    const existing = lock({
      foo: toolWithArtifacts("v1", {
        "linux-amd64": { url: "https://example.com/foo/linux-amd64", sha256: "a".repeat(64) },
        "windows-amd64": {
          url: "https://example.com/foo/windows-amd64",
          sha256: "b".repeat(64),
          emulated: true,
        },
      }),
    });

    const pruned = pruneRetiredPlatforms(mergeLocks(existing, lock({})));

    expect(pruned.releases.tools["foo"]?.artifacts).toEqual({
      "linux-amd64": { url: "https://example.com/foo/linux-amd64", sha256: "a".repeat(64) },
    });
  });

  test("a tool present in the resolution is unaffected by pruning beyond the normal overwrite", () => {
    const existing = lock({
      foo: toolWithArtifacts("v1", {
        "windows-amd64": {
          url: "https://example.com/foo/windows-amd64-v1",
          sha256: "a".repeat(64),
        },
      }),
    });
    const resolved = lock({
      foo: toolWithArtifacts("v2", {
        "linux-amd64": { url: "https://example.com/foo/linux-amd64-v2", sha256: "b".repeat(64) },
        "darwin-arm64": { url: "https://example.com/foo/darwin-arm64-v2", sha256: "c".repeat(64) },
      }),
    });

    const pruned = pruneRetiredPlatforms(mergeLocks(existing, resolved));

    expect(pruned.releases.tools["foo"]).toEqual(resolved.releases.tools["foo"]);
  });

  test("pruning an already-pruned lock a second time is idempotent", () => {
    const existing = lock({
      foo: toolWithArtifacts("v1", {
        "linux-amd64": { url: "https://example.com/foo/linux-amd64", sha256: "a".repeat(64) },
        "windows-amd64": { url: "https://example.com/foo/windows-amd64", sha256: "b".repeat(64) },
      }),
    });
    const prunedOnce = pruneRetiredPlatforms(mergeLocks(existing, lock({})));

    const prunedTwice = pruneRetiredPlatforms(prunedOnce);

    expect(prunedTwice).toEqual(prunedOnce);
  });
});

describe("sortTools", () => {
  test("orders keys regardless of insertion order", () => {
    expect(Object.keys(sortTools({ zed: tool("1"), abc: tool("1") }))).toEqual(["abc", "zed"]);
  });
});

describe("serializeLock", () => {
  test("ends with a trailing newline so the file is diff-clean", () => {
    expect(serializeLock(lock({ gh: tool("v1") }))).toMatch(/\n$/);
  });
});

describe("readLock and writeLock", () => {
  test("an absent file reads as null rather than throwing", async () => {
    expect(await readLock(join(await scratch(), "missing.json"))).toBeNull();
  });

  test("a malformed file throws rather than silently resetting the lock", async () => {
    const path = join(await scratch(), "broken.json");
    await writeFile(path, "{ not json", "utf8");
    await expect(readLock(path)).rejects.toThrow();
  });

  test("a written lock round-trips", async () => {
    const path = join(await scratch(), "releases.json");
    await writeLock(path, lock({ gh: tool("v1") }));
    expect((await readLock(path))?.releases.tools["gh"]?.version).toBe("v1");
    expect(await readFile(path, "utf8")).toMatch(/\n$/);
  });

  test("overlaying a failed resolution preserves the prior entry on disk", async () => {
    const path = join(await scratch(), "releases.json");
    await writeLock(path, lock({ gh: tool("v1"), uv: tool("0.1") }));

    const resolvedWithoutUv = lock({ gh: tool("v2") });
    await writeLock(path, mergeLocks(await readLock(path), resolvedWithoutUv));

    const after = await readLock(path);
    expect(after?.releases.tools["gh"]?.version).toBe("v2");
    expect(after?.releases.tools["uv"]?.version).toBe("0.1");
  });

  test("a failed atomic replacement preserves the destination and removes its temporary", async () => {
    const root = await scratch();
    const path = join(root, "releases.json");
    const before = serializeLock(lock({ gh: tool("v1") }));
    await writeFile(path, before, "utf8");

    await expect(
      writeLock(path, lock({ gh: tool("v2") }), {
        writeFile,
        rename: async () => {
          throw new Error("rename failed");
        },
        unlink,
      }),
    ).rejects.toThrow("rename failed");

    expect(await readFile(path, "utf8")).toBe(before);
    expect((await readdir(root)).filter((entry) => entry.includes(".tmp-"))).toEqual([]);
  });
});
