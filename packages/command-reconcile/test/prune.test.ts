import { lstat, mkdir, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { describe, expect, it } from "vite-plus/test";
import type { CommandManifest } from "../src/manifest.js";
import { resolveCommandPaths } from "../src/paths.js";
import type { ProcessRoots } from "../src/process-linux.js";
import { pruneEligibleUnits } from "../src/prune.js";
import type { CommandState } from "../src/state.js";

describe("prune", () => {
  it("prunes unused older version of proof-eligible native unit", async () => {
    const testHome = join(tmpdir(), `test-prune-${Date.now()}-${Math.random()}`);
    const paths = resolveCommandPaths(testHome);

    const storeV1 = join(paths.storeDir, "agent-browser", "v1.0");
    const storeV2 = join(paths.storeDir, "agent-browser", "v2.0");
    await mkdir(storeV1, { recursive: true });
    await mkdir(storeV2, { recursive: true });
    await writeFile(join(storeV1, "agent-browser"), "bin-v1", "utf-8");
    await writeFile(join(storeV2, "agent-browser"), "bin-v2", "utf-8");

    const manifest: CommandManifest = {
      schemaVersion: "command-manifest/v1",
      units: [
        {
          id: "agent-browser",
          producer: "external",
          safetyProfile: "native-single-file",
          proofEligible: true,
          mutableTree: false,
          privacy: "public",
          mode: "0755",
          commands: [{ name: "agent-browser" }],
          identity: "v2.0",
          stagingPath: "path",
        },
      ],
    };

    const state: CommandState = {
      schemaVersion: "command-reconcile/v1",
      revision: 1,
      updatedAt: new Date().toISOString(),
      units: {
        "agent-browser": { activeIdentity: "v2.0" },
      },
    };

    const mockScanner = async (): Promise<ProcessRoots> => ({
      paths: new Set(),
      inodes: new Set(),
      uncertain: false,
    });

    try {
      const result = await pruneEligibleUnits(paths, manifest, state, mockScanner);
      expect(result.pruned).toContain("agent-browser/v1.0");
      expect(result.retained.length).toBe(0);

      await expect(lstat(storeV1)).rejects.toThrow();
      const st2 = await lstat(storeV2);
      expect(st2.isDirectory()).toBe(true);
    } finally {
      await rm(testHome, { recursive: true, force: true }).catch(() => {});
    }
  });

  it("retains older version when active process uses it", async () => {
    const testHome = join(tmpdir(), `test-prune-live-${Date.now()}-${Math.random()}`);
    const paths = resolveCommandPaths(testHome);

    const storeV1 = join(paths.storeDir, "agent-browser", "v1.0");
    const storeV2 = join(paths.storeDir, "agent-browser", "v2.0");
    await mkdir(storeV1, { recursive: true });
    await mkdir(storeV2, { recursive: true });
    const binV1 = join(storeV1, "agent-browser");
    await writeFile(binV1, "bin-v1", "utf-8");
    await writeFile(join(storeV2, "agent-browser"), "bin-v2", "utf-8");

    const manifest: CommandManifest = {
      schemaVersion: "command-manifest/v1",
      units: [
        {
          id: "agent-browser",
          producer: "external",
          safetyProfile: "native-single-file",
          proofEligible: true,
          mutableTree: false,
          privacy: "public",
          mode: "0755",
          commands: [{ name: "agent-browser" }],
          identity: "v2.0",
          stagingPath: "path",
        },
      ],
    };

    const state: CommandState = {
      schemaVersion: "command-reconcile/v1",
      revision: 1,
      updatedAt: new Date().toISOString(),
      units: {
        "agent-browser": { activeIdentity: "v2.0" },
      },
    };

    const mockScanner = async (): Promise<ProcessRoots> => ({
      paths: new Set([binV1]),
      inodes: new Set(),
      uncertain: false,
    });

    try {
      const result = await pruneEligibleUnits(paths, manifest, state, mockScanner);
      expect(result.retained).toContain("agent-browser/v1.0");
      expect(result.pruned.length).toBe(0);

      const st1 = await lstat(storeV1);
      expect(st1.isDirectory()).toBe(true);
    } finally {
      await rm(testHome, { recursive: true, force: true }).catch(() => {});
    }
  });

  it("retains interpreted and mutable tree units unconditionally", async () => {
    const testHome = join(tmpdir(), `test-prune-interp-${Date.now()}-${Math.random()}`);
    const paths = resolveCommandPaths(testHome);

    const storeV1 = join(paths.storeDir, "code", "v1.0");
    const storeV2 = join(paths.storeDir, "code", "v2.0");
    await mkdir(storeV1, { recursive: true });
    await mkdir(storeV2, { recursive: true });
    await writeFile(join(storeV1, "code"), "script-v1", "utf-8");
    await writeFile(join(storeV2, "code"), "script-v2", "utf-8");

    const manifest: CommandManifest = {
      schemaVersion: "command-manifest/v1",
      units: [
        {
          id: "code",
          producer: "source",
          safetyProfile: "interpreted",
          proofEligible: false,
          mutableTree: false,
          privacy: "public",
          mode: "0755",
          commands: [{ name: "code" }],
          identity: "v2.0",
          stagingPath: "path",
        },
      ],
    };

    const state: CommandState = {
      schemaVersion: "command-reconcile/v1",
      revision: 1,
      updatedAt: new Date().toISOString(),
      units: {
        code: { activeIdentity: "v2.0" },
      },
    };

    const mockScanner = async (): Promise<ProcessRoots> => ({
      paths: new Set(),
      inodes: new Set(),
      uncertain: false,
    });

    try {
      const result = await pruneEligibleUnits(paths, manifest, state, mockScanner);
      expect(result.retained).toContain("code/v1.0");
      expect(result.pruned.length).toBe(0);
      const st1 = await lstat(storeV1);
      expect(st1.isDirectory()).toBe(true);
    } finally {
      await rm(testHome, { recursive: true, force: true }).catch(() => {});
    }
  });
});
