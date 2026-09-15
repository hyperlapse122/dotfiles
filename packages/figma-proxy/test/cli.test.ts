import { describe, expect, it } from "vite-plus/test";
import { runCli, USAGE } from "../src/cli.js";

describe("CLI Interface", () => {
  it("prints usage and exits 0 on --help", async () => {
    let output = "";
    const stdout = {
      write: (v: string) => {
        output += v;
      },
    };
    const code = await runCli(["--help"], { stdout });
    expect(code).toBe(0);
    expect(output).toContain("Usage: figma-proxy <command>");
  });

  it("prints usage and exits 2 when called with no arguments", async () => {
    let output = "";
    const stdout = {
      write: (v: string) => {
        output += v;
      },
    };
    const code = await runCli([], { stdout });
    expect(code).toBe(2);
    expect(output).toBe(USAGE);
  });

  it("prints error and exits 2 on unknown command", async () => {
    let errorOutput = "";
    const stderr = {
      write: (v: string) => {
        errorOutput += v;
      },
    };
    const code = await runCli(["invalid-command"], { stderr });
    expect(code).toBe(2);
    expect(errorOutput).toContain("Unknown command: invalid-command");
  });
});
