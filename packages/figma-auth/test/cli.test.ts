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
  it.each([[[]], [["unknown"]], [["opencode", "pi"]]])(
    "rejects invalid arguments before running OAuth: %j",
    async (args: string[]) => {
      const stderr = sink();
      const run = vi.fn();
      expect(await runCli(args, { stderr, run })).toBe(2);
      expect(stderr.output).toBe(USAGE);
      expect(stderr.output).toContain("opencode");
      expect(stderr.output).toContain("pi");
      expect(run).not.toHaveBeenCalled();
    },
  );

  it.each(["opencode", "pi"] as const)("accepts only the %s target", async (target) => {
    const stdout = sink();
    const run = vi.fn(async () => undefined);
    expect(parseTarget([target])).toBe(target);
    expect(await runCli([target], { stdout, run })).toBe(0);
    expect(run).toHaveBeenCalledOnce();
    expect(run).toHaveBeenCalledWith(target, expect.any(AbortSignal));
  });

  it("reports failures without claiming credentials were saved", async () => {
    const stdout = sink();
    const stderr = sink();
    const run = vi.fn(async () => {
      throw new Error("cancelled");
    });
    expect(await runCli(["pi"], { stdout, stderr, run })).toBe(1);
    expect(stdout.output).toBe("");
    expect(stderr.output).toContain("cancelled");
  });
});
