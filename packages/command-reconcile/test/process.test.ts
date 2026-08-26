import { mkdir, rm, symlink, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { describe, expect, it } from "vite-plus/test";
import { scanLinuxRoots } from "../src/process-linux.js";

describe("process roots", () => {
  it("scans mock Linux procfs structure", async () => {
    const mockProc = join(tmpdir(), `mock-proc-${Date.now()}-${Math.random()}`);
    const pid100 = join(mockProc, "100");
    const pidFd = join(pid100, "fd");
    await mkdir(pidFd, { recursive: true });

    const targetBinary = join(mockProc, "sample-bin");
    await writeFile(targetBinary, "binary-content", "utf-8");

    await symlink(targetBinary, join(pid100, "exe"));
    await writeFile(
      join(pid100, "maps"),
      `7f123000-7f124000 r-xp 00000000 08:01 123456   ${targetBinary}\n`,
      "utf-8",
    );
    await symlink(targetBinary, join(pidFd, "0"));

    try {
      const roots = await scanLinuxRoots(mockProc);
      expect(roots.uncertain).toBe(false);
      expect(roots.paths.has(targetBinary)).toBe(true);
    } finally {
      await rm(mockProc, { recursive: true, force: true }).catch(() => {});
    }
  });

  it("handles missing procfs root gracefully with uncertainty", async () => {
    const nonExistent = join(tmpdir(), `non-existent-proc-${Date.now()}`);
    const roots = await scanLinuxRoots(nonExistent);
    expect(roots.uncertain).toBe(true);
  });
});
