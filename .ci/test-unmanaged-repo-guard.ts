#!/usr/bin/env bun
/**
 * In-process behavior suite for the unmanaged-repo-guard omp extension.
 *
 * Covers plan units U1-U5 of
 * docs/plans/2026-08-05-006-feat-unmanaged-repo-issue-guard-plan.md.
 * No network, no real `gh`/`glab`, no real git: every subprocess is stubbed.
 *
 * Run: bun .ci/test-unmanaged-repo-guard.ts
 */

import { createGuard, readConfig } from "../dot_local/share/omp-plugins/plugins/unmanaged-repo-guard/src/index.ts";
import type {
  BoundedExec,
  Exec,
  ExecResult,
} from "../dot_local/share/omp-plugins/plugins/unmanaged-repo-guard/src/exec.ts";
import { createProber } from "../dot_local/share/omp-plugins/plugins/unmanaged-repo-guard/src/probe.ts";
import { composeReason } from "../dot_local/share/omp-plugins/plugins/unmanaged-repo-guard/src/reason.ts";
import {
  parseRemoteUrl,
  resolveCandidates,
} from "../dot_local/share/omp-plugins/plugins/unmanaged-repo-guard/src/target.ts";
import type { RepoRef } from "../dot_local/share/omp-plugins/plugins/unmanaged-repo-guard/src/target.ts";
import { classify, splitCommand, toArgv } from "../dot_local/share/omp-plugins/plugins/unmanaged-repo-guard/src/triggers.ts";
import type { Classification } from "../dot_local/share/omp-plugins/plugins/unmanaged-repo-guard/src/triggers.ts";

/** Every scenario below must run; a silently deleted check would lower this. */
const EXPECTED_MIN_CHECKS = 311;

let passed = 0;
const failures: string[] = [];

function check(name: string, condition: boolean, detail?: string): void {
  if (condition) {
    passed += 1;
    return;
  }
  failures.push(detail ? `${name}\n      ${detail}` : name);
}

function eq<T>(name: string, actual: T, expected: T): void {
  check(name, Object.is(actual, expected), `expected ${String(expected)}, got ${String(actual)}`);
}

const CONFIG = { probeTimeoutMs: 5000, cacheTtlMs: 300_000, auditLog: { enabled: false, maxBytes: 1_048_576 } };

function execResult(partial: Partial<ExecResult> = {}): ExecResult {
  return { stdout: "", stderr: "", code: 0, killed: false, ...partial };
}

type StubCall = { command: string; args: string[]; cwd?: string };

/** Raw `Exec` for `createGuard`, which applies its own timeout wrapper. */
function stubExec(
  handler: (command: string, args: string[], cwd?: string) => ExecResult,
): Exec & { calls: StubCall[] } {
  const calls: StubCall[] = [];
  const fn = (async (command: string, args: string[], options?: { cwd?: string }) => {
    calls.push({ command, args, cwd: options?.cwd });
    return handler(command, args, options?.cwd);
  }) as Exec & { calls: StubCall[] };
  fn.calls = calls;
  return fn;
}

/** Pre-bounded exec for direct probe/target calls; `null` models a timeout. */
function boundedStub(
  handler: (command: string, args: string[], cwd?: string) => ExecResult | null,
): BoundedExec & { calls: StubCall[] } {
  const calls: StubCall[] = [];
  const fn = (async (command: string, args: string[], options?: { cwd?: string }) => {
    calls.push({ command, args, cwd: options?.cwd });
    return handler(command, args, options?.cwd);
  }) as BoundedExec & { calls: StubCall[] };
  fn.calls = calls;
  return fn;
}

type GhStubExtra = { origin?: string; login?: string; repoFailure?: Partial<ExecResult> };

function ghHandler(repoJson: Record<string, unknown>, extra?: GhStubExtra) {
  return (command: string, args: string[]): ExecResult => {
    if (command === "git") {
      return extra?.origin === undefined
        ? execResult({ code: 1, stderr: "no such remote" })
        : execResult({ stdout: `${extra.origin}\n` });
    }
    if (command === "gh" && args[0] === "api") {
      return execResult({ stdout: `${extra?.login ?? "tester"}\n` });
    }
    if (command === "gh" && args[0] === "repo") {
      if (extra?.repoFailure) return execResult(extra.repoFailure);
      return execResult({ stdout: JSON.stringify(repoJson) });
    }
    if (command === "glab" && args.includes("user")) {
      return execResult({ stdout: JSON.stringify({ username: "tester" }) });
    }
    return execResult({ code: 127, stderr: "unexpected command" });
  };
}

const ghStub = (repoJson: Record<string, unknown>, extra?: GhStubExtra) =>
  stubExec(ghHandler(repoJson, extra));
const ghBounded = (repoJson: Record<string, unknown>, extra?: GhStubExtra) =>
  boundedStub(ghHandler(repoJson, extra));

const asWrite = (c: Classification) => (c.kind === "issue-write" ? c : null);
const bash = (command: string, cwd?: string) =>
  classify("bash", cwd === undefined ? { command } : { command, cwd });

// ---------------------------------------------------------------- U1: classify

check("U1 gh issue create classifies", asWrite(bash("gh issue create --repo o/r -t x -b y"))?.repo === "o/r");
check("U1 gh issue comment classifies (R4)", asWrite(bash("gh issue comment 3 --repo o/r -b y")) !== null);
eq("U1 gh issue list ignored (R5)", bash("gh issue list --repo o/r").kind, "ignore");
eq("U1 gh issue view ignored (R5)", bash("gh issue view 3 --repo o/r").kind, "ignore");
eq("U1 bare gh api ignored (R5)", bash("gh api repos/o/r/issues").kind, "ignore");
eq("U1 explicit GET gh api ignored (R5)", bash("gh api -X GET repos/o/r/issues").kind, "ignore");
eq("U1 gh pr create ignored (R7)", bash("gh pr create --title x").kind, "ignore");
eq("U1 glab mr create ignored (R7)", bash("glab mr create --title x").kind, "ignore");
eq("U1 glab issue update --assignee ignored (R6)", bash("glab issue update 5 --assignee +alice").kind, "ignore");
check("U1 glab api POST to issues classifies", asWrite(bash("glab api projects/o%2Fr/issues -X POST"))?.repo === "o/r");
check("U1 gh api POST to issue comments classifies (R4)", asWrite(bash("gh api -X POST repos/o/r/issues/5/comments"))?.repo === "o/r");
check("U1 chained command classifies", asWrite(bash("cd /tmp && gh issue create --repo o/r"))?.repo === "o/r");
check("U1 leading env assignment skipped", asWrite(bash("env GH_TOKEN=x gh issue create --repo o/r"))?.repo === "o/r");
check("U1 absolute binary path skipped", asWrite(bash("/usr/bin/gh issue create --repo o/r"))?.repo === "o/r");
check("U1 GH_HOST captured (R11)", asWrite(bash("GH_HOST=ghe.example.com gh issue create --repo o/r"))?.host === "ghe.example.com");
check("U1 glab --hostname captured (R11)", asWrite(bash("glab issue create --hostname gitlab.example.com --title x"))?.host === "gitlab.example.com");

// Grouping punctuation: confirmed bypasses before the fix.
for (const [label, cmd] of [
  ["unspaced subshell", "(gh issue create --repo o/r -t x)"],
  ["spaced subshell", "( gh issue create --repo o/r -t x )"],
  ["brace group", "{ gh issue create --repo o/r; }"],
] as const) {
  check(`U1 ${label} classifies`, asWrite(bash(cmd))?.repo === "o/r", cmd);
}

// Redirections must not be read as control operators.
for (const [label, cmd] of [
  ["2>&1", "gh issue create --repo o/r -t x 2>&1"],
  ["&>file", "gh issue create --repo o/r -t x &>/dev/null"],
  [">&2", "gh issue create --repo o/r -t x >&2"],
] as const) {
  check(`U1 redirection ${label} classifies`, asWrite(bash(cmd))?.repo === "o/r", cmd);
}
eq("U1 lone & still splits", bash("gh issue view 1 --repo o/r & echo done").kind, "ignore");

// Interpreter stdin is always executable text; a body flag on the interpreter
// itself must not make it look like inert data.
for (const [label, cmd] of [
  ["plain heredoc", "bash <<'EOF'\ngh issue create --repo o/r -t x\nEOF"],
  ["heredoc then &&", "bash <<'EOF' && echo done\ngh issue create --repo o/r\nEOF"],
  ["heredoc then ;", "bash <<'EOF' ; echo done\ngh issue create --repo o/r\nEOF"],
  ["bash -m collision", "bash -m <<'EOF'\ngh issue create --repo o/r\nEOF"],
  ["tab-stripped <<-", "bash <<-'EOF'\n\tgh issue create --repo o/r\n\tEOF"],
  ["here-string", "bash <<< 'gh issue create --repo o/r'"],
] as const) {
  check(`U1 interpreter ${label} classifies`, asWrite(bash(cmd))?.repo === "o/r", cmd);
}
eq(
  "U1 interpreter heredoc with no gh/glab stays ignored",
  bash("python3 <<'EOF'\nprint('hello')\nEOF").kind,
  "ignore",
);
{
  const c = asWrite(bash("gh issue create --repo o/r -F - <<'EOF'\ngh issue create --repo other/x\nEOF"));
  check("U1 gh-attached heredoc body is not rescanned", c !== null && c.repo === "o/r");
}
eq("U1 quoted mention is not an argv head", bash('echo "run gh issue create later" > notes.txt').kind, "ignore");
eq("U1 read piped to grep ignored", bash("gh issue view 3 --repo o/r | grep gh").kind, "ignore");
check("U1 mcp issue create classifies", classify("mcp__glab_issue_create", { title: "x" }).kind === "issue-write");
check("U1 mcp issue note classifies (real glab tool name)", classify("mcp__glab_issue_note", { body: "x" }).kind === "issue-write");
eq("U1 mcp issue list ignored", classify("mcp__glab_issue_list", {}).kind, "ignore");
eq("U1 unknown mcp tool ignored (fail-open route boundary, KTD4)", classify("mcp__foo_bar", {}).kind, "ignore");

