---
artifact_contract: ce-unified-plan/v1
artifact_readiness: implementation-ready
execution: code
product_contract_source: ce-plan-bootstrap
title: "feat: add agent-browser to chezmoi externals"
date: 2026-07-21
type: feat
depth: lightweight
---

# feat: Add agent-browser to chezmoi externals

## Summary

Add **agent-browser** (vercel-labs/agent-browser — "Browser automation CLI for AI
agents", a Rust single-file binary) as a chezmoi external in
`.chezmoiexternals/ai-agents.toml`, alongside `claude` and `codex`. Track the newest
GitHub release at render time (**like claude/codex**), select the right per-platform
asset (`agent-browser-<os>-<arch>`, with a glibc-vs-musl split on linux **mirroring the
`claude` entry**), and pin the download with an **sha256 checksum read from the GitHub
REST API asset `digest`** — the same technique the reviewed
`.chezmoitemplates/cli-proxy-api-panel-ref.tmpl` already uses, because this release ships
**no checksums sidecar** and chezmoi's go-github version does not expose the asset digest
to `gitHubLatestRelease`.

The binary lands on `PATH` at `~/.local/bin/agent-browser` (`.exe` on Windows) as a bare
`type = "file"` external — the `marksman` shape, since agent-browser is one
self-contained executable with no sibling runtime files. This is config/packaging work,
verified by cross-platform `chezmoi execute-template` render + a real fetch/apply smoke on
the linux host and CI `apply --init`.

The user referenced release **v0.32.3** to reveal the asset layout; the entry itself tracks
**latest** (see Assumptions).

---

## Problem Frame

The repo provisions standalone agent CLIs through `.chezmoiexternals/ai-agents.toml`, each
resolving its download URL (and usually its version) at chezmoi render time. agent-browser
is absent. The user wants it added "like claude, codex" — i.e. a render-time-versioned
GitHub-release external in that same grouped file.

**Constraints verified during research (`gh release view`, GitHub REST API, and
`chezmoi execute-template` on this host):**

- agent-browser **is** a GitHub release (vercel-labs/agent-browser), so
  `gitHubLatestRelease` / `gitHubReleaseAssetURL` apply — unlike the claude-code /
  winbox `output "curl"` vendor-manifest situation.
- v0.32.3 assets are **bare binaries** (`application/octet-stream`, not archives, not
  gzipped), named `agent-browser-<os>-<arch>`:
  - os segment: `darwin`, `linux`, `win32`  (i.e. `.chezmoi.os` windows → `win32`)
  - arch segment: `x64`, `arm64`  (i.e. `.chezmoi.arch` amd64 → `x64`, arm64 unchanged)
  - linux ships **both** `agent-browser-linux-<arch>` (glibc) **and**
    `agent-browser-linux-musl-<arch>` (static musl) — the same glibc/musl fork the
    `claude` entry already handles with an `ldd /bin/ls | grep musl` probe.
  - windows ships **only** `agent-browser-win32-x64.exe` (with the `.exe` suffix; no
    win32-arm64 build).
- There is **no checksums sidecar** (no `SHA256SUMS`, no per-asset `.sha256`). The only
  machine-readable hash is the GitHub REST API asset `digest` field
  (`"digest": "sha256:<hex>"`), confirmed present on every asset.
- chezmoi **v2.71.0**'s bundled go-github does **not** expose `Digest` on the
  `gitHubLatestRelease` asset struct (`can't evaluate field Digest in type
  *github.ReleaseAsset`), so the digest must be read from the REST API separately — the
  exact situation `cli-proxy-api-panel-ref.tmpl` solves.
- These agent-CLI externals are **not** container-gated (claude/codex/opencode/pi/
  codegraph/aoe are all fetched inside containers — "the agent CLIs are first-class
  here"), so no `.chezmoiignore` change and no container gate are needed.

---

## Requirements

- **R1** — agent-browser is declared as a chezmoi external in
  `.chezmoiexternals/ai-agents.toml` (not a new file), alongside claude/codex.
- **R2** — The release version is resolved at render time from the latest GitHub release
  (not hardcoded), matching the claude/codex idiom.
- **R3** — The correct asset is selected per platform: darwin/linux/windows × x64/arm64,
  with the linux glibc-vs-musl split resolved by the same probe the `claude` entry uses.
- **R4** — The download is checksum-pinned with the sha256 taken from the GitHub REST API
  asset `digest`, regex-guarded, and fail-closed when the asset is missing/ambiguous.
- **R5** — The binary is installed executable on `PATH` at `~/.local/bin/agent-browser`
  (`.exe` on Windows).
- **R6** — The change renders cleanly through `chezmoi execute-template` on linux (glibc
  **and** musl branch), darwin, and windows, and a real fetch/apply lands a runnable
  binary on the linux host; CI `apply --init` proves the cross-platform fetch.

---

## Key Technical Decisions

- **KTD1 — Add to `ai-agents.toml`, not a new file.** AGENTS.md fixes the grouped
  externals set; agent-browser is an AI-agent CLI (`repo description: "Browser automation
  CLI for AI agents"`) and the user named claude/codex as the model, both of which live
  in `ai-agents.toml`. Place the block **after the `codex` block** so the leading
  claude → codex → agent-browser agent-CLI cluster stays together, and add
  `agent-browser` to the top-of-file summary comment (line 1).
- **KTD2 — Single atomic `releases/latest` REST call for both tag and digest.** One
  `output "sh" "-c" (curl … https://api.github.com/repos/vercel-labs/agent-browser/releases/latest)`
  → `fromJson`, reading `tag_name` **and** the matching asset's `digest` from the **same**
  snapshot. This is race-free (one view of "latest") and one network call — strictly
  better than `gitHubLatestRelease` (for the tag) plus a second API call for the digest,
  which could straddle a release publish. Build the optional `Authorization: Bearer` header
  from `env "GITHUB_TOKEN"` exactly as `cli-proxy-api-panel-ref.tmpl` does, so it is authed
  locally (zsh wrapper injects the token) and in CI (`GITHUB_TOKEN` set), and falls back to
  an unauthenticated call for a one-off local render. Build the download URL as a **plain
  `printf` string** — `printf "https://github.com/vercel-labs/agent-browser/releases/download/%s/%s" $tag $assetName`,
  the shape `cli-proxy-api-panel-ref.tmpl` uses (its final `url` field) — **not**
  `gitHubReleaseAssetURL`, which would fetch the release a second time and undo the
  one-call/race-free property. The `$tag` and `$assetName` are already validated (KTD3/KTD4)
  before they reach the URL, so the string build is safe.
- **KTD3 — Platform + musl asset selection mirrors the `claude` entry.**
  `$osName := replace "windows" "win32" (replace "linux" "linux" (replace "darwin" "darwin" .chezmoi.os))`
  (effectively windows→win32, else unchanged); `$arch := replace "amd64" "x64" .chezmoi.arch`
  (arm64 unchanged). On linux, run the established
  `ldd /bin/ls 2>&1 | grep -q musl; echo $?` probe and insert the `-musl` infix when it
  reports `0`. Append `$executableExtension` (`.exe` on windows) — so the windows asset
  name is `agent-browser-win32-x64.exe`. The `$executableExtension` helper is already
  defined at the top of `ai-agents.toml`.
- **KTD4 — Fail-closed digest match with regex guards, mirroring panel-ref.** Range the
  API assets, match `.name == $assetName`, `trimPrefix "sha256:" .digest`, and count
  matches; `fail` unless exactly one. Guard `$tag` with `^v[0-9]+\.[0-9]+\.[0-9]+$` and
  `$sha256` with `^[0-9a-f]{64}$` before emitting, so a shape change upstream fails the
  render loudly instead of writing a malformed external.
- **KTD5 — Bare `type = "file"` → `~/.local/bin/agent-browser`, executable.** The asset is
  a single self-contained binary (no sibling package files, unlike `pi`), so a direct
  `.local/bin` target — the `marksman` shape (a bare `type = "file"` binary; **not** `aoe`,
  which is a `type = "archive-file"` that extracts its binary from a tarball) — is correct;
  no `type = "archive"`, no `decompress`, and no post-external symlink/reconciler script.
  `.local/bin` is already on `PATH` (ast-grep, marksman, uv, aoe precedent). `[agent-browser.checksum] sha256`
  sub-table pins the bytes (the `claude` / `jq` / `agy` shape).
- **KTD6 — No container gate, no `.chezmoiignore` change.** Match claude/codex: these
  agent-CLI externals are fetched in containers too. (agent-browser drives a headless
  browser, so it is not desktop-only.)

---

## Assumptions

Pipeline (headless) run — inferred decisions recorded for review:

- **A1 — Track the latest release, not a pinned v0.32.3.** "Like claude, codex" — both
  track latest — and every GitHub-release entry in `ai-agents.toml` uses
  `gitHubLatestRelease`. The v0.32.3 link was read as the asset-layout reference, not a
  pin request. (If a pin is wanted instead, swap the `releases/latest` endpoint for
  `releases/tags/v0.32.3` and drop the tag regex to an equality check — a one-line change.)
- **A2 — Windows maps arch→x64 only in practice.** The release ships only
  `agent-browser-win32-x64.exe`; a hypothetical windows-arm64 host would compute a
  non-existent asset name and fail-close at the digest-match guard. Acceptable: the primary
  host is linux/amd64 and windows-arm64 is not a supported target here.

---

## Implementation Units

### U1. agent-browser external block in `ai-agents.toml`

**Goal:** Declare the render-time-versioned, checksum-pinned external that installs
`agent-browser` to `~/.local/bin/` for the current platform, and record it in the
file's summary comment.

**Requirements:** R1, R2, R3, R4, R5, R6; KTD1–KTD6; A1, A2.

**Dependencies:** none.

**Files:** `.chezmoiexternals/ai-agents.toml` (modify) — insert the `[agent-browser]`
block (with its `[agent-browser.checksum]` sub-table) after the `codex` block and before
the antigravity/`agy` comment; extend the line-1 summary comment to list `agent-browser`.

**Approach:**
1. Build `$authHeader` from `env "GITHUB_TOKEN"` (empty when unset); `output "sh" "-c"`
   curl `https://api.github.com/repos/vercel-labs/agent-browser/releases/latest` →
   `| fromJson` into `$api`.
2. `$tag := $api.tag_name | toString`; regex-guard `^v[0-9]+\.[0-9]+\.[0-9]+$` via `fail`.
3. Compute `$osName` (windows→win32, else identity), `$arch` (amd64→x64, arm64 identity);
   on linux run the `ldd /bin/ls | grep -q musl` probe and set a `-musl` infix on `0`.
   Assemble `$assetName := printf "agent-browser-%s%s-%s%s" $osName $muslInfix $arch $executableExtension`
   (musl infix only applies on linux; `$executableExtension` supplies `.exe` on windows).
4. Range `$api.assets`; on `.name == $assetName` set `$sha256 := trimPrefix "sha256:" .digest`
   and increment a counter; `fail` unless the counter is exactly `1`; regex-guard
   `$sha256` `^[0-9a-f]{64}$`.
5. Emit `[agent-browser]` — `type = "file"`, `url = printf
   "https://github.com/vercel-labs/agent-browser/releases/download/%s/%s" $tag $assetName`
   (a plain string build from the already-validated `$tag`/`$assetName`, **not**
   `gitHubReleaseAssetURL` — see KTD2), `targetPath =
   '.local/bin/agent-browser<$executableExtension>'`, `executable = true` — plus
   `[agent-browser.checksum]` `sha256 = '<$sha256>'`.

**Patterns to follow:** `ai-agents.toml` `claude` (platform + `ldd` musl probe + versioned
binary + `.checksum` sub-table) and `codex` (arch remap);
`.chezmoitemplates/cli-proxy-api-panel-ref.tmpl` (optional-auth `releases/latest` curl,
`fromJson`, asset-`digest` extraction, exactly-one-match `fail`, tag + sha256 regex guards,
and the `printf`-built release-download `url`); `dev-tools.toml` `marksman` (bare
`type = "file"` binary → `.local/bin`).

**Execution note:** packaging/config — verify by render + install smoke, not unit tests.

**Test scenarios:** `Test expectation: none — declarative external; verified by the render +
apply smoke below (no application code path to unit-test).`

**Verification:**
- `chezmoi execute-template` renders valid TOML with a concrete `tag`, the correct
  `$assetName`/URL, and a 64-hex `sha256` for each platform matrix cell:
  linux/amd64 **glibc** → `agent-browser-linux-x64`; linux/amd64 **musl** (force the probe)
  → `agent-browser-linux-musl-x64`; linux/arm64 → `agent-browser-linux-arm64`;
  darwin/arm64 → `agent-browser-darwin-arm64`; windows/amd64 →
  `agent-browser-win32-x64.exe`. The rendered `sha256` equals the API `digest` for that
  asset (cross-check against `gh release view --json assets`).
- Fail-closed check: a bogus `$assetName` (e.g. windows/arm64) makes the exactly-one-match
  guard `fail` rather than emit a checksum-less entry.
- Real smoke on this linux/amd64/glibc host: `chezmoi apply` (externals-scoped) fetches the
  binary to `~/.local/bin/agent-browser`, chezmoi's checksum verification passes, and
  `agent-browser --version` runs.
- CI `render-dotfiles.yml` + `apply --init` stay green across fedora/ubuntu/macos/windows.

---

## Scope Boundaries

**In scope:** the single `[agent-browser]` external (+ its checksum sub-table) in
`ai-agents.toml`; render-time latest-release version resolution; per-platform + musl asset
selection; API-digest sha256 pinning; the one-line summary-comment update.

### Deferred to Follow-Up Work

- **Shell completions / man pages** — not published as separate release assets; nothing to
  wire up.
- **Version pinning / a shared `agent-browser-ref.tmpl` partial** — unnecessary while a
  single external is the only consumer; extract a partial only if a script later needs the
  resolved version/checksum (the cli-proxy-api reason for its ref template).

**Out of scope (not agent-browser's identity here):** configuring or launching
agent-browser, managing its MCP/skill surface, or any browser-runtime provisioning.

---

## Risks & Trust Posture

These are documented risk acceptances, not blockers — each mirrors the reviewed
`cli-proxy-api-panel-ref.tmpl` pattern and/or the existing agent-CLI family posture. Noted
so the trade-offs are explicit rather than implied.

- **Third-party binary tracked at `latest`, auto-installed executable.** agent-browser is a
  vercel-labs project (not first-party to this repo), yet it is tracked at `latest` and
  placed executable on `PATH` (in containers too), so every apply adopts the newest upstream
  release without a human review gate — consistent with the rest of the agent-CLI family
  (claude/codex/opencode/pi/… all track latest). Accepted as the deliberate family posture;
  A1 documents the one-line swap to a reviewed pin (`releases/tags/v0.32.3`) if a
  review-per-bump posture is preferred later.
- **The API `digest` is not an integrity control independent of GitHub.** The pinned
  `sha256` is read from the same release object that serves the binary, so it guards the
  **download path** (transport corruption, wrong-asset mismatch) but not a poisoned upstream
  release — an actor who can publish/replace the asset also controls its `digest`. No
  independent checksum sidecar exists to close this. This is still a net gain over the
  HTTPS-transport-only baseline that several existing externals rely on.
- **`GITHUB_TOKEN` reaches `curl` via argv.** The optional auth header interpolates the
  token into the command string handed to `output "sh" "-c"` (panel-ref line 31 does the
  same), so the value is briefly present in the `sh`/`curl` process arguments during the
  fetch. Accepted because it mirrors the already-reviewed panel-ref pattern; locally this is
  the user's `gh` token on a single-user workstation, and CI masks its `GITHUB_TOKEN`.
- **Fail-closed on upstream asset changes (availability, not correctness).** If a future
  release renames assets or drops an asset's `digest`, the exactly-one-match / `sha256`
  regex guards `fail` the render, blocking apply until the entry is fixed or pinned — the
  intended fail-safe. The token-less local fallback also shares GitHub's 60 req/hr anonymous
  budget with the other GitHub calls in this file, so a one-off unauthenticated render could
  rate-limit; the normal `GITHUB_TOKEN` path avoids it.

---

## System-Wide Impact

- One file modified: `.chezmoiexternals/ai-agents.toml`. No `/etc`, `.chezmoidata`, facts,
  script, or `.chezmoiignore` changes.
- Adds one render-time network call per apply (the `releases/latest` REST fetch), authed
  via the existing `GITHUB_TOKEN` path — the same order of cost as the claude/codex/pi
  externals already incur, and the same optional-auth curl `cli-proxy-api-panel-ref.tmpl`
  already performs.
- Deployed in containers too (agent CLIs are first-class there); no new host/desktop
  surface.

---

## Sources & Research

- Release + assets — `gh release view v0.32.3 --repo vercel-labs/agent-browser`
  (7 bare-binary assets, each with an API `digest`); repo description "Browser automation
  CLI for AI agents" (Rust), latest release v0.32.3 (2026-07-19).
- Digest availability — confirmed chezmoi v2.71.0 `gitHubLatestRelease` does **not** expose
  `.Digest`, while a `releases/latest` REST curl → `fromJson` yields `tag_name` + per-asset
  `digest` (verified live via `chezmoi execute-template`).
- Repo patterns: `.chezmoiexternals/ai-agents.toml` (`claude` platform/musl/checksum,
  `codex` arch remap + `gitHubReleaseAssetURL`), `.chezmoitemplates/cli-proxy-api-panel-ref.tmpl`
  (optional-auth API digest fetch + guards), `.chezmoiexternals/dev-tools.toml`
  (`marksman` bare-binary `.local/bin` target), `.chezmoiignore` container block
  (agent CLIs kept), `docs/plans/2026-07-21-001-feat-winbox-external-plan.md` (sibling
  external-addition plan).
- Repo conventions: `AGENTS.md` — grouped externals ownership, render/apply verification
  harness, container skips.
