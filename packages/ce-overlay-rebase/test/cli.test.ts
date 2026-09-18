import { mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { describe, expect, test } from "vite-plus/test";
import { runCli } from "../src/cli.js";
import { FAILURE_CLASSES } from "../src/marker.js";

async function scratch(): Promise<string> {
  return await mkdtemp(join(tmpdir(), "ce-rebase-test-"));
}

describe("CLI", () => {
  test("validate-marker passes on valid marker file", async () => {
    const dir = await scratch();
    try {
      const file = join(dir, "marker.json");
      await writeFile(
        file,
        JSON.stringify({
          ceOverlayRebase: {
            target: "compound-engineering-v3.26.3",
            status: "idle",
            attempts: 0,
            firstAttempt: null,
            lastAttempt: null,
            notBefore: null,
            failureClass: null,
            missing: [],
            issue: null,
          },
        }),
      );

      let stdout = "";
      const code = await runCli(["validate-marker", file], {
        stdout: (msg: string) => (stdout += msg),
      });
      expect(code).toBe(0);
      const parsed = JSON.parse(stdout);
      expect(parsed.valid).toBe(true);
    } finally {
      await rm(dir, { recursive: true, force: true });
    }
  });

  test("validate-marker fails on invalid marker file", async () => {
    const dir = await scratch();
    try {
      const file = join(dir, "marker.json");
      await writeFile(
        file,
        JSON.stringify({
          ceOverlayRebase: {
            target: "invalid-target",
            status: "idle",
          },
        }),
      );

      let stderr = "";
      const code = await runCli(["validate-marker", file], {
        stderr: (msg: string) => (stderr += msg),
      });
      expect(code).toBe(1);
      expect(stderr).toMatch(/validation failed/i);
    } finally {
      await rm(dir, { recursive: true, force: true });
    }
  });

  test("write-marker refuses marker that fails schema", async () => {
    const dir = await scratch();
    try {
      const outPath = join(dir, "written.json");
      const badMarker = {
        target: "bad-version",
        status: "invalid-status",
      };

      let stderr = "";
      const code = await runCli(["write-marker", "--out", outPath], {
        stdin: JSON.stringify(badMarker),
        stderr: (msg: string) => (stderr += msg),
      });
      expect(code).toBe(1);
      expect(stderr).toMatch(/refused/i);
      await expect(readFile(outPath)).rejects.toThrow();
    } finally {
      await rm(dir, { recursive: true, force: true });
    }
  });

  test("write-marker writes valid marker", async () => {
    const dir = await scratch();
    try {
      const outPath = join(dir, "written.json");
      const goodMarker = {
        target: "compound-engineering-v3.26.3",
        status: "idle",
        attempts: 0,
        firstAttempt: null,
        lastAttempt: null,
        notBefore: null,
        failureClass: null,
        missing: [],
        issue: null,
      };

      const code = await runCli(["write-marker", "--out", outPath], {
        stdin: JSON.stringify(goodMarker),
      });
      expect(code).toBe(0);
      const raw = await readFile(outPath, "utf-8");
      const parsed = JSON.parse(raw);
      expect(parsed.ceOverlayRebase.target).toBe("compound-engineering-v3.26.3");
      expect(parsed.ceOverlayRebase.status).toBe("idle");
    } finally {
      await rm(dir, { recursive: true, force: true });
    }
  });

  test("decide command prints decision JSON", async () => {
    const input = {
      resolvedTag: "compound-engineering-v3.27.0",
      pin: "compound-engineering-v3.26.3",
      gateClass: "invalid",
      marker: {
        target: "compound-engineering-v3.26.3",
        status: "idle",
        attempts: 0,
        firstAttempt: null,
        lastAttempt: null,
        notBefore: null,
        failureClass: null,
        missing: [],
        issue: null,
      },
      rebaseRuns: [],
      openPullRequests: [],
      trackingIssue: null,
    };

    let stdout = "";
    const code = await runCli(["decide"], {
      stdin: JSON.stringify(input),
      stdout: (msg: string) => (stdout += msg),
    });
    expect(code).toBe(0);
    const parsed = JSON.parse(stdout);
    expect(parsed.action).toBe("dispatch");
  });

  test("classify command prints failureClass and maps unknown", async () => {
    let stdout1 = "";
    const code1 = await runCli(["classify"], {
      stdin: JSON.stringify({
        executionFileContent: JSON.stringify({
          error: { type: "rate_limit_error" },
        }),
      }),
      stdout: (msg: string) => (stdout1 += msg),
    });
    expect(code1).toBe(0);
    expect(JSON.parse(stdout1).failureClass).toBe("quota");

    let stdout2 = "";
    const code2 = await runCli(["classify"], {
      stdin: JSON.stringify({
        callerReason: "some_unrecognized_custom_value",
      }),
      stdout: (msg: string) => (stdout2 += msg),
    });
    expect(code2).toBe(0);
    expect(JSON.parse(stdout2).failureClass).toBe("unknown");
  });

  test("validate-class exits 0 for every member of the closed failure-class set", async () => {
    for (const failureClass of FAILURE_CLASSES) {
      let stderr = "";
      const code = await runCli(["validate-class", failureClass], {
        stderr: (msg: string) => (stderr += msg),
      });
      expect(code).toBe(0);
      expect(stderr).toBe("");
    }
  });

  test("validate-class exits non-zero for a value outside the set or a missing value", async () => {
    for (const args of [
      ["validate-class", "none"],
      ["validate-class", "Outage"],
      ["validate-class", ""],
      ["validate-class", "outage", "quota"],
      ["validate-class"],
    ]) {
      let stderr = "";
      const code = await runCli(args, { stderr: (msg: string) => (stderr += msg) });
      expect(code).not.toBe(0);
      expect(stderr).toMatch(/failure class/i);
    }
  });

  test("transition command produces new marker", async () => {
    const input = {
      currentMarker: {
        target: "compound-engineering-v3.26.3",
        status: "idle",
        attempts: 0,
        firstAttempt: null,
        lastAttempt: null,
        notBefore: null,
        failureClass: null,
        missing: [],
        issue: null,
      },
      event: {
        type: "failure",
        target: "compound-engineering-v3.27.0",
        failureClass: "outage",
        reachedClaude: true,
        now: "2026-09-19T10:00:00.000Z",
      },
    };

    let stdout = "";
    const code = await runCli(["transition"], {
      stdin: JSON.stringify(input),
      stdout: (msg: string) => (stdout += msg),
    });
    expect(code).toBe(0);
    const parsed = JSON.parse(stdout);
    expect(parsed.status).toBe("deferred");
    expect(parsed.attempts).toBe(1);
    expect(parsed.failureClass).toBe("outage");
  });
});
