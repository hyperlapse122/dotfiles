import { describe, expect, it, vi } from "vite-plus/test";
import { parseTarget, runCli, USAGE } from "../src/cli.js";

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
    [[]],
    [["unknown"]],
    [["omp", "extra"]],
    [["opencode"]],
    [["pi"]],
    [["antigravity"]],
    [["kimi"]],
  ])("rejects invalid arguments before running OAuth: %j", async (args: string[]) => {
    const stderr = sink();
    const run = vi.fn();
    expect(await runCli(args, { stderr, run })).toBe(2);
    expect(stderr.output).toBe(USAGE);
    expect(stderr.output).toContain("omp");
    expect(stderr.output).not.toContain("opencode");
    expect(stderr.output).not.toContain("pi");
    expect(stderr.output).not.toContain("antigravity");
    expect(stderr.output).not.toContain("kimi");
    expect(run).not.toHaveBeenCalled();
  });

  it("accepts only the omp target", async () => {
    const stdout = sink();
    const run = vi.fn(async () => undefined);
    expect(parseTarget(["omp"])).toBe("omp");
    expect(await runCli(["omp"], { stdout, run })).toBe(0);
    expect(run).toHaveBeenCalledOnce();
    expect(run).toHaveBeenCalledWith("omp", expect.any(AbortSignal));
  });

  it("reports failures without claiming credentials were saved", async () => {
    const stdout = sink();
    const stderr = sink();
    const run = vi.fn(async () => {
      throw new Error("cancelled");
    });
    expect(await runCli(["omp"], { stdout, stderr, run })).toBe(1);
    expect(stdout.output).toBe("");
    expect(stderr.output).toContain("cancelled");
  });
});