// omp's DEFAULT MCP mounting folds a connected MCP tool behind an `xd://`
// device reached through the ordinary `write` tool. That outer `write` is NOT
// classified here on purpose: omp re-enters the tool_call hook with the
// expanded `mcp__<server>_<tool>` name and its parsed arguments, so the branch
// above already covers the device route one layer down. Verified against the
// locked omp version by tracing every toolName the handler receives; step 6 of
// .ci/test-unmanaged-repo-guard-real.sh proves it end to end.
eq("U8 outer xd:// device write is not classified; the expanded call is", classify("write", { path: "xd://mcp__glab_issue_create", content: '{"repo":"o/r"}' }).kind, "ignore");
eq("U8 ordinary file write ignored", classify("write", { path: "notes.txt", content: "hello" }).kind, "ignore");

// ANSI-C escapes must be DECODED, not merely unquoted. Bash resolves
// `$'\x69ssue'` to `issue`, so a tokenizer that yields `x69ssue` classifies
// the call as unrelated and the write runs with no permission probe --
// and fallbackScan cannot rescue it, because the raw text holds no literal
// `issue` for its regex to match. Surfaced by code review of the U1 change.
for (const [label, encoded] of [
  ["hex", "$'\\x69ssue'"],
  ["octal", "$'\\151ssue'"],
  ["unicode", "$'\\u0069ssue'"],
  ["split across escapes", "$'\\x69\\x73sue'"],
] as const) {
  const c = bash(`gh ${encoded} create --repo other-owner/other-repo`);
  eq(`U1 ansi-c ${label} subcommand still classifies (R4)`, c.kind, "issue-write");
  eq(`U1 ansi-c ${label} subcommand keeps the repo (R4)`, c.repo, "other-owner/other-repo");
}
eq("U1 ansi-c newline escape decodes", toArgv("echo $'a\\nb'")[1], "a\nb");
eq("U1 ansi-c tab escape decodes", toArgv("echo $'a\\tb'")[1], "a\tb");
eq("U1 ansi-c unrecognised escape keeps its backslash, as bash does", toArgv("echo $'a\\qb'")[1], "a\\qb");
eq("U1 ansi-c escaped backslash decodes to one backslash", toArgv("echo $'a\\\\b'")[1], "a\\b");
// Adversarial re-review of the decode above found four more shapes bash
// executes as `gh issue create` while the guard saw something else. All are
// the same class: the tokenizer must agree with bash BYTE for byte, because
// fallbackScan cannot rescue an encoded subcommand.
for (const [label, head] of [
  // Bash truncates an argv word at a NUL; the guard used to keep the tail.
  ["nul terminator", "$'issue\\0'"],
  ["octal wrap to nul", "$'issue\\400x'"],
  ["control-@ is nul", "$'issue\\c@'"],
  // Bash DROPS an out-of-range code point, making this exactly `issue`.
  ["out-of-range \\U vanishes", "$'iss\\UFFFFFFFFue'"],
] as const) {
  const c = bash(`gh ${head} create --repo other-owner/other-repo`);
  eq(`U1 ansi-c ${label} still classifies (R4)`, c.kind, "issue-write");
  eq(`U1 ansi-c ${label} keeps the repo (R4)`, c.repo, "other-owner/other-repo");
}
// Line continuation: bash removes the backslash-newline pair and joins the
// word. Emitting a literal newline split `issue` and lost the route. Needs no
// ANSI-C quoting at all.
{
  const c = bash("gh iss\\\nue create --repo other-owner/other-repo");
  eq("U1 line continuation still classifies (R4)", c.kind, "issue-write");
  eq("U1 line continuation keeps the repo (R4)", c.repo, "other-owner/other-repo");
}
// `\c` is the only escape whose target may be any character, so it is the only
// one that could swallow the span's closing quote and leave toArgv inside a
// quote splitCommand had already closed. Bash keeps a dangling `\c` literal,
// so `issue\c` is genuinely not an issue write - but the two machines must
// still agree on where the span ended.
eq("U1 ansi-c dangling backslash-c matches bash literally", toArgv("x $'issue\\c'")[1], "issue\\c");
eq("U1 ansi-c dangling backslash-c does not desync the span", splitCommand("gh $'issue\\c' create").unparseable, false);
eq("U1 ansi-c control escape decodes to its byte", toArgv("x $'a\\cXb'")[1], "a\x18b");
eq("U1 ansi-c octal above 0xff wraps to a byte", toArgv("x $'\\777'")[1], "\u00ff");
// A throw from classify() escapes the guard entirely, including its
// fail-closed handler, so an unrepresentable escape must degrade, never throw.
let outOfRangeThrew = false;
try {
  classify("bash", { command: "gh issue create --repo o/r --title $'\\UFFFFFFFF'" });
} catch {
  outOfRangeThrew = true;
}
eq("U1 ansi-c out-of-range \\U does not throw out of classify", outOfRangeThrew, false);

// Recorded accepted residual gaps: asserted so the suite states its boundary.
// A shell-shaped line inside any interpreter heredoc IS caught (covered above);
// what is not caught is a write expressed in a non-shell language's own syntax,
// because a shell tokenizer cannot parse Python/Node/Ruby source.
for (const [label, cmd] of [
  ["curl", "curl -XPOST https://api.github.com/repos/o/r/issues"],
  ["interpreter script file", "bash /tmp/filer.sh"],
  ["unexpanded alias", "gh filebug"],
  ["python source call", "python3 <<'EOF'\nimport os; os.system('gh issue create --repo o/r')\nEOF"],
  ["node source call", "node <<'EOF'\nrequire('child_process').execSync(\"gh issue create --repo o/r\")\nEOF"],
] as const) {
  eq(`U1 accepted residual gap not covered: ${label}`, bash(cmd).kind, "ignore");
}
// A bare shell-shaped line in a non-shell heredoc still is caught, which is why
// those interpreters stay in the recursion table.
check(
  "U1 shell-shaped line inside a python heredoc is still caught",
  asWrite(bash("python3 <<'EOF'\ngh issue create --repo o/r\nEOF"))?.repo === "o/r",
);

// R13/R15 (#186, #188): an unrecognised head must not silently drop a segment
// that still names gh/glab -- whether it is a recognised prefix's own option
// (`env -C`, `sudo -u`, which leave argvHead returning a flag) or an
// argv-forwarding wrapper. Every command below was reproduced as `ignore`
// against the classifier before the fix, so each is a closed bypass.
for (const [label, cmd] of [
  ["env -C", "env -C /srv/other gh issue create --repo o/r -t x"],
  ["sudo -u", "sudo -u nobody gh issue create --repo o/r -t x"],
  ["sudo --preserve-env=", "sudo --preserve-env=PATH gh issue create --repo o/r"],
  ["xargs", "xargs gh issue create --repo o/r"],
  ["timeout", "timeout 30 gh issue create --repo o/r"],
  ["nice -n", "nice -n 5 gh issue create --repo o/r"],
  ["stdbuf", "stdbuf -oL gh issue create --repo o/r"],
  ["setsid", "setsid gh issue create --repo o/r"],
  ["absolute wrapper path", "/usr/bin/timeout 30 /usr/bin/gh issue create --repo o/r"],
] as const) {
  check(`U1 ${label} fails closed (R13/R15)`, asWrite(bash(cmd))?.repo === "o/r", cmd);
}
// A wrapper may forward the whole command line as ONE word. That is a command,
// not prose, so its head is what decides -- see the ignored cases below.
check(
  "U1 wrapper forwarding one quoted command line fails closed (R15)",
  asWrite(bash("watch 'gh issue create --repo o/r'"))?.repo === "o/r",
);
eq(
  "U1 wrapped write with no --repo cannot assume the cwd (R13)",
  asWrite(bash("env -C /srv/other gh issue create -t x"))?.cwdUnresolvable,
  true,
);
{
  // The fail-closed path must merge the cd state the earlier segments built,
  // not discard it for fallbackScan's own nulls.
  const c = asWrite(bash("cd /other/checkout && xargs gh issue create -t x"));
  eq("U1 wrapped write keeps the accumulated cd (R15)", c?.cdTarget, "/other/checkout");
  eq("U1 wrapped write with no --repo is still unresolvable (R15)", c?.cwdUnresolvable, true);
}
// Accepted cost of the fail-closed rule: a READ behind a wrapper becomes a
// probe candidate. The probe allows it whenever the repository is managed.
// Asserted so narrowing this later is a deliberate change, not a silent one.
eq(
  "U1 wrapped read is an accepted false candidate (R15)",
  bash("xargs gh issue list --repo o/r").kind,
  "issue-write",
);
// Boundaries of the rule. `cliMention` is token-level on purpose: a word-
// boundary scan of the raw text would turn every prose mention into a candidate.
for (const [label, cmd] of [
  ["unrecognised head with no gh/glab token", "env -C /srv/other true"],
  ["wrapped gh with no issue/api route", "xargs gh auth status"],
  ["prose mention behind an unrecognised head", "git commit -m 'mentions gh issue create in prose'"],
] as const) {
  eq(`U1 ${label} stays ignored (R15)`, bash(cmd).kind, "ignore");
}
// The mention test and the rescan must agree about ENCODING as well. The first
// matches decoded argv, the second matches text, so rescanning the raw segment
// let an ANSI-C-encoded head slip straight back out after the mention had
// already proved it was there — `xargs $'\x67h' …` holds no literal `gh`.
for (const [label, cmd] of [
  ["xargs", "xargs $'\\x67h' issue create --repo o/r"],
  ["timeout", "timeout 30 $'\\x67h' issue create --repo o/r"],
  ["env -C", "env -C /srv/other $'\\x67h' issue create --repo o/r"],
  ["watch, whole line encoded", "watch $'\\x67h issue create --repo o/r'"],
] as const) {
  check(`U1 encoded gh behind ${label} still fails closed (R13/R15)`, asWrite(bash(cmd))?.repo === "o/r", cmd);
}
// An interpreter this table does not model is just an unrecognised head, so the
// same path must carry its encoded payload — and the right target — to the probe.
eq(
  "U1 encoded payload behind an unmodelled interpreter fails closed (R15)",
  asWrite(bash("fish -c $'\\x67h issue create -R victim/repo'"))?.repo,
  "victim/repo",
);
// The target must come from the decoded tokens, not from `fallbackScan`'s
// regex over the rejoined string. Rejoining flattens quoting, so a `--repo`
// the caller only ever wrote inside a title would otherwise aim the probe at a
// repository of the caller's choosing — pass the probe there, write here.
// `repo: null` with `cwdUnresolvable` set is the correct conservative answer.
for (const [label, cmd] of [
  ["title", 'xargs gh issue create --title "--repo evil/x"'],
  ["body", 'timeout 5 gh issue create --body "see -R evil/x"'],
] as const) {
  const c = asWrite(bash(cmd));
  eq(`U1 a --repo hidden in a ${label} does not become the target (R15)`, c?.repo, null);
  eq(`U1 a --repo hidden in a ${label} leaves the cwd unresolvable (R15)`, c?.cwdUnresolvable, true);
}
// Two more spellings of the same spoof. `--title -Revil/x` is the sharper one:
// real gh gives `-Revil/x` to `--title`, but a reader with no notion of
// consumption sees a `-R` and reports `evil/x` as the target.
for (const [label, cmd] of [
  ["attached -R", "gh issue create --title -Revil/x"],
  ["long --repo=", "gh issue create --title '--repo=evil/x'"],
] as const) {
  eq(`U1 a ${label} inside --title is the title's value, not a target (R16)`, asWrite(bash(cmd))?.repo, null);
}

