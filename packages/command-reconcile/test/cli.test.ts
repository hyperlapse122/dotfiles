import { afterEach, beforeEach, describe, expect, it } from "vite-plus/test";
import { mkdir, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { main } from "../src/cli.js";

describe("command-reconcile cli", () => {
  let testHome: string;
  let testManifestPath: string;
  let stdoutData: string[] = [];
  let stderrData: string[] = [];
  let originalStdoutWrite: typeof process.stdout.write;
  let originalStderrWrite: typeof process.stderr.write;

  beforeEach(async () => {
    testHome = join(tmpdir(), `test-cli-${Date.now()}-${Math.random().toString(36).slice(2)}`);
    await mkdir(join(testHome, ".local/bin"), { recursive: true });
    await mkdir(join(testHome, ".local/share/chezmoi-commands/incomplete/omp"), {
      recursive: true,
    });
    await writeFile(
      join(testHome, ".local/share/chezmoi-commands/incomplete/omp/omp"),
      "#!/usr/bin/env bash\necho omp\n",
      { mode: 0o755 },
    );

    testManifestPath = join(testHome, "manifest.json");
    await writeFile(
      testManifestPath,
      JSON.stringify(
        {
          schemaVersion: "command-manifest/v1",
          units: [
            {
              id: "omp",
              producer: "external",
              safetyProfile: "native-single-file",
              proofEligible: true,
              mutableTree: false,
              privacy: "public",
              mode: "0755",
              commands: [{ name: "omp" }],
              identity: "v1.0.0",
              stagingPath: ".local/share/chezmoi-commands/incomplete/omp",
            },
          ],
        },
        null,
        2,
      ),
      "utf-8",
    );

    stdoutData = [];
    stderrData = [];
    originalStdoutWrite = process.stdout.write.bind(process.stdout);
    originalStderrWrite = process.stderr.write.bind(process.stderr);

    process.stdout.write = ((chunk: string | Uint8Array) => {
      stdoutData.push(typeof chunk === "string" ? chunk : new TextDecoder().decode(chunk));
      return true;
    }) as typeof process.stdout.write;

    process.stderr.write = ((chunk: string | Uint8Array) => {
      stderrData.push(typeof chunk === "string" ? chunk : new TextDecoder().decode(chunk));
      return true;
    }) as typeof process.stderr.write;
  });

  afterEach(async () => {
    process.stdout.write = originalStdoutWrite;
    process.stderr.write = originalStderrWrite;
    await rm(testHome, { recursive: true, force: true });
  });

  it("prints usage on --help or -h", async () => {
    const code = await main(["bun", "cli.ts", "--help"]);
    expect(code).toBe(1);
    expect(stderrData.join("")).toContain("Usage:");
    expect(stderrData.join("")).toContain("--json");
  });

  it("fails when --manifest is missing", async () => {
    const code = await main(["bun", "cli.ts", "reconcile-all"]);
    expect(code).toBe(1);
    expect(stderrData.join("")).toContain("Error: --manifest is required");
  });

  it("fails when --unit is missing for activate-unit", async () => {
    const code = await main(["bun", "cli.ts", "activate-unit", "--manifest", testManifestPath]);
    expect(code).toBe(1);
    expect(stderrData.join("")).toContain("Error: --unit is required for activate-unit");
  });

  it("activate-unit is silent by default on success", async () => {
    const code = await main([
      "bun",
      "cli.ts",
      "activate-unit",
      "--manifest",
      testManifestPath,
      "--unit",
      "omp",
      "--home",
      testHome,
    ]);
    expect(code).toBe(0);
    expect(stdoutData.join("")).toBe("");
    expect(stderrData.join("")).toBe("");
  });

  it("activate-unit outputs JSON with --json", async () => {
    const code = await main([
      "bun",
      "cli.ts",
      "activate-unit",
      "--manifest",
      testManifestPath,
      "--unit",
      "omp",
      "--home",
      testHome,
      "--json",
    ]);
    expect(code).toBe(0);
    const parsed = JSON.parse(stdoutData.join(""));
    expect(parsed.unitId).toBe("omp");
    expect(parsed.status).toBe("activated");
  });

  it("reconcile-all outputs concise message on activation and is silent when unchanged", async () => {
    const code1 = await main([
      "bun",
      "cli.ts",
      "reconcile-all",
      "--manifest",
      testManifestPath,
      "--home",
      testHome,
    ]);
    expect(code1).toBe(0);
    expect(stdoutData.join("")).toBe("command-reconcile: activated omp\n");
    expect(stderrData.join("")).toBe("");

    stdoutData = [];
    stderrData = [];

    const code2 = await main([
      "bun",
      "cli.ts",
      "reconcile-all",
      "--manifest",
      testManifestPath,
      "--home",
      testHome,
    ]);
    expect(code2).toBe(0);
    expect(stdoutData.join("")).toBe("");
    expect(stderrData.join("")).toBe("");
  });

  it("reconcile-all outputs JSON report with --json", async () => {
    const code = await main([
      "bun",
      "cli.ts",
      "reconcile-all",
      "--manifest",
      testManifestPath,
      "--home",
      testHome,
      "--json",
    ]);
    expect(code).toBe(0);
    const parsed = JSON.parse(stdoutData.join(""));
    expect(parsed.activated).toEqual(["omp"]);
    expect(parsed.failed).toEqual([]);
  });

  it("reconcile-all reports conflicts to stderr", async () => {
    await writeFile(join(testHome, ".local/bin/omp"), "foreign-binary", { mode: 0o755 });

    const code = await main([
      "bun",
      "cli.ts",
      "reconcile-all",
      "--manifest",
      testManifestPath,
      "--home",
      testHome,
    ]);
    expect(code).toBe(0);
    expect(stderrData.join("")).toContain("command-reconcile: conflict for omp");
  });
});
