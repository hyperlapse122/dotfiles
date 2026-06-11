#!/usr/bin/env node
// CI guard: verify every dotbot `link:` source in the install*.yaml files
// resolves to a real path in the repo, so a broken `link:` source cannot ship
// silently. Invoked by .github/workflows/tooling.yml; also runnable manually:
//   node scripts/ci/check-dotbot-links.mjs [repoRoot]
// Ignored-source rule: a source that does not exist is treated as OK when git
// ignores it (`git check-ignore -q`) — those are generated-at-bootstrap
// artifacts (e.g. packages/*/dist/ built by `yarn build`) whose absence in a
// fresh checkout is expected. If git cannot run (not a git repo), the fallback
// is to report the missing source, so the non-git negative test still fails.
// Single-platform parity exception: this is a Node-only CI guard with no host
// shell behavior, so it intentionally has no `.ps1` mate — it runs on the Linux
// CI runner and anywhere Node is available.
import { existsSync, readFileSync } from "node:fs";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";
import { spawnSync } from "node:child_process";

const root = process.argv[2] ?? join(dirname(fileURLToPath(import.meta.url)), "..", "..");
const yamls = ["install.conf.yaml", "install.linux.yaml", "install.macos.yaml", "install.windows.yaml"];

// Non-path scalars that the line regexes might still capture.
const SKIP = /^(true|false|null|yes|no|glob|create|relink|force|path)$/i;

function isCandidate(v) {
  if (!v) return false;
  if (v.startsWith("~") || v.startsWith("/") || v.startsWith("http")) return false; // abs / home / URL
  return !SKIP.test(v);
}

// True when git ignores `rel` (a repo-relative path). Generated artifacts are
// git-ignored, so their absence in a fresh checkout is expected, not a bug.
function gitIgnored(rel) {
  const r = spawnSync("git", ["-C", root, "check-ignore", "-q", "--", rel], { stdio: "ignore" });
  return r.status === 0; // 0 = ignored; 1 = not ignored; >1 / null = git unavailable
}

// A source is OK if it exists, or (when missing) if git ignores it. Glob sources
// resolve against the parent directory before the first glob segment.
function sourceOk(src) {
  let rel = src;
  if (src.includes("*") || src.includes("{")) {
    const segs = src.split("/");
    const i = segs.findIndex((s) => s.includes("*") || s.includes("{"));
    rel = segs.slice(0, i).join("/") || ".";
  }
  return existsSync(join(root, rel)) || gitIgnored(rel);
}

const missing = [];
for (const yaml of yamls) {
  const path = join(root, yaml);
  if (!existsSync(path)) continue;
  for (const line of readFileSync(path, "utf8").split("\n")) {
    const m = line.match(/^\s+~[^:]+:\s+(\S+)\s*$/) || line.match(/^\s+path:\s+(\S+)\s*$/);
    if (!m || !isCandidate(m[1])) continue;
    if (!sourceOk(m[1])) missing.push(`${yaml}: ${m[1]}`);
  }
}

if (missing.length) {
  console.error("Missing dotbot link sources:");
  for (const entry of missing) console.error(`  ${entry}`);
  process.exit(1);
}
console.log("dotbot-links-ok");