// A forwarded command line is resolved the way any segment is — split into
// simple commands, then through `argvHead` — so a leading `cd`, `sudo`, or
// assignment inside it cannot hide the write. Matching only on `inner[0]`
// left every one of these `ignore`.
for (const [label, cmd] of [
  ["timeout + bash -c + cd", "timeout 30 bash -c 'cd repo && gh issue create --repo o/r'"],
  ["nice + sh -c + cd", "nice -n 5 sh -c 'cd repo && gh issue create --repo o/r'"],
  ["watch + cd", "watch 'cd /srv/other && gh issue create --repo o/r'"],
  ["watch + sudo", "watch 'sudo gh issue create --repo o/r'"],
  ["watch + assignment", "watch 'GH_HOST=example.com gh issue create --repo o/r'"],
  ["setsid + sh -c + sudo", "setsid sh -c 'sudo gh issue create --repo o/r'"],
] as const) {
  check(`U1 a prefix inside a forwarded line does not hide the write: ${label} (R15)`, asWrite(bash(cmd))?.repo === "o/r", cmd);
}

// The fail-closed branch must carry the CLI identity too, or a GitLab write is
// probed as a GitHub one. No other new assertion reaches this field.
{
  const c = asWrite(bash("xargs glab issue create --repo g/p"));
  eq("U1 a wrapped glab write keeps its cli (R15)", c?.cli, "glab");
  eq("U1 a wrapped glab write keeps its hostKind (R15)", c?.hostKind, "gitlab");
  eq("U1 a wrapped glab write keeps its repo (R15)", c?.repo, "g/p");
}

// The interpreter merge must keep the PAYLOAD's cwd uncertainty. Overwriting it
// with the outer value yields `repo: null` with `cwdUnresolvable: false` — the
// one state that makes the caller trust the current checkout's origin.
for (const [label, cmd] of [
  ["variable cd", "bash -c 'cd \"$D\" && gh issue create -t x'"],
  ["cd -", "bash -c 'cd - && gh issue create -t x'"],
  ["tilde cd", "bash -c 'cd ~/elsewhere && gh issue create -t x'"],
] as const) {
  eq(`U1 an unresolvable ${label} inside a -c payload survives the merge (R14)`, asWrite(bash(cmd))?.cwdUnresolvable, true);
}

// R14 (#187): an interpreter's `-c`/`-e` payload is executable text too, and a
// here-string word must be captured whole before it can be re-split.
for (const [label, cmd] of [
  ["bash -c", "bash -c 'gh issue create --repo o/r -t x'"],
  ["sh -lc combined group", "sh -lc 'gh issue create --repo o/r'"],
  ["bash -euc combined group", "bash -euc 'gh issue create --repo o/r'"],
  ["node -e", "node -e 'gh issue create --repo o/r'"],
  ["python3 -c shell-shaped", "python3 -c 'gh issue create --repo o/r'"],
] as const) {
  check(`U1 interpreter ${label} payload is scanned (R14)`, asWrite(bash(cmd))?.repo === "o/r", cmd);
}
eq("U1 interpreter payload with no gh/glab stays ignored (R14)", bash("bash -c 'echo hello'").kind, "ignore");
{
  // Bash re-parses interpreter stdin, so the decoded word is a command LINE.
  // Without the re-split it collapses into one argv token and the route is lost.
  const encoded = "bash <<< $'gh\\x20issue\\x20create\\x20--repo\\x20o/r'";
  eq("U1 ansi-c here-string body classifies (R14)", asWrite(bash(encoded))?.repo, "o/r");
  eq("U1 ansi-c here-string leaves splitCommand balanced (R14)", splitCommand(encoded).unparseable, false);
}
{
  // Before the capture fix this classified only BY ACCIDENT: the word reader
  // stopped at the first space, the trailing quote opened a phantom span, and
  // `unparseable` dropped the command into fallbackScan. Assert the deliberate
  // path, so the accident can never be what keeps this green.
  const spaced = "bash <<< $'gh issue create --repo o/r'";
  eq("U1 spaced ansi-c here-string classifies (R14)", asWrite(bash(spaced))?.repo, "o/r");
  eq("U1 spaced ansi-c here-string is parseable, not rescued (R14)", splitCommand(spaced).unparseable, false);
}
{
  const unterminated = "bash <<< $'gh issue create --repo o/r";
  eq("U1 unterminated ansi-c here-string is flagged unparseable (R14)", splitCommand(unterminated).unparseable, true);
  eq("U1 unterminated ansi-c here-string still classifies (R14)", bash(unterminated).kind, "issue-write");
}

