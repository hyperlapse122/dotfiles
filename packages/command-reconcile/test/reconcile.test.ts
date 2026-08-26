import { lstat, mkdir, readFile, readlink, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { describe, expect, it } from "vite-plus/test";
import type { CommandManifest } from "../src/manifest.js";
import { activateUnit, reconcileAll } from "../src/reconcile.js";
import { readState } from "../src/state.js";

describe("reconcile", () => {
  it("activates version A, switches to version B atomically via current symlink", async () => {
    const testHome = join(tmpdir(), `test-rec-${Date.now()}-${Math.random()}`);
    const stagingDir = join(testHome, ".local/share/chezmoi-commands/incomplete/multi-tool");
    await mkdir(stagingDir, { recursive: true });
    await writeFile(join(stagingDir, "tool-one"), "#!/bin/sh\necho v1-1\n", "utf-8");
    await writeFile(join(stagingDir, "tool-two"), "#!/bin/sh\necho v1-2\n", "utf-8");

    const manifestV1: CommandManifest = {
      schemaVersion: "command-manifest/v1",
      units: [
        {
          id: "multi-tool",
          producer: "external",
          safetyProfile: "native-single-file",
          proofEligible: true,
          mutableTree: false,
          privacy: "public",
          mode: "0755",
          commands: [{ name: "tool-one" }, { name: "tool-two" }],
          identity: "v1.0.0",
          stagingPath: ".local/share/chezmoi-commands/incomplete/multi-tool",
        },
      ],
    };

    try {
      const act1 = await activateUnit(testHome, manifestV1, "multi-tool");
      expect(act1.status).toBe("activated");

      const linkOne = join(testHome, ".local/bin/tool-one");
      const linkTwo = join(testHome, ".local/bin/tool-two");
      const currentLink = join(testHome, ".local/lib/commands/current/multi-tool");

      const stOne = await lstat(linkOne);
      const stTwo = await lstat(linkTwo);
      expect(stOne.isSymbolicLink()).toBe(true);
      expect(stTwo.isSymbolicLink()).toBe(true);

      const targetCurrent1 = await readlink(currentLink);
      expect(targetCurrent1).toContain("v1.0.0");

      const contentOneV1 = await readFile(linkOne, "utf-8");
      expect(contentOneV1).toContain("v1-1");

      await writeFile(join(stagingDir, "tool-one"), "#!/bin/sh\necho v2-1\n", "utf-8");
      await writeFile(join(stagingDir, "tool-two"), "#!/bin/sh\necho v2-2\n", "utf-8");

      const manifestV2: CommandManifest = {
        schemaVersion: "command-manifest/v1",
        units: [
          {
            ...manifestV1.units[0]!,
            identity: "v2.0.0",
          },
        ],
      };

      const act2 = await activateUnit(testHome, manifestV2, "multi-tool");
      expect(act2.status).toBe("activated");

      const targetCurrent2 = await readlink(currentLink);
      expect(targetCurrent2).toContain("v2.0.0");

      const contentOneV2 = await readFile(linkOne, "utf-8");
      expect(contentOneV2).toContain("v2-1");
      const contentTwoV2 = await readFile(linkTwo, "utf-8");
      expect(contentTwoV2).toContain("v2-2");

      const act3 = await activateUnit(testHome, manifestV2, "multi-tool");
      expect(act3.status).toBe("unchanged");
    } finally {
      await rm(testHome, { recursive: true, force: true }).catch(() => {});
    }
  });

  it("handles secret commands with opaque private generations", async () => {
    const testHome = join(tmpdir(), `test-rec-secret-${Date.now()}-${Math.random()}`);
    const stagingDir = join(testHome, ".local/share/chezmoi-command-sources");
    await mkdir(stagingDir, { recursive: true });
    const secretFile = join(stagingDir, "import-wifi-1password");
    await writeFile(secretFile, "secret-v1-bytes", "utf-8");

    const manifest: CommandManifest = {
      schemaVersion: "command-manifest/v1",
      units: [
        {
          id: "import-wifi-linux",
          producer: "source",
          safetyProfile: "interpreted",
          proofEligible: false,
          mutableTree: false,
          privacy: "secret",
          mode: "0700",
          commands: [{ name: "import-wifi-1password" }],
          identity: "",
          stagingPath: ".local/share/chezmoi-command-sources/import-wifi-1password",
        },
      ],
    };

    try {
      const act1 = await activateUnit(testHome, manifest, "import-wifi-linux");
      expect(act1.status).toBe("activated");

      const state1 = await readState(testHome);
      const gen1 = state1.units["import-wifi-linux"]?.activeGeneration;
      expect(gen1).toBeDefined();
      expect(gen1?.startsWith("gen-")).toBe(true);

      const act2 = await activateUnit(testHome, manifest, "import-wifi-linux");
      expect(act2.status).toBe("unchanged");
      const state2 = await readState(testHome);
      expect(state2.units["import-wifi-linux"]?.activeGeneration).toBe(gen1);

      await writeFile(secretFile, "secret-v2-bytes-rotated", "utf-8");
      const act3 = await activateUnit(testHome, manifest, "import-wifi-linux");
      expect(act3.status).toBe("activated");
      const state3 = await readState(testHome);
      const gen3 = state3.units["import-wifi-linux"]?.activeGeneration;
      expect(gen3).not.toBe(gen1);
    } finally {
      await rm(testHome, { recursive: true, force: true }).catch(() => {});
    }
  });

  it("does not overwrite foreign regular file without legacy ownership", async () => {
    const testHome = join(tmpdir(), `test-rec-conflict-${Date.now()}-${Math.random()}`);
    const binDir = join(testHome, ".local/bin");
    await mkdir(binDir, { recursive: true });
    await writeFile(join(binDir, "foreign-tool"), "user-installed-binary", "utf-8");

    const stagingDir = join(testHome, ".local/share/chezmoi-commands/incomplete/foreign-tool");
    await mkdir(stagingDir, { recursive: true });
    await writeFile(join(stagingDir, "foreign-tool"), "managed-binary", "utf-8");

    const manifest: CommandManifest = {
      schemaVersion: "command-manifest/v1",
      units: [
        {
          id: "foreign-tool",
          producer: "external",
          safetyProfile: "native-single-file",
          proofEligible: true,
          mutableTree: false,
          privacy: "public",
          mode: "0755",
          commands: [{ name: "foreign-tool" }],
          identity: "v1.0",
          stagingPath: ".local/share/chezmoi-commands/incomplete/foreign-tool",
        },
      ],
    };

    try {
      const act = await activateUnit(testHome, manifest, "foreign-tool");
      expect(act.status).toBe("conflict");

      const content = await readFile(join(binDir, "foreign-tool"), "utf-8");
      expect(content).toBe("user-installed-binary");
    } finally {
      await rm(testHome, { recursive: true, force: true }).catch(() => {});
    }
  });

  it("reconcileAll activates valid units and isolates failures", async () => {
    const testHome = join(tmpdir(), `test-rec-all-${Date.now()}-${Math.random()}`);
    const stagingDir1 = join(testHome, ".local/share/chezmoi-commands/incomplete/good-unit");
    await mkdir(stagingDir1, { recursive: true });
    await writeFile(join(stagingDir1, "good-cmd"), "#!/bin/sh\necho good\n", "utf-8");

    const manifest: CommandManifest = {
      schemaVersion: "command-manifest/v1",
      units: [
        {
          id: "good-unit",
          producer: "external",
          safetyProfile: "native-single-file",
          proofEligible: true,
          mutableTree: false,
          privacy: "public",
          mode: "0755",
          commands: [{ name: "good-cmd" }],
          identity: "v1.0",
          stagingPath: ".local/share/chezmoi-commands/incomplete/good-unit",
        },
        {
          id: "bad-unit",
          producer: "external",
          safetyProfile: "native-single-file",
          proofEligible: true,
          mutableTree: false,
          privacy: "public",
          mode: "0755",
          commands: [{ name: "bad-cmd" }],
          identity: "v1.0",
          stagingPath: ".local/share/chezmoi-commands/incomplete/non-existent-staging",
        },
      ],
    };

    try {
      const report = await reconcileAll(testHome, manifest);
      expect(report.activated).toContain("good-unit");
      expect(report.failed.some((f) => f.id === "bad-unit")).toBe(true);

      const goodLink = join(testHome, ".local/bin/good-cmd");
      const st = await lstat(goodLink);
      expect(st.isSymbolicLink()).toBe(true);
    } finally {
      await rm(testHome, { recursive: true, force: true }).catch(() => {});
    }
  });
});
