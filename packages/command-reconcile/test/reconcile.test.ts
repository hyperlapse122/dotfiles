import { lstat, mkdir, readFile, readlink, rm, symlink, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { describe, expect, it } from "vite-plus/test";
import type { CommandManifest, UnitManifest } from "../src/manifest.js";
import { resolveCommandPaths } from "../src/paths.js";
import {
  ensureCompletedUnit,
  isUnitCompleted,
  writeCompletionMarker,
} from "../src/producer.js";
import { activateUnit, reconcileAll } from "../src/reconcile.js";
import { readState, type CommandState } from "../src/state.js";

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

  it("publishes resolvable links for every declared name of a single-file external unit", async () => {
    const testHome = join(tmpdir(), `test-rec-agy-${Date.now()}-${Math.random()}`);
    const stagingDir = join(testHome, ".local/share/chezmoi-commands/incomplete/agy");
    await mkdir(stagingDir, { recursive: true });
    await writeFile(join(stagingDir, "agy"), "#!/bin/sh\necho agy-binary\n", "utf-8");

    const manifest: CommandManifest = {
      schemaVersion: "command-manifest/v1",
      units: [
        {
          id: "agy",
          producer: "external",
          safetyProfile: "native-single-file",
          proofEligible: true,
          mutableTree: false,
          privacy: "public",
          mode: "0755",
          commands: [{ name: "agy" }, { name: "antigravity", relPath: "agy" }],
          identity: "v1.0.0",
          stagingPath: ".local/share/chezmoi-commands/incomplete/agy",
        },
      ],
    };

    try {
      const act = await activateUnit(testHome, manifest, "agy");
      expect(act.status).toBe("activated");

      for (const name of ["agy", "antigravity"]) {
        const link = join(testHome, ".local/bin", name);
        expect((await lstat(link)).isSymbolicLink()).toBe(true);
        expect(await readFile(link, "utf-8")).toContain("agy-binary");
      }
    } finally {
      await rm(testHome, { recursive: true, force: true }).catch(() => {});
    }
  });

  it("fails loudly instead of publishing a dangling link for an unbacked command name", async () => {
    const testHome = join(tmpdir(), `test-rec-dangling-${Date.now()}-${Math.random()}`);
    const stagingDir = join(testHome, ".local/share/chezmoi-commands/incomplete/agy");
    await mkdir(stagingDir, { recursive: true });
    await writeFile(join(stagingDir, "agy"), "#!/bin/sh\necho agy-binary\n", "utf-8");

    const manifest: CommandManifest = {
      schemaVersion: "command-manifest/v1",
      units: [
        {
          id: "agy",
          producer: "external",
          safetyProfile: "native-single-file",
          proofEligible: true,
          mutableTree: false,
          privacy: "public",
          mode: "0755",
          commands: [{ name: "agy" }, { name: "antigravity" }],
          identity: "v1.0.0",
          stagingPath: ".local/share/chezmoi-commands/incomplete/agy",
        },
      ],
    };

    try {
      const report = await reconcileAll(testHome, manifest);
      expect(report.failed.some((f) => f.id === "agy" && f.error.includes("antigravity"))).toBe(
        true,
      );
      expect(report.activated).not.toContain("agy");

      await expect(lstat(join(testHome, ".local/bin/antigravity"))).rejects.toThrow();
      await expect(lstat(join(testHome, ".local/bin/agy"))).rejects.toThrow();
    } finally {
      await rm(testHome, { recursive: true, force: true }).catch(() => {});
    }
  });

  it("reconciles a mutableTree unit whose tree is absent", async () => {
    const testHome = join(tmpdir(), `test-rec-mutable-${Date.now()}-${Math.random()}`);

    const manifest: CommandManifest = {
      schemaVersion: "command-manifest/v1",
      units: [
        {
          id: "flutter",
          producer: "existingTree",
          safetyProfile: "mutable-tree",
          proofEligible: false,
          mutableTree: true,
          privacy: "public",
          mode: "0755",
          commands: [
            { name: "flutter", relPath: "bin/flutter" },
            { name: "dart", relPath: "bin/dart" },
          ],
          identity: "stable",
          stagingPath: ".local/share/flutter/versions",
        },
      ],
    };

    try {
      const report = await reconcileAll(testHome, manifest);
      expect(report.failed).toEqual([]);
      expect(report.activated).toContain("flutter");
    } finally {
      await rm(testHome, { recursive: true, force: true }).catch(() => {});
    }
  });

  it("fails loudly for a mutableTree unit whose present tree lacks a declared relPath", async () => {
    const testHome = join(tmpdir(), `test-rec-mutable-partial-${Date.now()}-${Math.random()}`);
    const treeDir = join(testHome, ".local/share/flutter/versions");
    await mkdir(join(treeDir, "bin"), { recursive: true });
    await writeFile(join(treeDir, "bin/flutter"), "#!/bin/sh\necho flutter\n", "utf-8");

    const manifest: CommandManifest = {
      schemaVersion: "command-manifest/v1",
      units: [
        {
          id: "flutter",
          producer: "existingTree",
          safetyProfile: "mutable-tree",
          proofEligible: false,
          mutableTree: true,
          privacy: "public",
          mode: "0755",
          commands: [
            { name: "flutter", relPath: "bin/flutter" },
            { name: "dart", relPath: "bin/dart" },
          ],
          identity: "stable",
          stagingPath: ".local/share/flutter/versions",
        },
      ],
    };

    try {
      const report = await reconcileAll(testHome, manifest);
      expect(report.failed.some((f) => f.id === "flutter" && f.error.includes("dart"))).toBe(true);
      expect(report.activated).not.toContain("flutter");

      await expect(lstat(join(testHome, ".local/bin/dart"))).rejects.toThrow();
      await expect(lstat(join(testHome, ".local/bin/flutter"))).rejects.toThrow();
    } finally {
      await rm(testHome, { recursive: true, force: true }).catch(() => {});
    }
  });

  it("rejects a command whose relPath escapes the unit backing directory", async () => {
    const testHome = join(tmpdir(), `test-rec-escape-${Date.now()}-${Math.random()}`);
    const treeDir = join(testHome, ".local/share/escape-tree");
    const outsideDir = join(testHome, "outside");
    await mkdir(join(treeDir, "bin"), { recursive: true });
    await mkdir(outsideDir, { recursive: true });
    await writeFile(join(outsideDir, "payload"), "#!/bin/sh\necho outside\n", "utf-8");
    await symlink(join(outsideDir, "payload"), join(treeDir, "bin/escapee"));

    const manifest: CommandManifest = {
      schemaVersion: "command-manifest/v1",
      units: [
        {
          id: "escape-unit",
          producer: "existingTree",
          safetyProfile: "mutable-tree",
          proofEligible: false,
          mutableTree: true,
          privacy: "public",
          mode: "0755",
          commands: [{ name: "escapee", relPath: "bin/escapee" }],
          identity: "stable",
          stagingPath: ".local/share/escape-tree",
        },
      ],
    };

    try {
      const report = await reconcileAll(testHome, manifest);
      expect(
        report.failed.some((f) => f.id === "escape-unit" && f.error.includes("outside its store")),
      ).toBe(true);
      await expect(lstat(join(testHome, ".local/bin/escapee"))).rejects.toThrow();
    } finally {
      await rm(testHome, { recursive: true, force: true }).catch(() => {});
    }
  });

  it("rejects a command whose relPath resolves to a directory", async () => {
    const testHome = join(tmpdir(), `test-rec-dir-${Date.now()}-${Math.random()}`);
    const treeDir = join(testHome, ".local/share/dir-tree");
    await mkdir(join(treeDir, "bin/notafile"), { recursive: true });

    const manifest: CommandManifest = {
      schemaVersion: "command-manifest/v1",
      units: [
        {
          id: "dir-unit",
          producer: "existingTree",
          safetyProfile: "mutable-tree",
          proofEligible: false,
          mutableTree: true,
          privacy: "public",
          mode: "0755",
          commands: [{ name: "notafile", relPath: "bin/notafile" }],
          identity: "stable",
          stagingPath: ".local/share/dir-tree",
        },
      ],
    };

    try {
      const report = await reconcileAll(testHome, manifest);
      expect(
        report.failed.some((f) => f.id === "dir-unit" && f.error.includes("not a regular file")),
      ).toBe(true);
      await expect(lstat(join(testHome, ".local/bin/notafile"))).rejects.toThrow();
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

describe("ensureCompletedUnit repair", () => {
  const externalUnit = (stagingPath: string): UnitManifest => ({
    id: "codex",
    producer: "external",
    safetyProfile: "native-multi-file",
    proofEligible: true,
    mutableTree: false,
    privacy: "public",
    mode: "0755",
    commands: [{ name: "codex-bin", relPath: "codex" }],
    identity: "rust-v1.2.3",
    stagingPath,
  });

  const emptyState: CommandState = {
    schemaVersion: "command-reconcile/v1",
    revision: 1,
    updatedAt: new Date().toISOString(),
    units: {},
  };

  it("copies staged entries the completed generation lacks, without rewriting the ones it has", async () => {
    const testHome = join(tmpdir(), `test-repair-${Date.now()}-${Math.random()}`);
    const paths = resolveCommandPaths(testHome);
    const stagingRel = ".local/share/chezmoi-commands/incomplete/codex";
    const stagingDir = join(testHome, stagingRel);
    const storeDir = join(paths.storeDir, "codex", "rust-v1.2.3");

    await mkdir(stagingDir, { recursive: true });
    await writeFile(join(stagingDir, "codex"), "staged-codex", { encoding: "utf-8", mode: 0o755 });
    await writeFile(join(stagingDir, "codex-code-mode-host"), "staged-host", {
      encoding: "utf-8",
      mode: 0o755,
    });

    await mkdir(storeDir, { recursive: true });
    await writeFile(join(storeDir, "codex"), "installed-codex", {
      encoding: "utf-8",
      mode: 0o755,
    });
    await writeCompletionMarker(storeDir, 0o755);

    try {
      const result = await ensureCompletedUnit(paths, externalUnit(stagingRel), emptyState);

      expect(result.changed).toBe(true);
      expect(await readFile(join(storeDir, "codex-code-mode-host"), "utf-8")).toBe("staged-host");
      // The running entrypoint is never rewritten -- copying over a live binary fails ETXTBSY.
      expect(await readFile(join(storeDir, "codex"), "utf-8")).toBe("installed-codex");
      expect(await isUnitCompleted(storeDir)).toBe(true);
    } finally {
      await rm(testHome, { recursive: true, force: true }).catch(() => {});
    }
  });

  it("keeps the executable bit on a repaired entry", async () => {
    const testHome = join(tmpdir(), `test-repair-mode-${Date.now()}-${Math.random()}`);
    const paths = resolveCommandPaths(testHome);
    const stagingRel = ".local/share/chezmoi-commands/incomplete/codex";
    const stagingDir = join(testHome, stagingRel);
    const storeDir = join(paths.storeDir, "codex", "rust-v1.2.3");

    await mkdir(stagingDir, { recursive: true });
    await writeFile(join(stagingDir, "codex"), "staged-codex", { encoding: "utf-8", mode: 0o755 });
    await writeFile(join(stagingDir, "codex-code-mode-host"), "staged-host", {
      encoding: "utf-8",
      mode: 0o755,
    });

    await mkdir(storeDir, { recursive: true });
    await writeFile(join(storeDir, "codex"), "installed-codex", {
      encoding: "utf-8",
      mode: 0o755,
    });
    await writeCompletionMarker(storeDir, 0o755);

    try {
      await ensureCompletedUnit(paths, externalUnit(stagingRel), emptyState);
      const st = await lstat(join(storeDir, "codex-code-mode-host"));
      expect(st.mode & 0o111).not.toBe(0);
    } finally {
      await rm(testHome, { recursive: true, force: true }).catch(() => {});
    }
  });

  it("leaves a completed generation alone when it already holds every staged entry", async () => {
    const testHome = join(tmpdir(), `test-repair-noop-${Date.now()}-${Math.random()}`);
    const paths = resolveCommandPaths(testHome);
    const stagingRel = ".local/share/chezmoi-commands/incomplete/codex";
    const stagingDir = join(testHome, stagingRel);
    const storeDir = join(paths.storeDir, "codex", "rust-v1.2.3");

    await mkdir(stagingDir, { recursive: true });
    await writeFile(join(stagingDir, "codex"), "staged-codex", { encoding: "utf-8", mode: 0o755 });

    await mkdir(storeDir, { recursive: true });
    await writeFile(join(storeDir, "codex"), "installed-codex", {
      encoding: "utf-8",
      mode: 0o755,
    });
    await writeCompletionMarker(storeDir, 0o755);

    try {
      const result = await ensureCompletedUnit(paths, externalUnit(stagingRel), emptyState);
      expect(result.changed).toBe(false);
      expect(await readFile(join(storeDir, "codex"), "utf-8")).toBe("installed-codex");
    } finally {
      await rm(testHome, { recursive: true, force: true }).catch(() => {});
    }
  });

  it("accepts a completed generation whose staging path is gone", async () => {
    const testHome = join(tmpdir(), `test-repair-nostage-${Date.now()}-${Math.random()}`);
    const paths = resolveCommandPaths(testHome);
    const storeDir = join(paths.storeDir, "codex", "rust-v1.2.3");

    await mkdir(storeDir, { recursive: true });
    await writeFile(join(storeDir, "codex"), "installed-codex", {
      encoding: "utf-8",
      mode: 0o755,
    });
    await writeCompletionMarker(storeDir, 0o755);

    try {
      const result = await ensureCompletedUnit(
        paths,
        externalUnit(".local/share/chezmoi-commands/incomplete/codex"),
        emptyState,
      );
      expect(result.changed).toBe(false);
      expect(result.identity).toBe("rust-v1.2.3");
    } finally {
      await rm(testHome, { recursive: true, force: true }).catch(() => {});
    }
  });

  it("still copies a file staging path per declared command", async () => {
    const testHome = join(tmpdir(), `test-repair-file-${Date.now()}-${Math.random()}`);
    const paths = resolveCommandPaths(testHome);
    const stagingRel = ".local/share/chezmoi-command-sources/codex";
    const stagingFile = join(testHome, stagingRel);

    await mkdir(join(testHome, ".local/share/chezmoi-command-sources"), { recursive: true });
    await writeFile(stagingFile, "#!/bin/sh\n", { encoding: "utf-8", mode: 0o755 });

    const unit: UnitManifest = {
      ...externalUnit(stagingRel),
      id: "codex-wrapper",
      producer: "source",
      safetyProfile: "interpreted",
      proofEligible: false,
      commands: [{ name: "codex", relPath: "codex-wrapper" }],
      identity: "sha-abc",
    };

    try {
      const result = await ensureCompletedUnit(paths, unit, emptyState);
      expect(result.changed).toBe(true);
      const installed = join(paths.storeDir, "codex-wrapper", "sha-abc", "codex-wrapper");
      expect(await readFile(installed, "utf-8")).toBe("#!/bin/sh\n");
    } finally {
      await rm(testHome, { recursive: true, force: true }).catch(() => {});
    }
  });
});
