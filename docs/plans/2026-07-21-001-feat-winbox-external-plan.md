---
artifact_contract: ce-unified-plan/v1
artifact_readiness: implementation-ready
execution: code
product_contract_source: ce-plan-bootstrap
title: "feat: add Winbox to chezmoi externals"
date: 2026-07-21
type: feat
depth: standard
---

# feat: Add Winbox to chezmoi externals

## Summary

Add MikroTik **WinBox 4.3** (the RouterOS management GUI) as a chezmoi external in
`.chezmoiexternals/system.toml`. The version is resolved at render time from
MikroTik's `LATEST.4` endpoint — the **same version-resolution pattern claude/codex
already use** (`output "curl"` against a vendor version source instead of a hardcoded
string). Per-platform assets are selected from `download.mikrotik.com/routeros/winbox/<version>/`:

- **linux** (`WinBox_Linux.zip`) → `archive-file`, extract the `WinBox` binary to `.local/bin/winbox`
- **windows amd64** (`WinBox_Windows.zip`) / **arm64** (`WinBox_Windows_arm64.zip`) → `archive-file`, extract `WinBox.exe` to `.local/bin/winbox.exe`
- **darwin** (`WinBox.dmg`) → `file`, staged to `.local/share/winbox/WinBox.dmg` (chezmoi cannot extract a `.dmg`; documented limitation)

This is a config/packaging change to a single source file. It follows the existing
externals idiom in the repo, so verification is render + install-smoke, not unit tests.

---

## Problem Frame

The repo provisions standalone tooling through grouped `.chezmoiexternals/*.toml` files,
each resolving its download URL (and often version) at chezmoi render time. WinBox is
currently absent. The user wants it added across all four MikroTik-published desktop
targets, with the version parsed dynamically from MikroTik rather than pinned to `4.3`,
mirroring how `claude` and `codex` resolve their versions.

**Constraints discovered during research:**

- WinBox is **not** a GitHub release, so `gitHubLatestRelease`/`gitHubReleaseAssetURL`
  helpers do not apply. This is exactly the claude-code situation (Anthropic downloads
  manifest) — resolve via `output "curl"`.
- `https://download.mikrotik.com/routeros/winbox/LATEST.4` returns the bare current
  version string (`4.3\n`) — a clean, parseable endpoint. Preferred over scraping the
  HTML download page.
- Archive layouts (verified by download+`unzip -l`):
  - `WinBox_Linux.zip` → `WinBox` (54 MB self-contained binary) + `assets/img/winbox.png`
  - `WinBox_Windows.zip` → `WinBox.exe` + `assets/img/winbox.png`
  - `WinBox_Windows_arm64.zip` → same shape as amd64 (assumed identical; download
    timed out during research — confirm at implementation via `unzip -l`)
  - `WinBox.dmg` → an Apple Disk Image; **chezmoi has no `.dmg` extraction type**.
- MikroTik Linux is published **x86_64 only** (download page says "Linux (64-bit)");
  there is no Linux arm64 build.
- No published per-file checksum sidecar at a predictable URL; like many existing
  externals here (ast-grep, buf, marksman, opencode, codex, aoe), WinBox relies on
  HTTPS transport integrity.

---

## Requirements

- **R1** — WinBox is declared as a chezmoi external in `.chezmoiexternals/system.toml`.
- **R2** — The version is resolved at render time from MikroTik's `LATEST.4` endpoint
  (`output "curl"`), not hardcoded, matching the claude/codex version-resolution idiom.
- **R3** — All four user-supplied assets are honored, each routed to the correct
  platform: `WinBox_Linux.zip` (linux), `WinBox.dmg` (darwin), `WinBox_Windows.zip`
  (windows amd64), `WinBox_Windows_arm64.zip` (windows arm64).
- **R4** — linux/windows externals extract the runnable binary to `.local/bin`; darwin
  stages the `.dmg` with a clear in-file comment on the manual-install limitation.
- **R5** — The change renders cleanly through `chezmoi execute-template` on linux with
  the standard scratch/stub harness, producing valid TOML with the version substituted.

---

## Key Technical Decisions

- **KTD1 — Version via `output "curl"` on `LATEST.4`, not HTML scraping.** The
  `.../winbox/LATEST.4` endpoint returns exactly `4.3`; parsing it is a one-liner and is
  stable across releases, unlike scraping `mikrotik.com/download/winbox`. This is the
  literal "same pattern as claude/codex" — claude fetches `downloads.claude.ai/.../latest`
  then a manifest; codex resolves a release tag; WinBox resolves `LATEST.4`. Trim the
  trailing newline (`| toString | trim`).
- **KTD2 — Add to `system.toml`, not a new file.** AGENTS.md fixes the grouped externals
  set to `{ai-agents,dev-tools,vcs,k8s,system,fonts}`; creating `winbox.toml` would
  violate it. WinBox is a host/network desktop utility → `system.toml` (alongside docker
  credential helpers, wakatime, prezto) is the closest fit.
