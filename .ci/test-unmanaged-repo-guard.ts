#!/usr/bin/env bun
/**
 * In-process behavior suite for the unmanaged-repo-guard omp extension.
 *
 * Covers plan units U1-U5 of
 * docs/plans/2026-08-05-006-feat-unmanaged-repo-issue-guard-plan.md, plus
 * R3-R6 of docs/plans/feedback-sweep-plan.md (ANSI-C quoting, its invariant
 * docs, the cheap verdict-cache hit, and the block-path audit log).
 * No network, no real `gh`/`glab`, no real git: every subprocess is stubbed.
 *
 * Run: bun .ci/test-unmanaged-repo-guard.ts
 */

import unmanagedRepoGuard, { createGuard, readConfig } from "../dot_local/share/omp-plugins/plugins/unmanaged-repo-guard/src/index.ts";
import { createAuditLog } from "../dot_local/share/omp-plugins/plugins/unmanaged-repo-guard/src/audit.ts";
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
const EXPECTED_MIN_CHECKS = 193;

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

const CONFIG = { probeTimeoutMs: 5000, cacheTtlMs: 300_000 };

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

// ------------------------------------------- R3: ANSI-C $'...' quoting (KTD6)

check(
  "R3 chained create after a $'...' search string classifies the real segment",
  asWrite(bash(`gh issue list --repo o/r --search $'it\\'s' ; gh issue create --repo other/repo`))?.repo ===
    "other/repo",
);
{
  const result = splitCommand(`echo $'a;b'`);
  eq("R3 a ; inside $'...' does not split the command", result.segments.length, 1);
}
{
  const result = splitCommand(`echo start $'a ; gh issue create --repo o/r`);
  eq("R3 unterminated $'...' sets unparseable", result.unparseable, true);
}
check(
  "R3 unterminated $'...' routes to fallbackScan",
  asWrite(bash(`echo start $'a ; gh issue create --repo o/r`))?.repo === "o/r",
);
{
  const result = splitCommand(`gh issue create --repo o/r -t 'a\\'; echo no`);
  eq("R3 backslash inside plain '...' stays literal (bash-matching)", result.unparseable, false);
  eq("R3 plain '...' still splits at the real ; that follows it", result.segments.length, 2);
}
check(
  "R3 $' inside a double-quoted string does not enter the ANSI-C state",
  asWrite(bash(`echo "abc$'def" ; gh issue create --repo o/r`))?.repo === "o/r",
);
{
  const result = splitCommand(`gh issue create --repo o/r -t $'\\\\' ; echo no`);
  eq("R3 an escaped backslash inside $'...' is consumed before the closing quote", result.unparseable, false);
  eq("R3 ...and the command still splits at the real ; that follows it", result.segments.length, 2);
}
{
  const cmd = `gh issue create --repo o/r -t $'it\\'s a test'`;
  const result = splitCommand(cmd);
  eq("R3 a properly-closed $'...' does not leave a quote open at EOF", result.unparseable, false);
  eq("R3 a properly-closed $'...' yields exactly one segment", result.segments.length, 1);
  eq("R3 the single segment's text is the whole command", result.segments[0]?.text, cmd);
}

// R3 regression: toArgv must agree with splitCommand's ANSI-C model. An
// earlier fix taught splitCommand `$'...'` but left toArgv on the 2-state

{
  const argv = toArgv(`gh issue create -t $'it\\'s a title'`);
  eq("R3 toArgv keeps an ANSI-C-quoted title as one token", argv.length, 5);
  eq("R3 toArgv does not split the ANSI-C string at the escaped quote or inner spaces", argv[4], "it's a title");
}
// --------------------------------------- R6: splitCommand invariant docs

