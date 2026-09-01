import { describe, expect, it, vi } from "vite-plus/test";
import { runCli, USAGE } from "../src/cli.js";

function sink(): { output: string; write(value: string): boolean } {
  return {
    output: "",
    write(value: string) {
      this.output += value;
      return true;
    },
  };
}

describe("CLI parsing", () => {
  it.each([
    [["omp"]],
    [["unknown"]],
    [["--help"]],
    [["omp", "extra"]],
    [["pi"]],
    [["antigravity"]],
    [["kimi"]],
  ])("rejects invalid arguments before running OAuth: %j", async (args: string[]) => {
    const stderr = sink();
    const run = vi.fn();
    expect(await runCli(args, { stderr, run })).toBe(2);
    expect(stderr.output).toBe(USAGE);
    expect(stderr.output).toBe("Usage: figma-auth\n");
    expect(run).not.toHaveBeenCalled();
  });

  it("executes OAuth flow with zero arguments", async () => {
    const stdout = sink();
    const run = vi.fn(async () => undefined);
    expect(await runCli([], { stdout, run })).toBe(0);
    expect(run).toHaveBeenCalledOnce();
    expect(run).toHaveBeenCalledWith(expect.any(AbortSignal));
    expect(stdout.output).toBe("Figma MCP credentials saved.\n");
  });

  it("reports failures without claiming credentials were saved", async () => {
    const stdout = sink();
    const stderr = sink();
    const run = vi.fn(async () => {
      throw new Error("cancelled");
    });
    expect(await runCli([], { stdout, stderr, run })).toBe(1);
    expect(stdout.output).toBe("");
    expect(stderr.output).toContain("cancelled");
  });
});