- **KTD3 — `archive-file` with a single `path` for linux/windows.** The binary is
  self-contained; the bundled `assets/img/winbox.png` is a window-icon nicety, not a
  runtime dependency, so extracting just the executable keeps `.local/bin` clean and
  mirrors how `uv`, `aoe`, `opencode`, `wakatime-cli` are handled.
- **KTD4 — Lowercase `.local/bin/winbox` target name.** The in-archive member is `WinBox`
  / `WinBox.exe`; `archive-file` lets `targetPath` differ from `path`. Lowercase matches
  every other `.local/bin` entry in the repo and is easier to launch.
- **KTD5 — darwin stages the raw `.dmg` (`type = "file"`).** chezmoi cannot mount/extract
  a `.dmg`. Downloading it to `.local/share/winbox/WinBox.dmg` faithfully honors the
  user-supplied URL and gives a predictable staging path; auto-mounting the `.app` is a
  macOS-only `run_onchange` script, out of scope here (see Deferred).
- **KTD6 — No checksum block.** No stable MikroTik sidecar URL exists; consistent with
  the many sidecar-less externals already in the repo.

See Assumptions for the headless-resolved calls (container gate, linux arch gate).

---

## Assumptions

Pipeline (headless) run — the following inferred decisions were made without a blocking
confirmation and are recorded here for review:

- **A1 — Gate the WinBox block on `not container`.** Resolve facts via
  `includeTemplate "facts.tmpl"` (as `cli-proxy-api` does) and skip the whole block in
  real containers. A 54 MB desktop GUI has no purpose in a headless container and the
  repo already treats desktop provisioning as container-skipped. *If the user prefers the
  ungated claude/codex behavior, drop the guard.*
- **A2 — Gate the linux external on `eq .chezmoi.arch "amd64"`.** MikroTik ships no Linux
  arm64 build; installing the x86_64 binary on arm64 linux would place a non-runnable
  file. Skipping arm64 linux is the fail-safe choice.
- **A3 — The `WinBox_Windows_arm64.zip` inner layout matches the amd64 zip**
  (`WinBox.exe` at root). Confirm with `unzip -l` at implementation before finalizing
  `path`.

---

## Output shape (illustrative, directional — not implementation spec)

```gotemplate
{{- /* ---------- winbox (MikroTik RouterOS GUI; vendor version endpoint, not GitHub) ---------- */ -}}
{{- $facts := includeTemplate "facts.tmpl" . | fromYaml -}}
{{- if not $facts.container -}}
{{- $winboxVersion := output "curl" "-fsSL" "https://download.mikrotik.com/routeros/winbox/LATEST.4" | toString | trim -}}
{{- $winboxBase := printf "https://download.mikrotik.com/routeros/winbox/%s" $winboxVersion -}}

{{- if and (eq .chezmoi.os "linux") (eq .chezmoi.arch "amd64") }}
[winbox]
type = "archive-file"
url = '{{ printf "%s/WinBox_Linux.zip" $winboxBase }}'
path = 'WinBox'
targetPath = '.local/bin/winbox'
executable = true

{{- else if eq .chezmoi.os "windows" }}
{{- $winboxAsset := (eq .chezmoi.arch "arm64") | ternary "WinBox_Windows_arm64.zip" "WinBox_Windows.zip" }}
[winbox]
type = "archive-file"
url = '{{ printf "%s/%s" $winboxBase $winboxAsset }}'
path = 'WinBox.exe'
targetPath = '.local/bin/winbox.exe'
executable = true

{{- else if eq .chezmoi.os "darwin" }}
# chezmoi cannot extract a .dmg; stage the installer and mount/copy WinBox.app manually.
[winbox]
type = "file"
url = '{{ printf "%s/WinBox.dmg" $winboxBase }}'
targetPath = '.local/share/winbox/WinBox.dmg'
{{- end }}
{{- end }}
```

Framing: directional guidance for reviewers, not the literal bytes to paste. Confirm the
`ternary` helper is available in this chezmoi's sprig set; if not, use an
`{{- if eq .chezmoi.arch "arm64" }}…{{- else }}…{{- end }}` asset selection.

---

## Implementation Units

### U1. Add the WinBox external block to `system.toml`

**Goal:** Declare WinBox as a render-time-versioned external covering all four platforms.

**Requirements:** R1, R2, R3, R4 (partial), KTD1–KTD6, A1–A3.

**Dependencies:** none.

**Files:**
- `.chezmoiexternals/system.toml` (modify) — append the WinBox block after the `prezto`
  block; update the top-of-file summary comment (line ~1-4) to mention winbox.

**Approach:**
- Resolve `$winboxVersion` via `output "curl" "-fsSL" ".../winbox/LATEST.4" | toString | trim`.
- Build `$winboxBase` = `.../winbox/<version>`.
- Gate the whole block on `not (includeTemplate "facts.tmpl" . | fromYaml).container` (A1).
- Branch by `.chezmoi.os`:
  - linux + amd64 (A2): `archive-file`, `path = 'WinBox'`, `targetPath = '.local/bin/winbox'`, executable.
  - windows: select asset by arch (amd64 → `WinBox_Windows.zip`, arm64 → `WinBox_Windows_arm64.zip`), `path = 'WinBox.exe'`, `targetPath = '.local/bin/winbox.exe'`, executable.
  - darwin: `type = "file"`, `targetPath = '.local/share/winbox/WinBox.dmg'`, with a comment on the manual-install limitation (KTD5).