{
  const source = await Bun.file(`${import.meta.dir}/../dot_local/share/omp-plugins/plugins/unmanaged-repo-guard/src/triggers.ts`).text();
  const match = /\/\*\*([\s\S]*?)\*\/\s*export function splitCommand/.exec(source);
  const doc = match?.[1] ?? "";
  check(
    "R6 splitCommand JSDoc documents the single-quote backslash invariant",
    /single-quoted strings/.test(doc) && /never inside plain/.test(doc),
  );
  check("R6 splitCommand JSDoc documents the argvHead substitution split", /argvHead/.test(doc));
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
  clock = 5000;
  login = "bob";
  await prober.evaluate([githubRef]);
  check("U3 identity change invalidates the cached verdict (R16)", exec.calls.filter((c) => c.args[0] === "repo").length > first);
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

// ---------------------------------------- R5: cheap verdict-cache hit (KTD8)

{
  const exec = ghBounded({ viewerPermission: "WRITE", isFork: false });
  let clock = 0;
  const prober = createProber({ exec, now: () => clock, cacheTtlMs: 1000 });
  const repoA = { host: "github.com", hostKind: "github" as const, path: "o/r5-a" };
  const repoB = { host: "github.com", hostKind: "github" as const, path: "o/r5-b" };
  await prober.evaluate([repoA]); // t=0: identity + verdictA cached, both expire at 1000
  clock = 500;
  await prober.evaluate([repoB]); // t=500: identity cache hit, verdictB set, expires at 1500
  clock = 1200; // identity entry (expiry 1000) now expired; verdictB (expiry 1500) still fresh
  const identityCallsBefore = exec.calls.filter((c) => c.command === "gh" && c.args[0] === "api").length;
  const repoCallsBefore = exec.calls.filter((c) => c.command === "gh" && c.args[0] === "repo").length;
  const outcome = await prober.evaluate([repoB]);
  eq("R5 expired identity + fresh verdict returns the cached verdict", outcome.verdict, "managed");
  eq(
    "R5 expired identity + fresh verdict spawns no identity subprocess",
    exec.calls.filter((c) => c.command === "gh" && c.args[0] === "api").length,
    identityCallsBefore,
  );
  eq(
    "R5 expired identity + fresh verdict spawns no repo-view subprocess",
    exec.calls.filter((c) => c.command === "gh" && c.args[0] === "repo").length,
    repoCallsBefore,
  );
}
{
  const exec = ghBounded({ viewerPermission: "WRITE", isFork: false });
  let clock = 0;
  const prober = createProber({ exec, now: () => clock, cacheTtlMs: 1000 });
  const ref = { host: "github.com", hostKind: "github" as const, path: "o/r5-c" };
  await prober.evaluate([ref]);
  clock = 5000; // both identity and verdict TTLs (1000ms) have elapsed
  const identityCallsBefore = exec.calls.filter((c) => c.command === "gh" && c.args[0] === "api").length;
  await prober.evaluate([ref]);
  check(
    "R5 identity and verdict both expired re-runs the identity subprocess",
    exec.calls.filter((c) => c.command === "gh" && c.args[0] === "api").length > identityCallsBefore,
  );
}
{
  const exec = ghBounded({ viewerPermission: "WRITE", isFork: false });
  const outcome = await verdictFor({ host: "github.com", hostKind: "github", path: "o/r5-cold" }, exec);
  eq("R5 cold cache still probes identity then repo", outcome.verdict, "managed");
  eq("R5 cold cache spawns exactly one identity subprocess", exec.calls.filter((c) => c.command === "gh" && c.args[0] === "api").length, 1);
  eq("R5 cold cache spawns exactly one repo subprocess", exec.calls.filter((c) => c.command === "gh" && c.args[0] === "repo").length, 1);
}
{
  let login = "alice";
  const exec = boundedStub((command, args) => {
    if (command === "gh" && args[0] === "api") return execResult({ stdout: `${login}\n` });
    return execResult({ stdout: JSON.stringify({ viewerPermission: login === "alice" ? "WRITE" : "READ", isFork: false }) });
  });
  let clock = 0;
  const prober = createProber({ exec, now: () => clock, cacheTtlMs: 1000 });
  const repoA = { host: "github.com", hostKind: "github" as const, path: "o/r5-d1" };
  const repoB = { host: "github.com", hostKind: "github" as const, path: "o/r5-d2" };
  await prober.evaluate([repoA]); // t=0, alice, managed; identity+verdictA expire at 1000
  clock = 500;
  await prober.evaluate([repoB]); // t=500, identity cache hit (alice), verdictB managed, expires at 1500
  clock = 1200; // identity (expiry 1000) now expired
  login = "bob"; // host access actually changed
  const identityCallsBefore = exec.calls.filter((c) => c.command === "gh" && c.args[0] === "api").length;
  const repoCallsBefore = exec.calls.filter((c) => c.command === "gh" && c.args[0] === "repo").length;
  const stale = await prober.evaluate([repoB]);
  eq("R5 identity change while verdict fresh still serves the old identity's verdict (KTD8 cost)", stale.verdict, "managed");
  eq(
    "R5 identity change while verdict fresh spawns no identity subprocess",
    exec.calls.filter((c) => c.command === "gh" && c.args[0] === "api").length,
    identityCallsBefore,
  );
  eq(
    "R5 identity change while verdict fresh spawns no repo-view subprocess",
    exec.calls.filter((c) => c.command === "gh" && c.args[0] === "repo").length,
    repoCallsBefore,
  );

  clock = 1600; // > repoB's own verdict expiry (1500): the stale slot is finally gone
  const fresh = await prober.evaluate([repoB]);
  eq("R5 two different identities on one host do not share a verdict slot", fresh.verdict, "unmanaged");
  check(
    "R5 the new identity gets its own probe once the stale verdict truly expires",
    exec.calls.filter((c) => c.command === "gh" && c.args[0] === "api").length > identityCallsBefore,
  );
}
{
  const exec = ghBounded({}, { repoFailure: { code: 1, stderr: "boom" } });
  const prober = createProber({ exec, now: () => 0, cacheTtlMs: 1000 });
  const ref = { host: "github.com", hostKind: "github" as const, path: "o/r5-e" };
  await prober.evaluate([ref]);
  const first = exec.calls.filter((c) => c.args[0] === "repo").length;
  await prober.evaluate([ref]);
  check(
    "R5 an indeterminate outcome is never served by the fast path either (guard plan KTD3)",
    exec.calls.filter((c) => c.args[0] === "repo").length > first,
  );
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
  eq("U5 readConfig accepts a valid manifest", readConfig(await write({ unmanagedRepoGuard: { probeTimeoutMs: 5000, cacheTtlMs: 300000 } })).probeTimeoutMs, 5000);
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
  await Bun.$`rm -rf ${tmp}`.quiet();
}

// -------------------------------------------------------- R4: audit log (KTD7)

const GUARD_SRC_DIR = `${import.meta.dir}/../dot_local/share/omp-plugins/plugins/unmanaged-repo-guard/src`;
const GUARD_PLUGIN_DIR = `${import.meta.dir}/../dot_local/share/omp-plugins/plugins/unmanaged-repo-guard`;

/** Points XDG_STATE_HOME at a fresh scratch dir for the duration of `fn`. */
async function withScratchStateHome<T>(fn: (stateHome: string) => Promise<T>): Promise<T> {
  const dir = `${process.env.XDG_RUNTIME_DIR ?? "."}/urg-audit-test-${Math.random().toString(36).slice(2)}`;
  await Bun.$`mkdir -p ${dir}`.quiet();
  const prev = process.env.XDG_STATE_HOME;
  process.env.XDG_STATE_HOME = dir;
  try {
    return await fn(dir);
  } finally {
    process.env.XDG_STATE_HOME = prev;
    await Bun.$`rm -rf ${dir}`.quiet();
  }
}

function auditLines(text: string): string[] {
  return text
    .trim()
    .split("\n")
    .filter((l) => l.length > 0);
}

// A non-issue-write tool call never touches the audit seam (pass-through
// path stays allocation-free, plan KTD7).
{
  const calls: unknown[] = [];
  const handler = createGuard({
    exec: ghStub({ viewerPermission: "READ", isFork: false }),
    now: () => 0,
    config: CONFIG,
    auditAppend: (entry) => calls.push(entry),
  });
  await handler({ toolName: "computer", input: { code: "click(1,2)" } }, { hasUI: false });
  eq("R4 a non-issue-write tool call writes no audit entry", calls.length, 0);
}

// An unmanaged verdict writes exactly one JSON line with the expected keys.
await withScratchStateHome(async (stateHome) => {
  const blocked = await runGuard("gh issue create --repo other/repo -t x", ghStub({ viewerPermission: "READ", isFork: false }));
  check("R4 unmanaged verdict blocks", blocked?.block === true);
  const text = await Bun.file(`${stateHome}/unmanaged-repo-guard/audit.jsonl`).text();
  const lines = auditLines(text);
  eq("R4 unmanaged verdict writes exactly one audit line", lines.length, 1);
  const entry = JSON.parse(lines[0] ?? "{}");
  check(
    "R4 the audit line carries the expected keys",
    typeof entry.timestamp === "string" &&
      entry.tool === "bash" &&
      entry.path === "unmanaged-verdict" &&
      entry.verdict === "unmanaged" &&
      entry.repo === "other/repo" &&
      entry.hostKind === "github" &&
      entry.cli === "gh",
    JSON.stringify(entry),
  );
});

// A managed verdict writes nothing.
await withScratchStateHome(async (stateHome) => {
  const passed = await runGuard("gh issue create --repo other/repo -t x", ghStub({ viewerPermission: "WRITE", isFork: false }));
  eq("R4 managed verdict passes", passed, undefined);
  const exists = await Bun.file(`${stateHome}/unmanaged-repo-guard/audit.jsonl`).exists();
  check("R4 managed verdict writes no audit file", !exists);
});

// The unresolvable-target block writes a line tagged with that path.
await withScratchStateHome(async (stateHome) => {
  const blocked = await runGuard("gh issue create -t x -b y", ghStub({}));
  check("R4 unresolvable-target blocks", blocked?.block === true);
  const text = await Bun.file(`${stateHome}/unmanaged-repo-guard/audit.jsonl`).text();
  const entry = JSON.parse(auditLines(text)[0] ?? "{}");
  eq("R4 the unresolvable-target audit line is tagged with that path", entry.path, "unresolvable-target");
});

// The config-failure fail-closed handler writes a line: no rendered
// package.json exists in the raw source tree (only package.json.tmpl), so
// the real default export deterministically takes its catch branch.
await withScratchStateHome(async (stateHome) => {
  const errors: string[] = [];
  let handler: ((event: unknown, context?: unknown) => Promise<unknown>) | undefined;
  const pi = {
    exec: ghStub({ viewerPermission: "READ", isFork: false }),
    on: (_event: "tool_call", h: NonNullable<typeof handler>) => {
      handler = h;
    },
    logger: { error: (message: string) => errors.push(message) },
  };
  unmanagedRepoGuard(pi as never);
  check("R4 config-failure handler registered", handler !== undefined);
  const result = (await handler?.(
    { toolName: "bash", input: { command: "gh issue create --repo other/repo -t x", cwd: "/work" } },
    { hasUI: false },
  )) as { block?: boolean } | undefined;
  check("R4 config-failure fail-closed handler blocks", result?.block === true);
  check(
    "R4 config-failure logs the configuration error",
    errors.some((m) => m.includes("disabled by configuration error")),
  );
  const text = await Bun.file(`${stateHome}/unmanaged-repo-guard/audit.jsonl`).text();
  const entry = JSON.parse(auditLines(text)[0] ?? "{}");
  eq("R4 the config-failure handler writes a line tagged with that path", entry.path, "config-failure");
});

// The unwritable log location does not change the verdict: the block is
// still returned with its reason, and the failure is reported to the
// logger. The parent of XDG_STATE_HOME is a regular file, so directory
// creation fails on permissions-independent grounds (also fails for root).
{
  const scratchParent = `${process.env.XDG_RUNTIME_DIR ?? "."}/urg-audit-unwritable-${Math.random().toString(36).slice(2)}`;
  await Bun.$`mkdir -p ${scratchParent}`.quiet();
  const regularFile = `${scratchParent}/not-a-dir`;
  await Bun.write(regularFile, "not a directory");
  const prevXdg = process.env.XDG_STATE_HOME;
  process.env.XDG_STATE_HOME = `${regularFile}/state`;
  try {
    const errors: string[] = [];
    const handler = createGuard({
      exec: ghStub({ viewerPermission: "READ", isFork: false }),
      now: () => 0,
      config: CONFIG,
      logger: { error: (m) => errors.push(m) },
    });
    const blocked = await handler(
      { toolName: "bash", input: { command: "gh issue create --repo other/repo -t x", cwd: "/work" } },
      { hasUI: false },
    );
    check(
      "R4 an unwritable log location still returns the block with its reason",
      blocked?.block === true && typeof blocked.reason === "string" && blocked.reason.length > 0,
    );
    check(
      "R4 an unwritable log location reports the failure to the logger",
      errors.some((m) => m.includes("audit log append failed")),
    );
  } finally {
    process.env.XDG_STATE_HOME = prevXdg;
    await Bun.$`rm -rf ${scratchParent}`.quiet();
  }
}

// The production call site (index.ts's default export) supplies the logger:
// an audit-append failure reaches a logger the deployed wiring provides, not
// only one a test injects. A valid manifest is written temporarily so
// `createGuard` is reached with a real config, exercising the true
// production call site rather than the config-failure fallback above.
{
  const packageJsonPath = `${GUARD_PLUGIN_DIR}/package.json`;
  await Bun.write(packageJsonPath, JSON.stringify({ unmanagedRepoGuard: { probeTimeoutMs: 5000, cacheTtlMs: 300000 } }));
  try {
    const scratchParent = `${process.env.XDG_RUNTIME_DIR ?? "."}/urg-audit-prod-${Math.random().toString(36).slice(2)}`;
    await Bun.$`mkdir -p ${scratchParent}`.quiet();
    const regularFile = `${scratchParent}/not-a-dir`;
    await Bun.write(regularFile, "not a directory");
    const prevXdg = process.env.XDG_STATE_HOME;
    process.env.XDG_STATE_HOME = `${regularFile}/state`;
    try {
      const errors: string[] = [];
      let handler: ((event: unknown, context?: unknown) => Promise<unknown>) | undefined;
      const pi = {
        exec: ghStub({ viewerPermission: "READ", isFork: false }),
        on: (_event: "tool_call", h: NonNullable<typeof handler>) => {
          handler = h;
        },
        logger: { error: (message: string) => errors.push(message) },
      };
      unmanagedRepoGuard(pi as never);
      check("R4 production wiring registered a handler with a valid manifest", handler !== undefined);
      const result = (await handler?.(
        { toolName: "bash", input: { command: "gh issue create --repo other/repo -t x", cwd: "/work" } },
        { hasUI: false },
      )) as { block?: boolean } | undefined;
      check("R4 the production call site still blocks when the audit append fails", result?.block === true);
      check(
        "R4 the production call site's audit-append failure reaches the deployed logger",
        errors.some((m) => m.includes("audit log append failed")),
      );
    } finally {
      process.env.XDG_STATE_HOME = prevXdg;
      await Bun.$`rm -rf ${scratchParent}`.quiet();
    }
  } finally {
    await Bun.$`rm -f ${packageJsonPath}`.quiet();
  }
}

// Two sequential appends from separate appender instances both land without
// truncation (append mode). This is NOT a multi-process atomicity test — the
// 4 KB single-line bound that guards real concurrent omp processes is a
// design property of audit.ts, not something this in-process suite exercises.
await withScratchStateHome(async (stateHome) => {
  createAuditLog({}).block(
    { tool: "bash", path: "unmanaged-verdict", verdict: "unmanaged", repo: "o/r-a", host: "github.com", hostKind: "github", cli: "gh" },
    "reason a",
  );
  createAuditLog({}).block(
    { tool: "bash", path: "unmanaged-verdict", verdict: "unmanaged", repo: "o/r-b", host: "github.com", hostKind: "github", cli: "gh" },
    "reason b",
  );
  const text = await Bun.file(`${stateHome}/unmanaged-repo-guard/audit.jsonl`).text();
  const lines = auditLines(text);
  eq("R4 two separate appender instances both land without truncation", lines.length, 2);
  check(
    "R4 both lines from separate instances parse as JSON",
    lines.every((l) => {
      try {
        JSON.parse(l);
        return true;
      } catch {
        return false;
      }
    }),
  );
});

// Two sequential blocks append two lines rather than truncating the file.
await withScratchStateHome(async (stateHome) => {
  await runGuard("gh issue create --repo other/repo1 -t x", ghStub({ viewerPermission: "READ", isFork: false }));
  await runGuard("gh issue create --repo other/repo2 -t x", ghStub({ viewerPermission: "READ", isFork: false }));
  const text = await Bun.file(`${stateHome}/unmanaged-repo-guard/audit.jsonl`).text();
  eq("R4 two sequential blocks append two lines rather than truncating", auditLines(text).length, 2);
});

// A long field value is truncated so the emitted line stays under the bound.
await withScratchStateHome(async (stateHome) => {
  const longValue = "r".repeat(5000);
  createAuditLog({}).block(
    { tool: "bash", path: "unmanaged-verdict", verdict: "unmanaged", repo: longValue, host: longValue, hostKind: "github", cli: "gh" },
    "reason",
  );
  const text = await Bun.file(`${stateHome}/unmanaged-repo-guard/audit.jsonl`).text();
  const line = auditLines(text)[0] ?? "";
  check("R4 a long field value keeps the emitted line well under the 4KB bound", line.length < 4096, `len=${line.length}`);
  const entry = JSON.parse(line);
  check("R4 the long repo value was truncated", entry.repo.length < longValue.length);
});

// The seam is the only constructor: introduce a stray block construction
// outside audit.ts, confirm both gates (typecheck, literal grep) catch it,
// then restore and confirm both gates are clean again.
{
  const strayPath = `${GUARD_SRC_DIR}/_stray_block_test.ts`;
  const includeTs = "--include=*.ts";
  await Bun.write(
    strayPath,
    'import type { BlockResult } from "./audit.ts";\n\nexport const bogus: BlockResult = { block: true, reason: "nope" };\n',
  );
  try {
    const grepWithStray = await Bun.$`grep -rn "block: true" ${GUARD_SRC_DIR} ${includeTs}`.quiet().nothrow();
    const strayLines = grepWithStray.stdout.toString().split("\n").filter((l) => l.includes("_stray_block_test.ts"));
    check("R4 the literal grep finds the injected out-of-seam block", strayLines.length > 0);

    const tscResult = await Bun.$`packages/node_modules/.bin/tsc --noEmit -p .ci/tsconfig.unmanaged-repo-guard.json`.quiet().nothrow();
    check("R4 the nominal type rejects a block constructed outside audit.ts", tscResult.exitCode !== 0);
  } finally {
    await Bun.$`rm -f ${strayPath}`.quiet();
  }

  const grepClean = await Bun.$`grep -rln "block: true" ${GUARD_SRC_DIR} ${includeTs}`.quiet().nothrow();
  const cleanFiles = grepClean.stdout.toString().split("\n").filter((l) => l.trim() !== "");
  eq(
    "R4 no block: true literal remains outside audit.ts once restored",
    cleanFiles.filter((f) => !f.endsWith("/audit.ts")).length,
    0,
  );

  const tscClean = await Bun.$`packages/node_modules/.bin/tsc --noEmit -p .ci/tsconfig.unmanaged-repo-guard.json`.quiet().nothrow();
  check("R4 the tree typechecks cleanly again once restored", tscClean.exitCode === 0);
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