// R16 (#189): a value-taking flag before the subcommand used to shift every
// positional, because the old `words` filter dropped flag tokens but kept the
// value each one consumes. `glab` takes `-R`/`--repo` as a persistent flag.
for (const [label, cmd, repo] of [
  ["glab -R", "glab -R g/p issue create -t x", "g/p"],
  ["gh --repo", "gh --repo o/r issue create -t x", "o/r"],
  ["glab --repo=", "glab --repo=g/p issue create -t x", "g/p"],
] as const) {
  eq(`U1 ${label} before the subcommand still classifies (R16)`, asWrite(bash(cmd))?.repo, repo);
}
eq(
  "U1 --hostname before the subcommand still classifies (R16)",
  asWrite(bash("glab --hostname gitlab.example.com issue create -t x"))?.host,
  "gitlab.example.com",
);
for (const [label, cmd] of [
  ["read", "glab -R g/p issue list"],
  ["pr create (R7)", "gh -R o/r pr create --title x"],
  ["issue update (R6)", "glab -R g/p issue update 5 --assignee +alice"],
] as const) {
  eq(`U1 -R before a non-write subcommand stays ignored: ${label} (R16)`, bash(cmd).kind, "ignore");
}
// The sentinel that actually defends the hazard: a value-taking flag BEFORE
// the subcommand whose value collides with a subcommand name. A parser that
// leaves the consumed value in the positional stream reads `issue`/`issue` as
// the pair and never sees `create`. A post-subcommand collision such as
// `gh issue create --title api` passes either way and proves nothing.
{
  const c = asWrite(bash("glab --hostname issue issue create -t x"));
  eq("U1 a pre-subcommand flag value colliding with a subcommand still classifies (R16)", c?.kind, "issue-write");
  eq("U1 that colliding value is still read as the hostname (R16)", c?.host, "issue");
}
eq(
  "U1 a post-subcommand flag value that reads like a subcommand is harmless (R16)",
  asWrite(bash("gh issue create --title api --repo o/r"))?.repo,
  "o/r",
);
// Attached shorthand (R16). `gh` and `glab` are cobra programs, so pflag's
// `-Nvalue` form is an ordinary invocation — verified against a real
// `glab -Rfoo/bar`. Both shapes below were confirmed broken before the fix:
// `-XPOST` left the method unresolved and the whole write classified `ignore`,
// and `-Rg/p` left `repo: null`, which makes the probe fall back to the
// current checkout's `origin` and clear a write aimed at another repository.
eq("U1 attached -R before the subcommand keeps the repo (R16)", asWrite(bash("glab -Rg/p issue create -t x"))?.repo, "g/p");
eq("U1 attached -R after the subcommand keeps the repo (R16)", asWrite(bash("gh issue create -Ro/r -t x"))?.repo, "o/r");
eq("U1 attached -XPOST api write classifies (R16)", asWrite(bash("gh api -XPOST repos/o/r/issues"))?.repo, "o/r");
// pflag resolves a short group at its FIRST value-taking letter, which then
// swallows the rest. So `-qXPOST` is `--jq XPOST`, a READ with an odd filter —
// not `--method POST`. Asserting a write here would encode a grammar the real
// CLI does not have, and it is the same misreading that hid `-XPATCH`.
eq("U1 clustered -qXPOST resolves as --jq, so it stays a read (R16)", bash("gh api -qXPOST repos/o/r/issues").kind, "ignore");
eq("U1 clustered -iXPOST is a write, since -i takes no value (R16)", asWrite(bash("gh api -iXPOST repos/o/r/issues"))?.repo, "o/r");
// PATCH on an issue path is an issue edit. It is spelling-sensitive: the old
// last-character rule read `-XPATCH` as ending in `-H`, ate the endpoint, and
// returned `ignore`. POST and DELETE survived only because `-T` and `-E` are
// not value flags — that is luck, not coverage.
for (const spelling of ["-XPATCH", "-X PATCH", "--method PATCH", "--method=PATCH", "-iXPATCH"] as const) {
  eq(`U1 api PATCH spelled ${spelling} classifies (R16)`, asWrite(bash(`gh api ${spelling} repos/o/r/issues/5`))?.repo, "o/r");
}
// Every value-taking `api` flag must be listed, or it eats the endpoint.
for (const [label, cmd, repo] of [
  ["--preview", "gh api -X POST --preview inertia repos/o/r/issues", "o/r"],
  ["-p", "gh api -X POST -p inertia repos/o/r/issues", "o/r"],
  ["--form", "glab api -X POST --form file=@x projects/g%2Fp/issues", "g/p"],
  ["--output", "glab api -X POST --output json projects/g%2Fp/issues", "g/p"],
] as const) {
  eq(`U1 api value flag ${label} does not eat the endpoint (R16)`, asWrite(bash(cmd))?.repo, repo);
}
// cobra is last-wins for a repeated flag; reading the first hands the probe a
// decoy the caller controls while the write lands on the later value.
eq("U1 a repeated --repo resolves last-wins (R16)", asWrite(bash("gh issue create --repo mine/ok --repo victim/x -t x"))?.repo, "victim/x");
eq("U1 a repeated -R resolves last-wins (R16)", asWrite(bash("gh issue create -R mine/ok -R victim/x -t x"))?.repo, "victim/x");
eq("U1 a repeated -X resolves last-wins (R16)", asWrite(bash("gh api -X GET -X POST repos/o/r/issues"))?.repo, "o/r");
eq("U1 attached -XGET stays a read (R16)", bash("gh api -XGET repos/o/r/issues").kind, "ignore");
// A short name must never match by prefix into a longer long-form flag.
eq("U1 --repository is not read as --repo (R16)", asWrite(bash("gh issue create --repository o/r"))?.repo, null);
// Clustered short groups whose value lands in the NEXT word. Before `parseArgs`
// the value lookup and the positional walk were separate readers: while only
// the value lookup understood `-iX POST`, the word `POST` stayed in the positional
// stream, became the API path, and the write classified `ignore`.
eq("U1 clustered -iX with the value in the next word classifies (R16)", asWrite(bash("gh api -iX POST repos/o/r/issues"))?.repo, "o/r");
eq("U1 clustered -qR with the value in the next word classifies (R16)", asWrite(bash("glab -qR g/p issue create -t x"))?.repo, "g/p");
eq("U1 clustered attached -iXGET stays a read (R16)", bash("gh api -iXGET repos/o/r/issues").kind, "ignore");
// Every value-taking `api` flag must be known, or it shifts the path too.
eq("U1 -q before the api path does not shift it (R16)", asWrite(bash("gh api -X POST -q .id repos/o/r/issues"))?.repo, "o/r");
eq("U1 -t before the api path does not shift it (R16)", asWrite(bash("gh api -X POST -t '{{.id}}' repos/o/r/issues"))?.repo, "o/r");
// Differential guard over pflag spellings (R16). Two of the four bypasses this
// change closed were those two readers disagreeing about which
// token was a flag's value, so the enumerated cases above are not enough: the
// invariant is that EVERY valid spelling of one write classifies identically.
// Kept as two checks rather than thousands so the count stays meaningful.
{
  const methods = ["-X POST", "-XPOST", "--method POST", "--method=POST", "-iX POST", "-iXPOST", "-vXPOST",
    "-X PATCH", "-XPATCH", "--method PATCH", "-X DELETE", "-XDELETE"];
  const noise = ["", "-i", "--paginate", "-q .id", "-qq .id", "--jq .id", "-t {{.id}}", "--template {{.id}}",
    "-H Accept:v3", "-HAccept:v3", "--header Accept:v3", "-f title=x", "-F body=y", "--input -", "--cache 5m"];
  const path = "repos/o/r/issues";
  const missed: string[] = [];
  for (const m of methods) {
    for (const a of noise) {
      for (const b of noise) {
        for (const order of [`${m} ${a} ${b}`, `${a} ${m} ${b}`, `${a} ${b} ${m}`]) {
          const cmd = `gh api ${`${order} ${path}`.replace(/\s+/g, " ").trim()}`;
          const c = asWrite(bash(cmd));
          if (c?.repo !== "o/r") missed.push(cmd);
        }
      }
    }
  }
  check(`U1 every pflag spelling of one api write classifies alike (R16)`, missed.length === 0, missed.slice(0, 5).join("\n      "));

  const falseWrites: string[] = [];
  for (const m of ["-X GET", "-XGET", "--method GET", "--method=GET", "-iXGET", ""]) {
    for (const a of noise) {
      const cmd = `gh api ${`${m} ${a} ${path}`.replace(/\s+/g, " ").trim()}`;
      if (bash(cmd).kind !== "ignore") falseWrites.push(cmd);
    }
  }
  check(`U1 no pflag spelling turns an api read into a write (R16)`, falseWrites.length === 0, falseWrites.slice(0, 5).join("\n      "));
}

// `cd` tracking, so origin resolves from the directory the write runs in.
{
  const c = asWrite(bash("cd /other/checkout && gh issue create -t x"));
  eq("U1 literal absolute cd captured", c?.cdTarget, "/other/checkout");
  eq("U1 literal cd is resolvable", c?.cwdUnresolvable, false);
}
{
  const c = asWrite(bash("cd sub/dir && gh issue create -t x"));
  eq("U1 literal relative cd captured", c?.cdTarget, "sub/dir");
}
for (const [label, cmd] of [
  ["variable cd", "cd \"$TARGET\" && gh issue create -t x"],
  ["cd -", "cd - && gh issue create -t x"],
  ["tilde cd", "cd ~/elsewhere && gh issue create -t x"],
  ["bare cd", "cd && gh issue create -t x"],
  ["popd", "pushd /a && popd && gh issue create -t x"],
] as const) {
  eq(`U1 unresolvable ${label} flagged`, asWrite(bash(cmd))?.cwdUnresolvable, true);
}
eq(
  "U1 unresolvable cd is irrelevant when --repo is explicit",
  asWrite(bash("cd \"$T\" && gh issue create --repo o/r"))?.repo,
  "o/r",
);

// ANSI-C `$'...'` quoting (R4): an escaped quote inside the span must not
// leak quote state past it, in both splitCommand's segment tracker and
// toArgv's independent argv tracker. A splitCommand-only fix would still
// mis-split in toArgv, so every case below checks both.
{
  const oneEscape = "gh issue create --title $'Don\\'t stop' --repo o/r";
  eq("U1 ansi-c $'...' escaped quote classifies with the correct repo (R4)", asWrite(bash(oneEscape))?.repo, "o/r");
  eq("U1 ansi-c $'...' escaped quote leaves splitCommand balanced (R4)", splitCommand(oneEscape).unparseable, false);
  eq(
    "U1 toArgv keeps an ansi-c escaped quote as one element, not two (R4)",
    JSON.stringify(toArgv(oneEscape)),
    JSON.stringify(["gh", "issue", "create", "--title", "Don't stop", "--repo", "o/r"]),
  );
}
{
  const twoEscapes = "gh issue create --title $'a\\'b\\'c' --repo o/r";
  eq("U1 two ansi-c escaped quotes leave splitCommand balanced (R4)", splitCommand(twoEscapes).unparseable, false);
  eq(
    "U1 toArgv decodes two ansi-c escaped quotes as one element (R4)",
    JSON.stringify(toArgv(twoEscapes)),
    JSON.stringify(["gh", "issue", "create", "--title", "a'b'c", "--repo", "o/r"]),
  );
}
{
  const semicolon = "gh issue create --title $'a;b' --repo o/r";
  const sr = splitCommand(semicolon);
  check("U1 ; inside an ansi-c span does not split the command (R4)", sr.segments.length === 1 && !sr.unparseable);
  eq(
    "U1 ; inside an ansi-c span does not split the argv element (R4)",
    JSON.stringify(toArgv(semicolon)),
    JSON.stringify(["gh", "issue", "create", "--title", "a;b", "--repo", "o/r"]),
  );
}
{
  const dollarInDquotes = 'echo "$\'" foo';
  const sr = splitCommand(dollarInDquotes);
  check(
    "U1 $ before ' inside double quotes is not an ansi-c opener in splitCommand (R4)",
    sr.segments.length === 1 && !sr.unparseable,
  );
  eq(
    "U1 $ before ' inside double quotes is not an ansi-c opener in toArgv (R4)",
    JSON.stringify(toArgv(dollarInDquotes)),
    JSON.stringify(["echo", "$'", "foo"]),
  );
}
{
  const plainSingleQuote = "'don\\'t'";
  eq(
    "U1 plain single-quoted backslash-quote still closes at the second quote in splitCommand (R4)",
    splitCommand(plainSingleQuote).unparseable,
    true,
  );
  eq(
    "U1 plain single-quoted backslash-quote still closes at the second quote in toArgv (R4)",
    JSON.stringify(toArgv(plainSingleQuote)),
    JSON.stringify(["don\\t"]),
  );
}

// ------------------------------------------------------- U2: target resolution

{
  const remotes: [string, string, string][] = [
    ["git@github.com:o/r.git", "github.com", "o/r"],
    ["https://github.com/o/r.git", "github.com", "o/r"],
    ["https://github.com/o/r", "github.com", "o/r"],
    ["ssh://git@gitlab.example.com/g/sub/p.git", "gitlab.example.com", "g/sub/p"],
    ["https://gitlab.example.com:8443/g/p.git", "gitlab.example.com", "g/p"],
    ["git@[2001:db8::1]:o/r.git", "[2001:db8::1]", "o/r"],
  ];
  for (const [url, host, path] of remotes) {
    const parsed = parseRemoteUrl(url);
    check(`U2 parses ${url}`, parsed?.host === host && parsed?.path === path, JSON.stringify(parsed));
  }
}

