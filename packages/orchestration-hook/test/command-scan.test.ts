import { describe, expect, it } from "vite-plus/test";
import { scanInvocations } from "../src/command-scan.js";

describe("scanInvocations", () => {
  describe("brief case table", () => {
    it('scans codex exec "x"', () => {
      expect(scanInvocations('codex exec "x"')).toMatchObject([{ program: "codex", next: "exec" }]);
    });

    it("skips leading environment assignments and option flags", () => {
      expect(scanInvocations("FOO=bar BAZ=1 claude -p hi")).toMatchObject([
        { program: "claude", next: "hi" },
      ]);
    });

    it("unwraps env wrapper", () => {
      expect(scanInvocations("env omp run")).toMatchObject([{ program: "omp", next: "run" }]);
    });

    it("unwraps env wrapper with environment assignments", () => {
      expect(scanInvocations("env FOO=1 codex exec")).toMatchObject([
        { program: "codex", next: "exec" },
      ]);
    });

    it("unwraps command wrapper and options without next non-flag token", () => {
      expect(scanInvocations("command -v codex")).toMatchObject([
        { program: "codex", next: undefined },
      ]);
    });

    it("resolves basename for absolute path", () => {
      expect(scanInvocations("/usr/bin/codex")).toMatchObject([
        { program: "codex", next: undefined },
      ]);
    });

    it("scans multiple segments across && operator", () => {
      expect(scanInvocations("git status && omp")).toMatchObject([
        { program: "git", next: "status" },
        { program: "omp", next: undefined },
      ]);
    });

    it("ignores words inside double quotes (echo only)", () => {
      expect(scanInvocations('echo "ask claude about it"')).toMatchObject([
        { program: "echo", next: "ask claude about it" },
      ]);
    });

    it("does not split on operators inside single quotes (echo only)", () => {
      expect(scanInvocations("echo 'a && codex'")).toMatchObject([
        { program: "echo", next: "a && codex" },
      ]);
    });

    it("does not split on semicolons inside double quotes (echo only)", () => {
      expect(scanInvocations('echo "a; codex"')).toMatchObject([
        { program: "echo", next: "a; codex" },
      ]);
    });

    it("scans bash -c string argument recursively", () => {
      expect(scanInvocations("bash -c 'codex exec x'")).toMatchObject([
        { program: "codex", next: "exec" },
      ]);
    });

    it("scans sh -c string argument recursively", () => {
      expect(scanInvocations('sh -c "echo hi"')).toMatchObject([{ program: "echo", next: "hi" }]);
    });

    it("unwraps timeout with duration argument", () => {
      expect(scanInvocations("timeout 5 codex exec")).toMatchObject([
        { program: "codex", next: "exec" },
      ]);
    });

    it("yields nothing for a segment containing $( command substitution", () => {
      expect(scanInvocations("$(which codex) exec")).toMatchObject([]);
    });

    it("yields nothing for backtick command substitution", () => {
      expect(scanInvocations("`codex`")).toMatchObject([]);
    });

    it("yields nothing for ${ parameter expansion", () => {
      expect(scanInvocations("${CMD} exec")).toMatchObject([]);
    });

    it("yields nothing when an unmatched quote makes input unparseable", () => {
      expect(scanInvocations('echo "unmatched')).toMatchObject([]);
    });

    it("yields nothing for empty string", () => {
      expect(scanInvocations("")).toMatchObject([]);
    });

    it("scans argv array", () => {
      expect(scanInvocations(["codex", "exec", "x"])).toMatchObject([
        { program: "codex", next: "exec" },
      ]);
    });

    it("scans argv array with shell wrapper and combined -c flag", () => {
      expect(scanInvocations(["bash", "-lc", "codex exec x"])).toMatchObject([
        { program: "codex", next: "exec" },
      ]);
    });
  });

  describe("additional edge cases", () => {
    it("handles multiple sequential operators and newlines", () => {
      expect(scanInvocations("git status\nclaude\n")).toMatchObject([
        { program: "git", next: "status" },
        { program: "claude", next: undefined },
      ]);
    });

    it("handles pipe and or operators", () => {
      expect(scanInvocations("git log | grep fix || omp")).toMatchObject([
        { program: "git", next: "log" },
        { program: "grep", next: "fix" },
        { program: "omp", next: undefined },
      ]);
    });

    it("handles nested wrappers such as sudo env", () => {
      expect(scanInvocations("sudo -u root env FOO=1 codex exec")).toMatchObject([
        { program: "codex", next: "exec" },
      ]);
    });

    it("handles timeout with flag then duration", () => {
      expect(scanInvocations("timeout -k 1s 10s codex exec")).toMatchObject([
        { program: "codex", next: "exec" },
      ]);
    });

    it("skips segment with unresolvable construct while keeping other valid segments", () => {
      expect(scanInvocations("echo ok; $(bad); claude")).toMatchObject([
        { program: "echo", next: "ok" },
        { program: "claude", next: undefined },
      ]);
    });

    it("returns empty when any unmatched single quote exists anywhere", () => {
      expect(scanInvocations("echo ok; echo 'unmatched")).toMatchObject([]);
    });

    it("handles escaped characters outside quotes", () => {
      expect(scanInvocations("echo hello\\;world; codex")).toMatchObject([
        { program: "echo", next: "hello;world" },
        { program: "codex", next: undefined },
      ]);
    });

    it("handles argv array with flags before first argument", () => {
      expect(scanInvocations(["claude", "-p", "hello"])).toMatchObject([
        { program: "claude", next: "hello" },
      ]);
    });

    it("handles argv array with no following token", () => {
      expect(scanInvocations(["codex"])).toMatchObject([{ program: "codex", next: undefined }]);
    });

    it("handles empty argv array", () => {
      expect(scanInvocations([])).toMatchObject([]);
    });
  });
});

describe("scanInvocations args", () => {
  // `next` skips flags, so a bare program and a `--version` probe are
  // indistinguishable through it. The launch check reads `args` instead.
  it("separates a flag-only invocation from a bare one", () => {
    expect(scanInvocations("claude --version")[0]?.args).toEqual(["--version"]);
    expect(scanInvocations("claude")[0]?.args).toEqual([]);
  });

  it("carries every token after the program, flags included", () => {
    expect(scanInvocations("codex plugin add x")[0]?.args).toEqual(["plugin", "add", "x"]);
  });

  it("carries args through a shell wrapper", () => {
    expect(scanInvocations('bash -c "claude --version"')[0]?.args).toEqual(["--version"]);
  });

  it("carries args from an argv array", () => {
    expect(scanInvocations(["codex", "exec", "x"])[0]?.args).toEqual(["exec", "x"]);
  });
});