- Reuse the existing `$executableExtension` var already declared at the top of `system.toml` if it simplifies the windows/linux target naming; otherwise the explicit `.exe` branch is fine.

**Patterns to follow:**
- `.chezmoiexternals/ai-agents.toml` `claude` block (lines 5-36) — `output "curl"` version
  resolution from a vendor endpoint.
- `.chezmoiexternals/ai-agents.toml` `cli-proxy-api` block (lines 132-134) —
  `includeTemplate "facts.tmpl"` container gate.
- `.chezmoiexternals/dev-tools.toml` `uv`/`wasm-pack` blocks — `archive-file` with a
  single `path` extracting one binary to `.local/bin`.
- `.chezmoiexternals/system.toml` `marksman` block — per-OS `if/else if` asset branching.

**Execution note:** This is packaging/config. Prefer render + install-smoke verification
(U2) over unit tests. Confirm the arm64 windows zip layout (A3) with `unzip -l` before
finalizing its `path`.

**Test scenarios:** `Test expectation: none — config/packaging change; behavior is
verified by the render + smoke checks in U2.`

**Verification:** The block is present, gated, and per-OS branches select the correct
asset and target path; the top comment lists winbox.

### U2. Render + install smoke verification

**Goal:** Prove the template renders to valid, version-substituted TOML and (on this
linux host) the external installs a runnable binary.

**Requirements:** R5, R2, R3.

**Dependencies:** U1.

**Files:** none created — verification only.

**Approach:**
- Render with the repo's standard scratch/op-stub harness (AGENTS.md "Verification"),
  using the zsh chezmoi wrapper or `GITHUB_TOKEN="$(gh auth token)"`, `--source "$PWD"`:
  `chezmoi execute-template < .chezmoiexternals/system.toml` and confirm the winbox
  `[winbox]` section appears with the concrete version (e.g. `4.3`) substituted into the
  URL, valid TOML, correct `type`/`path`/`targetPath` for linux.
- Optional deeper smoke on this linux/amd64 host: run a scoped `chezmoi apply` (or
  `chezmoi cat`/dry-run) for the winbox external against a throwaway destination and
  confirm `.local/bin/winbox` lands as an executable ~54 MB file that reports a version
  (`winbox --version` if supported, else `file`/size check). Note GUI binaries may not
  run headless — a `file` + size + executable-bit check is sufficient smoke.
- Disclose that `output "curl"` fetches `LATEST.4` at render time (a network call on
  every apply, matching claude/codex).

**Execution note:** Smoke/runtime verification, not unit coverage.

**Test scenarios:** `Test expectation: none — verification unit; the render output and
installed-file checks are the proof.`

**Verification:** `execute-template` exits 0, emits valid TOML with the substituted
version and correct per-OS branch for linux; no other section of `system.toml` changed.

---

## Scope Boundaries

**In scope:** the WinBox external declaration in `system.toml`; render/version-resolution
using the vendor `LATEST.4` endpoint; linux + windows extraction and darwin `.dmg` staging.

### Deferred to Follow-Up Work

- **macOS `.app` installation.** A darwin-only `run_onchange` script to mount `WinBox.dmg`,
  copy `WinBox.app` into `~/Applications`, and detach — untestable on this linux host and
  out of the "add to externals" ask.
- **Desktop menu / `.desktop` launcher entry** for the linux binary (icon from the
  bundled `assets/img/winbox.png`).
- **Checksum verification** if MikroTik later publishes a stable per-file hash sidecar.

**Out of scope (not WinBox's identity here):** managing RouterOS devices, credentials, or
any WinBox configuration/session state.

---

## System-Wide Impact

- Single-file edit to `.chezmoiexternals/system.toml`; no script, data, or `/etc` changes.
- Adds one render-time network call (`curl LATEST.4`) per apply, consistent with the
  existing claude/codex/agy externals that already curl vendor manifests.
- No CI/`.chezmoiignore`/facts changes required (`system.toml` is already active and
  externals are not ignored).

---

## Sources & Research

- MikroTik download page — https://mikrotik.com/download/winbox (current stable 4.3, released 2026-07-20).
- Version endpoint — `https://download.mikrotik.com/routeros/winbox/LATEST.4` → `4.3`.
- Archive layouts verified locally via `curl` + `unzip -l` (linux/windows amd64 confirmed;
  windows arm64 assumed same shape, to be confirmed at implementation).
- Repo patterns: `.chezmoiexternals/ai-agents.toml` (`claude`, `codex`, `cli-proxy-api`),
  `.chezmoiexternals/dev-tools.toml` (`uv`, `wasm-pack`), `.chezmoiexternals/system.toml`
  (`marksman`, `wakatime-cli`).
- Repo conventions: `AGENTS.md` — grouped externals set, verification harness, container skips.