async function resolveBash(command: string, exec: BoundedExec, cwd = "/work") {
  const c = asWrite(bash(command));
  if (!c) throw new Error(`expected issue-write for: ${command}`);
  return await resolveCandidates(c, cwd, exec);
}

for (const form of ["--repo o/r", "-R o/r", "--repo=o/r"]) {
  const r = await resolveBash(`gh issue create ${form}`, ghBounded({}));
  check(`U2 explicit ${form} resolves`, r.candidates[0]?.path === "o/r" && !r.invalid);
}
{
  const r = await resolveBash("gh issue create -t x", ghBounded({}, { origin: "git@github.com:o/r.git" }));
  check("U2 falls back to origin (R9)", r.candidates[0]?.path === "o/r" && !r.invalid);
}
{
  const exec = ghBounded({}, { origin: "git@github.com:o/r.git" });
  await resolveBash("cd /elsewhere && gh issue create -t x", exec);
  eq("U2 origin lookup uses the cd-adjusted cwd", exec.calls.find((c) => c.command === "git")?.cwd, "/elsewhere");
}
{
  const exec = ghBounded({}, { origin: "git@github.com:o/r.git" });
  await resolveBash("cd sub && gh issue create -t x", exec, "/work");
  eq("U2 relative cd joins onto the tool cwd", exec.calls.find((c) => c.command === "git")?.cwd, "/work/sub");
}
{
  const exec = ghBounded({}, { origin: "git@github.com:o/r.git" });
  const r = await resolveBash('cd "$T" && gh issue create -t x', exec);
  check("U2 unresolvable cd blocks without probing git", r.invalid && exec.calls.length === 0);
}
{
  const r = await resolveBash(
    "GH_HOST=ghe.example.com gh issue create -t x",
    ghBounded({}, { origin: "git@github.com:o/r.git" }),
  );
  eq("U2 command host overrides remote host (R11)", r.candidates[0]?.host, "ghe.example.com");
}
check("U2 absent origin yields no candidates", (await resolveBash("gh issue create -t x", ghBounded({}))).invalid);
check(
  "U2 hung git lookup yields no candidates",
  (await resolveBash("gh issue create -t x", boundedStub(() => null))).invalid,
);
eq(
  "U2 explicit --repo beats origin (R8)",
  (await resolveBash("gh issue create --repo explicit/win", ghBounded({}, { origin: "git@github.com:other/repo.git" })))
    .candidates[0]?.path,
  "explicit/win",
);
for (const hostile of ['--repo "o/r; rm -rf /"', "--repo '$(id)'", "--repo ../../etc", "--repo -flag/x"]) {
  const r = await resolveBash(`gh issue create ${hostile}`, ghBounded({}));
  check(`U2 rejects hostile identifier ${hostile} (R15)`, r.invalid && r.candidates.length === 0);
}

// ------------------------------------------------------------------- U3: probe

const githubRef: RepoRef = { host: "github.com", hostKind: "github", path: "o/r" };
const gitlabRef: RepoRef = { host: "gitlab.com", hostKind: "gitlab", path: "g/p" };

async function verdictFor(ref: RepoRef, exec: BoundedExec, ttlMs = CONFIG.cacheTtlMs, now = () => 0) {
  return await createProber({ exec, now, cacheTtlMs: ttlMs }).evaluate([ref]);
}

for (const permission of ["WRITE", "MAINTAIN", "ADMIN"]) {
  eq(`U3 ${permission} is managed`, (await verdictFor(githubRef, ghBounded({ viewerPermission: permission, isFork: false }))).verdict, "managed");
}
for (const permission of ["READ", "NONE"]) {
  eq(`U3 ${permission} is unmanaged`, (await verdictFor(githubRef, ghBounded({ viewerPermission: permission, isFork: false }))).verdict, "unmanaged");
}
{
  const glab = (body: Record<string, unknown>) =>
    boundedStub((command, args) =>
      command === "glab" && args.includes("user")
        ? execResult({ stdout: JSON.stringify({ username: "tester" }) })
        : execResult({ stdout: JSON.stringify(body) }),
    );
  eq("U3 gitlab access_level 30 managed", (await verdictFor(gitlabRef, glab({ permissions: { project_access: { access_level: 30 } } }))).verdict, "managed");
  eq("U3 gitlab access_level 20 unmanaged", (await verdictFor(gitlabRef, glab({ permissions: { project_access: { access_level: 20 } } }))).verdict, "unmanaged");
  eq("U3 gitlab both permissions null unmanaged", (await verdictFor(gitlabRef, glab({ permissions: { project_access: null, group_access: null } }))).verdict, "unmanaged");
  eq("U3 gitlab group_access 40 managed", (await verdictFor(gitlabRef, glab({ permissions: { project_access: null, group_access: { access_level: 40 } } }))).verdict, "managed");
  eq("U3 gitlab fork without parent is indeterminate", (await verdictFor(gitlabRef, glab({ permissions: { project_access: { access_level: 40 } }, forked_from_project: { id: 7 } }))).verdict, "indeterminate");
  eq("U3 gitlab omitted permissions is indeterminate", (await verdictFor(gitlabRef, glab({}))).verdict, "indeterminate");
}
for (const [label, failure] of [
  ["non-zero exit", { code: 1, stderr: "boom" }],
  ["empty stdout", { stdout: "" }],
  ["malformed JSON", { stdout: "{not json" }],
  ["non-object JSON", { stdout: '"a string"' }],
] as const) {
  eq(`U3 ${label} is indeterminate (R3)`, (await verdictFor(githubRef, ghBounded({}, { repoFailure: failure }))).verdict, "indeterminate");
}
eq(
  "U3 hung probe is indeterminate",
  (await verdictFor(githubRef, boundedStub((command, args) => (command === "gh" && args[0] === "repo" ? null : execResult({ stdout: "tester\n" }))))).verdict,
  "indeterminate",
);
eq(
  "U3 omitted viewerPermission is indeterminate",
  (await verdictFor(githubRef, ghBounded({ isFork: false }))).verdict,
  "indeterminate",
);
{
  const forkStub = boundedStub((command, args) => {
    if (command === "gh" && args[0] === "api") return execResult({ stdout: "tester\n" });
    return args[2] === "me/fork"
      ? execResult({ stdout: JSON.stringify({ viewerPermission: "ADMIN", isFork: true, parent: { name: "upstream", owner: { login: "them" } } }) })
      : execResult({ stdout: JSON.stringify({ viewerPermission: "READ", isFork: false }) });
  });
  const outcome = await createProber({ exec: forkStub, now: () => 0, cacheTtlMs: 1000 }).evaluate([
    { host: "github.com", hostKind: "github", path: "me/fork" },
  ]);
  eq("U3 unmanaged fork parent decides (R10)", outcome.verdict, "unmanaged");
  eq("U3 fork parent is the reported repo", outcome.repo, "them/upstream");
}

// R9: a cache hit for a fork must still surface its resolved parent, so a
// second call inside the same TTL window re-checks the parent chain instead
// of silently trusting a stale "managed" verdict for the fork alone.
{
  const exec = boundedStub((command, args) => {
    if (command === "gh" && args[0] === "api") return execResult({ stdout: "tester\n" });
    return args[2] === "me/fork"
      ? execResult({ stdout: JSON.stringify({ viewerPermission: "ADMIN", isFork: true, parent: { name: "upstream", owner: { login: "them" } } }) })
      : execResult({ stdout: JSON.stringify({ viewerPermission: "READ", isFork: false }) });
  });
  const prober = createProber({ exec, now: () => 0, cacheTtlMs: 1000 });
  const forkRef: RepoRef = { host: "github.com", hostKind: "github", path: "me/fork" };

  const first = await prober.evaluate([forkRef]);
  eq("U3 fork with unmanaged parent blocks on first evaluate (R9)", first.verdict, "unmanaged");
  const forkCallsAfterFirst = exec.calls.filter((c) => c.args[0] === "repo" && c.args[2] === "me/fork").length;
  const parentCallsAfterFirst = exec.calls.filter((c) => c.args[0] === "repo" && c.args[2] === "them/upstream").length;

  // No existing test calls evaluate twice; this is the regression itself —
  // before the fix, a cache-hit fork always reported parent: null, so the
  // second call never re-walked the chain and returned "managed" instead.
  const second = await prober.evaluate([forkRef]);
  eq("U3 cached fork verdict still blocks on second evaluate (R9)", second.verdict, "unmanaged");
  eq(
    "U3 cached fork hop resolves from cache without a subprocess (R9)",
    exec.calls.filter((c) => c.args[0] === "repo" && c.args[2] === "me/fork").length,
    forkCallsAfterFirst,
  );
  eq(
    "U3 cached fork parent hop resolves from cache without a subprocess (R9)",
    exec.calls.filter((c) => c.args[0] === "repo" && c.args[2] === "them/upstream").length,
    parentCallsAfterFirst,
  );
}

// R9: when the parent's own verdict cannot be cached (indeterminate results
// are never cached), the fork itself still comes from cache while the
// parent is re-probed every time — the invocation counts must diverge.
{
  const exec = boundedStub((command, args) => {
    if (command === "gh" && args[0] === "api") return execResult({ stdout: "tester\n" });
    if (args[2] === "me/fork2") {
      return execResult({
        stdout: JSON.stringify({ viewerPermission: "ADMIN", isFork: true, parent: { name: "upstream2", owner: { login: "them" } } }),
      });
    }
    return execResult({ code: 1, stderr: "boom" });
  });
  const prober = createProber({ exec, now: () => 0, cacheTtlMs: 1000 });
  const fork2Ref: RepoRef = { host: "github.com", hostKind: "github", path: "me/fork2" };

  await prober.evaluate([fork2Ref]);
  const forkFirst = exec.calls.filter((c) => c.args[0] === "repo" && c.args[2] === "me/fork2").length;
  const parentFirst = exec.calls.filter((c) => c.args[0] === "repo" && c.args[2] === "them/upstream2").length;

  await prober.evaluate([fork2Ref]);
  eq(
    "U3 cached fork itself is not re-probed on the second call (R9)",
    exec.calls.filter((c) => c.args[0] === "repo" && c.args[2] === "me/fork2").length,
    forkFirst,
  );
  check(
    "U3 fork parent is re-probed on the second call because indeterminate is never cached (R9)",
    exec.calls.filter((c) => c.args[0] === "repo" && c.args[2] === "them/upstream2").length > parentFirst,
  );
}

