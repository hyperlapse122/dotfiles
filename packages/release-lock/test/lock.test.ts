import { mkdtemp, mkdir, readFile, writeFile } from "node:fs/promises";
import { join } from "node:path";
import { homedir } from "node:os";
import { describe, expect, test } from "vite-plus/test";
import { mergeLocks, readLock, serializeLock, sortTools, writeLock } from "../src/lock.js";
import type { LockedTool, ReleaseLock } from "../src/types.js";

async function scratch(): Promise<string> {
  const base = process.env["XDG_RUNTIME_DIR"] ?? join(homedir(), ".cache");
  const root = join(base, "release-lock-tests");
  await mkdir(root, { recursive: true, mode: 0o700 });
  return mkdtemp(join(root, "case-"));
}

function tool(version: string): LockedTool {
  return { kind: "githubRelease", source: "owner/repo", version };
}

function lock(tools: Record<string, LockedTool>): ReleaseLock {
  return { tools };
}

describe("mergeLocks", () => {
  test("a resolved tool overwrites its committed entry", () => {
    const merged = mergeLocks(lock({ gh: tool("v1") }), lock({ gh: tool("v2") }));
    expect(merged.tools["gh"]?.version).toBe("v2");
  });

  test("a tool missing from the resolution keeps its committed entry", () => {
    const merged = mergeLocks(lock({ gh: tool("v1"), uv: tool("0.1") }), lock({ gh: tool("v2") }));
    expect(merged.tools["uv"]?.version).toBe("0.1");
    expect(merged.tools["gh"]?.version).toBe("v2");
  });

  test("a first run with no committed lock yields the resolution", () => {
    expect(Object.keys(mergeLocks(null, lock({ gh: tool("v1") })).tools)).toEqual(["gh"]);
  });

  test("tools are sorted so an unchanged upstream serializes identically", () => {
    const merged = mergeLocks(lock({ uv: tool("1") }), lock({ ast: tool("1"), gh: tool("1") }));
    expect(Object.keys(merged.tools)).toEqual(["ast", "gh", "uv"]);
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
    expect((await readLock(path))?.tools["gh"]?.version).toBe("v1");
    expect(await readFile(path, "utf8")).toMatch(/\n$/);
  });

  test("overlaying a failed resolution preserves the prior entry on disk", async () => {
    const path = join(await scratch(), "releases.json");
    await writeLock(path, lock({ gh: tool("v1"), uv: tool("0.1") }));

    const resolvedWithoutUv = lock({ gh: tool("v2") });
    await writeLock(path, mergeLocks(await readLock(path), resolvedWithoutUv));

    const after = await readLock(path);
    expect(after?.tools["gh"]?.version).toBe("v2");
    expect(after?.tools["uv"]?.version).toBe("0.1");
  });
});