// R9: a cached non-fork must never grow a phantom parent — no other repo
// path is ever probed across repeated evaluate calls.
{
  const exec = ghBounded({ viewerPermission: "WRITE", isFork: false });
  const prober = createProber({ exec, now: () => 0, cacheTtlMs: 1000 });
  await prober.evaluate([githubRef]);
  await prober.evaluate([githubRef]);
  const probedPaths = new Set(exec.calls.filter((c) => c.args[0] === "repo").map((c) => c.args[2]));
  eq("U3 cached non-fork verdict enqueues no parent probe (R9)", probedPaths.size, 1);
}

// R9: once the shared cacheTtlMs elapses, both hops are independently stale
// and both get re-probed.
{
  const exec = boundedStub((command, args) => {
    if (command === "gh" && args[0] === "api") return execResult({ stdout: "tester\n" });
    return args[2] === "me/fork3"
      ? execResult({ stdout: JSON.stringify({ viewerPermission: "ADMIN", isFork: true, parent: { name: "upstream3", owner: { login: "them" } } }) })
      : execResult({ stdout: JSON.stringify({ viewerPermission: "READ", isFork: false }) });
  });
  let clock = 0;
  const prober = createProber({ exec, now: () => clock, cacheTtlMs: 1000 });
  const fork3Ref: RepoRef = { host: "github.com", hostKind: "github", path: "me/fork3" };

  await prober.evaluate([fork3Ref]);
  const forkFirst = exec.calls.filter((c) => c.args[0] === "repo" && c.args[2] === "me/fork3").length;
  const parentFirst = exec.calls.filter((c) => c.args[0] === "repo" && c.args[2] === "them/upstream3").length;

  clock = 1001;
  await prober.evaluate([fork3Ref]);
  check(
    "U3 fork is re-probed after cacheTtlMs elapses (R9)",
    exec.calls.filter((c) => c.args[0] === "repo" && c.args[2] === "me/fork3").length > forkFirst,
  );
  check(
    "U3 fork parent is re-probed after cacheTtlMs elapses (R9)",
    exec.calls.filter((c) => c.args[0] === "repo" && c.args[2] === "them/upstream3").length > parentFirst,
  );
}
eq(
  "U3 fork parent failing validation is indeterminate (R15)",
  (await verdictFor(githubRef, ghBounded({ viewerPermission: "ADMIN", isFork: true, parent: { nameWithOwner: "../../etc" } }))).verdict,
  "indeterminate",
);
{
  const exec = ghBounded({ viewerPermission: "WRITE", isFork: false });
  const prober = createProber({ exec, now: () => 0, cacheTtlMs: 1000 });
  await prober.evaluate([githubRef]);
  const first = exec.calls.filter((c) => c.args[0] === "repo").length;
  await prober.evaluate([githubRef]);
  eq("U3 managed verdict is cached", exec.calls.filter((c) => c.args[0] === "repo").length, first);
}
{
  const exec = ghBounded({}, { repoFailure: { code: 1, stderr: "boom" } });
  const prober = createProber({ exec, now: () => 0, cacheTtlMs: 1000 });
  await prober.evaluate([githubRef]);
  const first = exec.calls.filter((c) => c.args[0] === "repo").length;
  await prober.evaluate([githubRef]);
  check("U3 indeterminate is never cached", exec.calls.filter((c) => c.args[0] === "repo").length > first);
}
{
  const exec = ghBounded({ viewerPermission: "WRITE", isFork: false });
  let clock = 0;
  const prober = createProber({ exec, now: () => clock, cacheTtlMs: 1000 });
  await prober.evaluate([githubRef]);
  const first = exec.calls.filter((c) => c.args[0] === "repo").length;
  clock = 5000;
  await prober.evaluate([githubRef]);
  check("U3 cached verdict expires with the TTL (R16)", exec.calls.filter((c) => c.args[0] === "repo").length > first);
}
{
  // R16: once the shared identity entry expires and a re-probe resolves to
  // a different login, the verdict cached under the old login is
  // unreachable — the cache key is identity-bound, not merely TTL-bound —
  // so a fresh probe runs rather than serving a stale answer for the wrong
  // identity. Under the clamp, identity and a same-call verdict always
  // share one expiry, so this is what R16 now promises (plan KTD3).
  let login = "alice";
  const exec = boundedStub((command, args) =>
    command === "gh" && args[0] === "api"
      ? execResult({ stdout: `${login}\n` })
      : execResult({ stdout: JSON.stringify({ viewerPermission: "WRITE", isFork: false }) }),
  );
  let clock = 0;
  const prober = createProber({ exec, now: () => clock, cacheTtlMs: 1000 });
  await prober.evaluate([githubRef]);
  const first = exec.calls.filter((c) => c.args[0] === "repo").length;
  clock = 1000; // the shared identity entry has just expired
  login = "bob";
  await prober.evaluate([githubRef]);
  check(
    "U3 identity change invalidates the cached verdict (R16)",
    exec.calls.filter((c) => c.args[0] === "repo").length > first,
  );
}

// R6: within one verdict TTL window, a second evaluate call for the same
// repository must not pay a second identity subprocess.
{
  const exec = ghBounded({ viewerPermission: "WRITE", isFork: false });
  const prober = createProber({ exec, now: () => 0, cacheTtlMs: CONFIG.cacheTtlMs });
  await prober.evaluate([githubRef]);
  await prober.evaluate([githubRef]);
  eq(
    "U3 identity subprocess runs once for two evaluate calls within one verdict TTL (R6)",
    exec.calls.filter((c) => c.args[0] === "api").length,
    1,
  );
}

// R6, KTD3: two repositories on one host share one identity entry. Probing
// B after A must not pay a second identity subprocess while that shared
// entry is still alive. This is the case a naive per-repo verdict TTL
// misses: the identity cache is keyed per host while the verdict cache is
// keyed per repository, so B's own verdict, if left unclamped, would
// outlive the shared identity — and hitting B again in that window would
// pay a wasted identity subprocess just to serve a now-stale verdict. The
// clamp forces "a live verdict always has a live identity", so once the
// shared identity dies, B's verdict dies with it and the next call gets an
// honest, fresh probe instead of a stale hit riding a refreshed identity.
{
  const exec = ghBounded({ viewerPermission: "WRITE", isFork: false });
  let clock = 0;
  const prober = createProber({ exec, now: () => clock, cacheTtlMs: CONFIG.cacheTtlMs });
  const repoA: RepoRef = { host: "github.com", hostKind: "github", path: "o/repoA" };
  const repoB: RepoRef = { host: "github.com", hostKind: "github", path: "o/repoB" };

  await prober.evaluate([repoA]);
  clock = 1000;
  await prober.evaluate([repoB]);
  eq(
    "U3 identity subprocess runs once across two repos on one host (R6, KTD3)",
    exec.calls.filter((c) => c.args[0] === "api").length,
    1,
  );

  // B was written at clock=1000, so an unclamped design would keep it alive
  // until 1000 + cacheTtlMs. The shared identity (created for A at clock=0)
  // dies at exactly cacheTtlMs instead — earlier. Hit B here, past the
  // identity's death but still inside B's own naive window: the clamp must
  // not serve that stale verdict.
  const repoBCallsBeforeThird = exec.calls.filter((c) => c.args[0] === "repo" && c.args[2] === "o/repoB").length;
  clock = CONFIG.cacheTtlMs;
  await prober.evaluate([repoB]);
  check(
    "U3 two repos on one host, load-bearing: B is re-probed once the shared identity expires, even though B's own naive TTL has not (R6, KTD3)",
    exec.calls.filter((c) => c.args[0] === "repo" && c.args[2] === "o/repoB").length > repoBCallsBeforeThird,
  );
}

// R6, KTD3: the clamp's deliberate cost, asserted directly. B's verdict,
// written well after A seeded the shared identity, is clamped to die with
// that identity rather than living a full cacheTtlMs of its own. It is
// still served right up to the identity's expiry, and not one tick past it.
{
  const exec = ghBounded({ viewerPermission: "WRITE", isFork: false });
  let clock = 0;
  const prober = createProber({ exec, now: () => clock, cacheTtlMs: CONFIG.cacheTtlMs });
  const repoC: RepoRef = { host: "github.com", hostKind: "github", path: "o/repoC" };
  const repoD: RepoRef = { host: "github.com", hostKind: "github", path: "o/repoD" };

  await prober.evaluate([repoC]); // seeds the shared identity at clock=0
  clock = 200_000;
  await prober.evaluate([repoD]); // D's own naive TTL would run to 500_000
  const repoDCallsAfterWrite = exec.calls.filter((c) => c.args[0] === "repo" && c.args[2] === "o/repoD").length;

  clock = CONFIG.cacheTtlMs - 1; // one tick before the shared identity dies
  await prober.evaluate([repoD]);
  eq(
    "U3 clamped verdict is still served right up to the identity's expiry (R6, KTD3)",
    exec.calls.filter((c) => c.args[0] === "repo" && c.args[2] === "o/repoD").length,
    repoDCallsAfterWrite,
  );

  clock = CONFIG.cacheTtlMs; // the shared identity's exact expiry
  await prober.evaluate([repoD]);
  check(
    "U3 clamp truncates the verdict at the identity's expiry, short of its own naive cacheTtlMs (R6, KTD3)",
    exec.calls.filter((c) => c.args[0] === "repo" && c.args[2] === "o/repoD").length > repoDCallsAfterWrite,
  );
}

// R6, KTD3: the clamp can only shorten a verdict's life relative to a plain
// now() + cacheTtlMs, never lengthen it. A repository probed for the first
// time on a fresh host establishes its own identity in the same call, so
// the clamp is a no-op there: the verdict lives the full cacheTtlMs, no
// more and no less — `min(now() + cacheTtlMs, identityEntry.expiresAt)`
// picks the identity side only when it is strictly earlier.
{
  const exec = ghBounded({ viewerPermission: "WRITE", isFork: false });
  let clock = 0;
  const prober = createProber({ exec, now: () => clock, cacheTtlMs: CONFIG.cacheTtlMs });
  const repoE: RepoRef = { host: "github.com", hostKind: "github", path: "o/repoE" };

  await prober.evaluate([repoE]);
  const callsAfterFirst = exec.calls.filter((c) => c.args[0] === "repo").length;

  clock = CONFIG.cacheTtlMs - 1;
  await prober.evaluate([repoE]);
  eq(
    "U3 clamp does not shorten a verdict below its own cacheTtlMs (R6, KTD3)",
    exec.calls.filter((c) => c.args[0] === "repo").length,
    callsAfterFirst,
  );

  clock = CONFIG.cacheTtlMs;
  await prober.evaluate([repoE]);
  check(
    "U3 verdict is never served past now() + cacheTtlMs either (R6, KTD3)",
    exec.calls.filter((c) => c.args[0] === "repo").length > callsAfterFirst,
  );
}
{
  const exec = ghBounded({ viewerPermission: "WRITE", isFork: false });
  await verdictFor(gitlabRef, exec);
  const call = exec.calls.find((c) => c.command === "glab" && c.args.some((a) => a.startsWith("projects/")));
  check("U3 gitlab project path is URL-encoded with %2F", call?.args.includes("projects/g%2Fp") === true, JSON.stringify(exec.calls));
}
{
  const exec = ghBounded({ viewerPermission: "READ", isFork: false });
  await verdictFor(githubRef, exec);
  check("U3 every subprocess gets an argv array (R15)", exec.calls.every((c) => Array.isArray(c.args) && !c.command.includes(" ")));
}
{
  const exec = ghBounded({}, { repoFailure: { code: 1, stderr: `x${"y".repeat(400)}` } });
  const outcome = await verdictFor(githubRef, exec);
  check("U3 stderr in the detail is bounded", outcome.detail.length < 200, `len=${outcome.detail.length}`);
}

// ------------------------------------------------------------------ U4: reason

{
  const unmanaged = composeReason({ verdict: "unmanaged", detail: "viewerPermission=READ", repo: "o/r" }, false);
  check("U4 unmanaged reason names repo", unmanaged.includes("o/r"));
  check("U4 unmanaged reason names the probe outcome (R12)", unmanaged.includes("viewerPermission=READ"));
  check("U4 unmanaged reason carries the anti-retry sentence (R13)", unmanaged.includes("same gate"));
  eq("U4 repo named exactly once", unmanaged.split("o/r").length - 1, 1);

  const indeterminate = composeReason({ verdict: "indeterminate", detail: "gh exited 1", repo: "o/r" }, false);
  check("U4 indeterminate reason names the failure", indeterminate.includes("gh exited 1"));
  check("U4 indeterminate reason disclaims a permission verdict", indeterminate.includes("not a statement that you lack access"));

  const attended = composeReason({ verdict: "unmanaged", detail: "viewerPermission=READ", repo: "o/r" }, true);
  check("U4 attended reason tells the user, not the agent, to act (R14)", attended.includes("let them decide and act themselves"));
  check("U4 attended reason states consent cannot lift the gate", attended.includes("cannot be lifted by their answer"));
  check("U4 attended reason forbids a retry", attended.includes("Do not retry"));
  check("U4 attended reason omits the unattended fallback", !attended.includes("residual-record"));
  check("U4 unattended reason names the committed record (R14)", unmanaged.includes("residual-record"));
  check("U4 unattended reason omits the ask move", !unmanaged.includes("Tell the user what you would have filed"));
}

// ------------------------------------------------------------------- U5: guard

async function runGuard(command: string, exec: Exec, ctx: { hasUI?: boolean } = {}) {
  const handler = createGuard({ exec, now: () => 0, config: CONFIG });
  return await handler({ toolName: "bash", input: { command, cwd: "/work" } }, ctx);
}

{
  const blocked = await runGuard("gh issue create --repo other/repo -t x", ghStub({ viewerPermission: "READ", isFork: false }));
  check("U5 AE1 unmanaged create is blocked", blocked?.block === true);
  check("U5 AE1 reason names the repo", blocked?.reason.includes("other/repo") === true);
}

// -------------------------------------------------------------- U4: audit (R5)

type FakeAuditFs = {
  files: Record<string, string>;
  calls: { size: number; truncate: number; append: number };
  size: (path: string) => number;
  truncate: (path: string) => void;
  append: (path: string, line: string) => void;
};
function fakeAuditFs(initial: Record<string, string> = {}): FakeAuditFs {
  const files: Record<string, string> = { ...initial };
  const calls = { size: 0, truncate: 0, append: 0 };
  return {
    files,
    calls,
    size: (path) => {
      calls.size += 1;
      return files[path] ? Buffer.byteLength(files[path]) : 0;
    },
    truncate: (path) => {
      calls.truncate += 1;
      files[path] = "";
    },
    append: (path, line) => {
      calls.append += 1;
      files[path] = (files[path] ?? "") + line;
    },
  };
}
function auditLines(fs: FakeAuditFs, path: string): Record<string, unknown>[] {
  const raw = fs.files[path] ?? "";
  return raw
    .split("\n")
    .filter(Boolean)
    .map((line) => JSON.parse(line) as Record<string, unknown>);
}

const AUDIT_ON = { enabled: true, maxBytes: 1_048_576 };

// The audit path is derived from XDG_STATE_HOME at call time, so pin it to a
// value this suite controls and predict the same join() the production code
// computes; restored once every audit scenario below has run.
const previousXdgStateHome = process.env["XDG_STATE_HOME"];
process.env["XDG_STATE_HOME"] = "/urg-audit-test-state";
const AUDIT_PATH = "/urg-audit-test-state/unmanaged-repo-guard/blocks.jsonl";

{
  const auditFs = fakeAuditFs();
  const handler = createGuard({
    exec: ghStub({ viewerPermission: "READ", isFork: false }),
    now: () => 0,
    config: { ...CONFIG, auditLog: AUDIT_ON },
    auditFs,
  });
  await handler({ toolName: "bash", input: { command: "gh issue create --repo other/repo -t PRIVATE-TITLE-TEXT", cwd: "/work" } });
  const lines = auditLines(auditFs, AUDIT_PATH);
  check("U4 unmanaged block appends exactly one audit record (R5)", lines.length === 1, `got ${lines.length} lines`);
  const record = lines[0];
  eq("U4 unmanaged record names the tool (R5)", record?.["tool"], "bash");
  eq("U4 unmanaged record outcome is unmanaged (R5)", record?.["outcome"], "unmanaged");
  eq("U4 unmanaged record host is resolved (R5)", record?.["host"], "github.com");
  eq("U4 unmanaged record repo is resolved (R5)", record?.["repo"], "other/repo");
  check("U4 no record contains the command text (R5)", !JSON.stringify(auditFs.files).includes("PRIVATE-TITLE-TEXT"));
}

{
  const auditFs = fakeAuditFs();
  const handler = createGuard({
    exec: ghStub({ viewerPermission: "WRITE", isFork: false }),
    now: () => 0,
    config: { ...CONFIG, auditLog: AUDIT_ON },
    auditFs,
  });
  await handler({ toolName: "bash", input: { command: 'cd "$T" && gh issue create -t x', cwd: "/work" } });
  const lines = auditLines(auditFs, AUDIT_PATH);
  check("U4 invalid-target block appends one audit record (R5)", lines.length === 1, `got ${lines.length} lines`);
  const record = lines[0];
  eq("U4 invalid-target record outcome (R5)", record?.["outcome"], "invalid-target");
  eq("U4 invalid-target record host is null (R5)", record?.["host"], null);
  eq("U4 invalid-target record repo is null (R5)", record?.["repo"], null);
  eq("U4 invalid-target record detail is null (R5)", record?.["detail"], null);
  check(
    "U4 invalid-target record has a populated attempted field (R5)",
    typeof record?.["attempted"] === "string" && (record["attempted"] as string).length > 0,
  );
}

{
  const auditFs = fakeAuditFs();
  const handler = createGuard({
    exec: ghStub({}, { repoFailure: { code: 1 } }),
    now: () => 0,
    config: { ...CONFIG, auditLog: AUDIT_ON },
    auditFs,
  });
  await handler({ toolName: "bash", input: { command: "gh issue create --repo other/repo", cwd: "/work" } });
  const lines = auditLines(auditFs, AUDIT_PATH);
  check("U4 indeterminate block appends one audit record (R5)", lines.length === 1, `got ${lines.length} lines`);
  const record = lines[0];
  eq("U4 indeterminate record outcome (R5)", record?.["outcome"], "indeterminate");
  check(
    "U4 indeterminate record carries the probe detail (R5)",
    typeof record?.["detail"] === "string" && (record["detail"] as string).length > 0,
  );
}

{
  const auditFs = fakeAuditFs();
  const handler = createGuard({
    exec: ghStub({ viewerPermission: "WRITE", isFork: false }),
    now: () => 0,
    config: { ...CONFIG, auditLog: AUDIT_ON },
    auditFs,
  });
  const result = await handler({ toolName: "bash", input: { command: "gh issue create --repo other/repo -t x", cwd: "/work" } });
  eq("U4 allowed call appends nothing (R5)", result, undefined);
  check("U4 allowed call writes no audit line (R5)", auditLines(auditFs, AUDIT_PATH).length === 0);
}

{
  const throwingFs: FakeAuditFs = { ...fakeAuditFs(), append: () => {
    throw new Error("disk full");
  } };
  const handler = createGuard({
    exec: ghStub({ viewerPermission: "READ", isFork: false }),
    now: () => 0,
    config: { ...CONFIG, auditLog: AUDIT_ON },
    auditFs: throwingFs,
  });
  const result = await handler({ toolName: "bash", input: { command: "gh issue create --repo other/repo -t x", cwd: "/work" } });
  check(
    "U4 a throwing writer does not change the verdict or propagate (R5)",
    result?.block === true && result.reason.includes("other/repo"),
  );
}

{
  const auditFs = fakeAuditFs();
  const handler = createGuard({
    exec: ghStub({ viewerPermission: "READ", isFork: false }),
    now: () => 0,
    config: { ...CONFIG, auditLog: { enabled: false, maxBytes: 1_048_576 } },
    auditFs,
  });
  await handler({ toolName: "bash", input: { command: "gh issue create --repo other/repo -t x", cwd: "/work" } });
  check("U4 disabled audit writes nothing (R5)", Object.keys(auditFs.files).length === 0);
  check(
    "U4 disabled audit never touches the filesystem seam, so no path is resolved (R5)",
    auditFs.calls.size === 0 && auditFs.calls.truncate === 0 && auditFs.calls.append === 0,
  );
}

{
  const maxBytes = 200;
  const auditFs = fakeAuditFs({ [AUDIT_PATH]: "x".repeat(maxBytes) });
  const handler = createGuard({
    exec: ghStub({ viewerPermission: "READ", isFork: false }),
    now: () => 0,
    config: { ...CONFIG, auditLog: { enabled: true, maxBytes } },
    auditFs,
  });
  await handler({ toolName: "bash", input: { command: "gh issue create --repo other/repo -t x", cwd: "/work" } });
  check("U4 a full audit file is truncated before the new record (R5)", auditFs.calls.truncate === 1);
  const lines = auditLines(auditFs, AUDIT_PATH);
  check(
    "U4 the new record survives truncation (R5)",
    lines.length === 1 && lines[0]?.["outcome"] === "unmanaged",
  );
}

process.env["XDG_STATE_HOME"] = previousXdgStateHome;

eq("U5 AE2 managed create passes", await runGuard("gh issue create --repo other/repo -t x", ghStub({ viewerPermission: "WRITE", isFork: false })), undefined);
check("U5 AE3 probe failure blocks", (await runGuard("gh issue create --repo other/repo", ghStub({}, { repoFailure: { code: 1 } })))?.block === true);
eq("U5 AE4 read against the same unmanaged repo passes", await runGuard("gh issue list --repo other/repo", ghStub({ viewerPermission: "READ", isFork: false })), undefined);
eq("U5 AE5 gh pr create passes", await runGuard("gh pr create --title x", ghStub({ viewerPermission: "READ", isFork: false })), undefined);
eq("U5 AE5 self-assignment carve-out passes (R6)", await runGuard("glab issue update 5 --assignee +alice", ghStub({ viewerPermission: "READ", isFork: false })), undefined);
{
  const forkStub = stubExec((command, args) => {
    if (command === "gh" && args[0] === "api") return execResult({ stdout: "tester\n" });
    return args[2] === "me/fork"
      ? execResult({ stdout: JSON.stringify({ viewerPermission: "ADMIN", isFork: true, parent: { name: "upstream", owner: { login: "them" } } }) })
      : execResult({ stdout: JSON.stringify({ viewerPermission: "READ", isFork: false }) });
  });
  check("U5 AE6 managed fork with unmanaged parent is blocked", (await runGuard("gh issue create --repo me/fork -t x", forkStub))?.block === true);
}
{
  const attended = await runGuard("gh issue create --repo other/repo", ghStub({ viewerPermission: "READ", isFork: false }), { hasUI: true });
  check("U5 AE7 attended reason routes to the user", attended?.reason.includes("let them decide and act themselves") === true);
  const unattended = await runGuard("gh issue create --repo other/repo", ghStub({ viewerPermission: "READ", isFork: false }), { hasUI: false });
  check("U5 AE7 unattended reason routes to the committed record", unattended?.reason.includes("residual-record") === true);
}
check("U5 AE9 issue comment blocked end to end (R4)", (await runGuard("gh issue comment 3 --repo other/repo -b x", ghStub({ viewerPermission: "READ", isFork: false })))?.block === true);
check(
  "U5 AE10 no --repo resolves origin and blocks (R9)",
  (await runGuard("gh issue create -t x -b y", ghStub({ viewerPermission: "READ", isFork: false }, { origin: "git@github.com:other/repo.git" })))?.block === true,
);
check(
  "U5 cd-chained no --repo blocks on the cd-target's origin",
  (await runGuard("cd /elsewhere && gh issue create -t x", ghStub({ viewerPermission: "READ", isFork: false }, { origin: "git@github.com:other/repo.git" })))?.block === true,
);
check(
  "U5 unresolvable cd without --repo blocks",
  (await runGuard('cd "$T" && gh issue create -t x', ghStub({ viewerPermission: "WRITE", isFork: false }, { origin: "git@github.com:mine/repo.git" })))?.block === true,
);
{
  const handler = createGuard({
    exec: stubExec((command, args) =>
      command === "glab" && args.includes("user")
        ? execResult({ stdout: JSON.stringify({ username: "tester" }) })
        : execResult({ stdout: JSON.stringify({ permissions: { project_access: { access_level: 10 } } }) }),
    ),
    now: () => 0,
    config: CONFIG,
  });
  check("U5 mcp route is blocked, so coverage is not bash-only", (await handler({ toolName: "mcp__glab_issue_create", input: { project: "g/p", title: "x" } }, { hasUI: false }))?.block === true);
}
check(
  "U5 interpreter heredoc reaches the probe and blocks",
  (await runGuard("bash <<'EOF'\ngh issue create --repo other/repo\nEOF", ghStub({ viewerPermission: "READ", isFork: false })))?.block === true,
);
for (const [label, call] of [
  ["curl write", { toolName: "bash", input: { command: "curl -XPOST https://api.github.com/repos/other/repo/issues" } }],
  ["computer tool", { toolName: "computer", input: { code: "click(1,2)" } }],
  ["unmatched mcp name", { toolName: "mcp__foo_issue_open", input: { repo: "other/repo" } }],
  ["interpreter script file", { toolName: "bash", input: { command: "bash /tmp/filer.sh" } }],
] as const) {
  const handler = createGuard({ exec: ghStub({ viewerPermission: "READ", isFork: false }), now: () => 0, config: CONFIG });
  eq(`U5 accepted residual gap not covered: ${label}`, await handler(call, { hasUI: false }), undefined);
}

// -------------------------------------------------------------- U5: readConfig

{
  const tmp = `${process.env.XDG_RUNTIME_DIR ?? "."}/urg-manifest-test`;
  await Bun.$`mkdir -p ${tmp}`.quiet();
  const write = async (body: unknown) => {
    const path = `${tmp}/package.json`;
    await Bun.write(path, JSON.stringify(body));
    return path;
  };
  const validConfig = readConfig(await write({ unmanagedRepoGuard: { probeTimeoutMs: 5000, cacheTtlMs: 300000, auditLog: { enabled: true, maxBytes: 1048576 } } }));
  eq("U5 readConfig accepts a valid manifest", validConfig.probeTimeoutMs, 5000);
  eq("U4 readConfig returns auditLog.enabled (R5)", validConfig.auditLog.enabled, true);
  eq("U4 readConfig returns auditLog.maxBytes (R5)", validConfig.auditLog.maxBytes, 1048576);
  for (const [label, body] of [
    ["missing block", {}],
    ["missing key", { unmanagedRepoGuard: { probeTimeoutMs: 5000 } }],
    ["non-numeric", { unmanagedRepoGuard: { probeTimeoutMs: "5000", cacheTtlMs: 300000 } }],
    ["zero", { unmanagedRepoGuard: { probeTimeoutMs: 0, cacheTtlMs: 300000 } }],
    ["over range", { unmanagedRepoGuard: { probeTimeoutMs: 5000, cacheTtlMs: 3600001 } }],
  ] as const) {
    let threw = false;
    try {
      readConfig(await write(body));
    } catch {
      threw = true;
    }
    check(`U5 readConfig rejects ${label}`, threw);
  }
  for (const [label, body] of [
    ["auditLog.maxBytes missing", { unmanagedRepoGuard: { probeTimeoutMs: 5000, cacheTtlMs: 300000, auditLog: { enabled: true } } }],
    ["auditLog.maxBytes non-numeric", { unmanagedRepoGuard: { probeTimeoutMs: 5000, cacheTtlMs: 300000, auditLog: { enabled: true, maxBytes: "1048576" } } }],
    ["auditLog.maxBytes out of range", { unmanagedRepoGuard: { probeTimeoutMs: 5000, cacheTtlMs: 300000, auditLog: { enabled: true, maxBytes: 100 } } }],
    ["auditLog.enabled missing", { unmanagedRepoGuard: { probeTimeoutMs: 5000, cacheTtlMs: 300000, auditLog: { maxBytes: 1048576 } } }],
    ["auditLog.enabled non-boolean", { unmanagedRepoGuard: { probeTimeoutMs: 5000, cacheTtlMs: 300000, auditLog: { enabled: "true", maxBytes: 1048576 } } }],
  ] as const) {
    let threw = false;
    try {
      readConfig(await write(body));
    } catch {
      threw = true;
    }
    check(`U4 readConfig rejects ${label} (R5)`, threw);
  }
  await Bun.$`rm -rf ${tmp}`.quiet();
}

// ------------------------------------------------------------------- report

if (failures.length > 0) {
  console.error(`\nunmanaged-repo-guard: ${failures.length} failed, ${passed} passed\n`);
  for (const failure of failures) console.error(`  FAIL  ${failure}`);
  process.exit(1);
}
if (passed < EXPECTED_MIN_CHECKS) {
  console.error(`unmanaged-repo-guard: only ${passed} checks ran, expected at least ${EXPECTED_MIN_CHECKS} — a scenario was lost`);
  process.exit(1);
}
console.log(`unmanaged-repo-guard: ${passed} checks passed`);
