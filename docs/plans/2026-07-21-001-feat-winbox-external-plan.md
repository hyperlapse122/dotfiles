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
`.chezmoiexternals/system.toml`, resolving the version at render time from MikroTik's
`LATEST.4` endpoint — the **same version-resolution pattern claude/codex use**
(`output "curl"` against a vendor version source instead of a hardcoded string).

Every platform lands the app in the **same folder**, `~/.local/share/winbox/`:

- **linux** (`WinBox_Linux.zip`, x86_64-only) → two `archive-file` externals (binary +
  `assets/img/winbox.png`) sharing one cached download, extracted into the folder; the
  binary is `executable`. A templated `.desktop` launcher makes it appear in the app menu.
- **windows** amd64 (`WinBox_Windows.zip`) / arm64 (`WinBox_Windows_arm64.zip`) → two
  `archive-file` externals (`WinBox.exe` + the icon), same as linux.
- **darwin** (`WinBox.dmg`) → `type = "file"` stages the disk image (chezmoi cannot
  extract a `.dmg`); a darwin-gated `run_onchange_after` script mounts it and copies
  `WinBox.app` into the same `~/.local/share/winbox/` folder.

The version is validated with a regex guard before URL construction (matching the
`jq`/`pi` externals). This is config/packaging work verified by render + install-smoke
(local `chezmoi apply` on linux + CI `apply --init` on fedora/ubuntu/macos/windows).

---

## Problem Frame

The repo provisions standalone tooling through grouped `.chezmoiexternals/*.toml` files,
each resolving its download URL (and often version) at chezmoi render time. WinBox is
absent. The user wants it added across all four MikroTik desktop targets, with the
version parsed dynamically (mirroring `claude`/`codex`), the **whole app extracted into a
folder** (the GUI loads its bundled `assets/img/winbox.png` at runtime, so a binary-only
extraction loses the icon), a **Linux `.desktop` launcher**, and a **consistent result on
windows and macOS**.

**Constraints verified during research (download + `unzip -l` + `chezmoi apply` test):**

- WinBox is **not** a GitHub release, so `gitHubLatestRelease`/`gitHubReleaseAssetURL`
  do not apply — resolve via `output "curl"` (the claude-code situation).
- `https://download.mikrotik.com/routeros/winbox/LATEST.4` returns the bare current
  version (`4.3\n`) — a clean, parseable endpoint. Preferred over HTML scraping.
- Archive layouts (all confirmed by extraction):
  - `WinBox_Linux.zip` → `WinBox` (ELF x86-64, mode `-rwxr-xr-x`) + `assets/img/winbox.png`
  - `WinBox_Windows.zip` → `WinBox.exe` (PE32+ x86-64) + `assets/img/winbox.png`
  - `WinBox_Windows_arm64.zip` → `WinBox.exe` (PE32+ **ARM64**) + `assets/img/winbox.png`
    — **confirmed** same root layout as amd64.
  - `WinBox.dmg` → a zlib-compressed Apple Disk Image; **chezmoi has no `.dmg` type**.
- `chezmoi type = "archive"` **preserves the archive's file modes** — verified by a local
  `chezmoi apply` test: `.local/share/winbox/WinBox` extracts as `-rwxr-xr-x`.
- MikroTik Linux is **x86_64 only** (no Linux arm64 build).
- No published per-file checksum sidecar; like many existing externals (ast-grep, buf,
  opencode, codex, aoe), WinBox relies on HTTPS transport integrity.

---

## Requirements

- **R1** — WinBox is declared as a chezmoi external in `.chezmoiexternals/system.toml`.
- **R2** — Version resolved at render time from `LATEST.4` (`output "curl"`), regex-guarded
  before use, not hardcoded — matching the claude/codex/jq/pi idioms.
- **R3** — All four assets are honored, routed per platform (linux; darwin; windows
  amd64 + arm64).
- **R4** — Every platform extracts the **whole app** into the same `~/.local/share/winbox/`
  folder (binary + `assets/`), not a bare binary.
- **R5** — Linux renders a `.desktop` launcher pointing at the extracted binary and icon.
- **R6** — macOS reaches parity: the staged `.dmg` is mounted and `WinBox.app` is copied
  into `~/.local/share/winbox/`.
- **R7** — The change renders cleanly through `chezmoi execute-template` and applies on
  linux; CI `apply --init` proves the fetch/extract on fedora/ubuntu/macos/windows.

---

## Key Technical Decisions

- **KTD1 — Version via `output "curl"` on `LATEST.4`, not HTML scraping.** One-line,
  stable across releases; the literal "same pattern as claude/codex." Trimmed and
  regex-guarded (`^[0-9]+\.[0-9]+`) with `fail`, matching the `jq`/`pi` externals so an
  unexpected 200 body fails loudly instead of building a malformed URL.
- **KTD2 — Add to `system.toml`, not a new file.** AGENTS.md fixes the grouped externals
  set; WinBox is a host/network desktop utility → `system.toml`.
- **KTD3 — Two `archive-file` externals (binary + icon) into `~/.local/share/winbox/`,
  not a single `type = "archive"`.** The GUI loads `assets/img/winbox.png` at runtime, so
  the icon must travel with the binary — but a `type = "archive"` external has no fixed
  target path, forcing chezmoi to download and extract the whole 20 MB zip just to
  enumerate its entries while building the target state, *even during an unrelated
  `apply --include=externals <other>`* (this broke the cli-proxy-api smoke with a MikroTik
  connection reset). Two `archive-file` externals sharing one cached download have explicit
  target paths (`WinBox` + `assets/img/winbox.png`), so the zip is fetched only when winbox
  itself is applied — the `ast-grep`/`sg` pattern. `executable = true` on the binary. A
  local filtered `chezmoi apply` confirmed both land correctly (`WinBox` `-rwxr-xr-x` +
  the PNG).
- **KTD4 — Consistent `~/.local/share/winbox/` target on every OS.** linux/windows extract
  there directly; macOS copies `WinBox.app` there. One predictable location everywhere.
- **KTD5 — macOS parity via a darwin-gated `run_onchange_after` script.** chezmoi can't
  extract a `.dmg`, so the external stages it and
  `.chezmoiscripts/00-tools/run_onchange_after_winbox-macos.sh.tmpl` mounts it
  (`hdiutil`), copies `WinBox.app`, and detaches. Placed in `00-tools` mirroring the `pi`
  post-external script. It embeds the resolved version so it re-runs on version bumps, and
  renders **empty on non-darwin / in containers** so chezmoi skips it. CI's macOS runner
  executes it for real.
- **KTD6 — Linux `.desktop` launcher as a templated dotfile.** `dot_local/share/`
  `applications/winbox.desktop.tmpl` with absolute `Exec`/`Icon`/`Path` (`.chezmoi.homeDir`),
  auto Linux-gated by the existing `dot_local/share/.chezmoiignore` (`applications` on
  non-linux). No Windows Start-Menu `.lnk` / macOS Launchpad alias (binary shortcut
  generation, out of scope — see Deferred).
- **KTD7 — No checksum block.** No stable MikroTik sidecar URL; consistent with the many
  sidecar-less externals in the repo.

See Assumptions for the headless-resolved gates (container, linux arch).

---

## Assumptions

Pipeline (headless) run — inferred decisions recorded for review:

- **A1 — Gate the WinBox external + macOS script on `not container`.** A 54 MB desktop GUI
  has no purpose in a headless container. *(The `.desktop` file follows the repo's existing
  OS-only gating for `applications/`, matching how `1password.desktop` behaves.)*
- **A2 — Gate the linux external on `eq .chezmoi.arch "amd64"`.** MikroTik ships no Linux
  arm64 build; skipping arm64 linux is the fail-safe choice.

---

## Output Structure

Result on every platform (extracted by the external; `WinBox.app` on macOS added by the
script):

```
~/.local/share/winbox/
├── WinBox                     # linux (ELF, executable)   OR
├── WinBox.exe                 # windows (PE32+)           OR
├── WinBox.app/                # macOS (copied from the mounted .dmg)
├── WinBox.dmg                 # macOS only (staged installer / version trigger)
└── assets/img/winbox.png      # linux/windows (bundled icon)

~/.local/share/applications/winbox.desktop   # linux launcher only
```

---

## Implementation Units

### U1. WinBox external block in `system.toml` (all platforms → one folder)

**Goal:** Declare the render-time-versioned external that extracts the whole app into
`~/.local/share/winbox/` on linux/windows and stages the `.dmg` on macOS.

**Requirements:** R1, R2, R3, R4, R7, KTD1–KTD4, KTD7, A1, A2.

**Dependencies:** none.

**Files:** `.chezmoiexternals/system.toml` (modify) — winbox block after `prezto`; update
the top-of-file summary comment.

**Approach:** resolve + regex-guard `$winboxVersion`; gate on `not container`; branch by OS:
linux+amd64 → two `archive-file` externals (`WinBox` + icon) → `.local/share/winbox/…`;
windows → two `archive-file` externals (`WinBox.exe` + icon), asset by arch; darwin →
`type=file` `WinBox.dmg` → `.local/share/winbox/WinBox.dmg`.

**Patterns to follow:** `ai-agents.toml` `claude` (curl version) and `cli-proxy-api`
(facts container gate); `system.toml` `marksman` (per-OS branching); `dev-tools.toml`
`ast-grep`/`sg` (two `archive-file` externals sharing one cached download).

**Execution note:** packaging/config — verify by render + install-smoke, not unit tests.

**Test scenarios:** `Test expectation: none — verified by U-wide render + apply smoke.`

**Verification:** `execute-template` emits valid TOML with the substituted version and the
correct per-OS branch; local `chezmoi apply` of the linux external yields
`.local/share/winbox/WinBox` (executable) + `assets/img/winbox.png`.

### U2. Render + install smoke verification

**Goal:** Prove render + real extraction across platforms.

**Requirements:** R7, R2, R3, R4.

**Dependencies:** U1, U3, U4.

**Files:** none — verification only.

**Approach:** render `system.toml`, the `.desktop` tmpl, and the macOS script via the
scratch/op-stub harness (macOS script must render **empty** on linux); local `chezmoi
apply` of the linux archive; rely on CI `apply --init` (fedora/ubuntu/macos/windows) for
the real cross-platform fetch/extract and the macOS `hdiutil` path.

**Test scenarios:** `Test expectation: none — verification unit.`

**Verification:** all renders valid; linux apply produces the executable + icon; CI green.

### U3. Linux `.desktop` launcher

**Goal:** Make WinBox launchable from the Linux application menu.

**Requirements:** R5, KTD6.

**Dependencies:** U1 (defines the install path).

**Files:** `dot_local/share/applications/winbox.desktop.tmpl` (create).

**Approach:** freedesktop entry with absolute `Exec`/`Icon`/`Path` under
`{{ .chezmoi.homeDir }}/.local/share/winbox`; `Categories=Network;RemoteAccess;`. Linux
gating is inherited from `dot_local/share/.chezmoiignore`.

**Patterns to follow:** existing `dot_local/share/applications/1password.desktop`,
`kde-color-picker.desktop`.

**Test scenarios:** `Covers R5. desktop-file-validate passes on the rendered entry.`

**Verification:** renders with substituted absolute paths; `desktop-file-validate` clean.

### U4. macOS `.dmg` extraction script (parity)

**Goal:** Copy `WinBox.app` out of the staged `.dmg` into `~/.local/share/winbox/` so
macOS matches linux/windows.

**Requirements:** R6, KTD5, A1.

**Dependencies:** U1 (stages the `.dmg`).

**Files:** `.chezmoiscripts/00-tools/run_onchange_after_winbox-macos.sh.tmpl` (create).

**Approach:** darwin-gated `run_onchange_after` (empty on non-darwin/container → skipped);
embeds the resolved version so it re-runs on bumps; `hdiutil attach -nobrowse` to a
`mktemp` mountpoint under `$TMPDIR`, `find` the `*.app`, `rm -rf` + `cp -R` into the dest,
`hdiutil detach` via an `EXIT` trap.

**Execution note:** untestable on the linux host; CI's `apply --init + internals (macos)`
runner executes it against the real dmg — the verification of record.

**Test scenarios:** `Covers R6. macOS CI apply mounts the dmg and lands
~/.local/share/winbox/WinBox.app without error.`

**Verification:** renders empty on linux; macOS CI apply exits 0 and the `.app` lands.

---

## Scope Boundaries

**In scope:** the winbox external; render-time version resolution; whole-app extraction to
`~/.local/share/winbox/` on all three OSes; the Linux `.desktop` launcher; the macOS
`.dmg` extraction script.

### Deferred to Follow-Up Work

- **Windows Start-Menu shortcut / macOS Launchpad alias** — binary `.lnk` / `/Applications`
  symlink generation (not text dotfiles); the extracted folder is the parity result today.
- **Checksum verification** if MikroTik later publishes a stable per-file hash sidecar.

**Out of scope (not WinBox's identity here):** managing RouterOS devices, credentials, or
WinBox session state.

---

## System-Wide Impact

- `.chezmoiexternals/system.toml` (modify), one new dotfile (`winbox.desktop.tmpl`), one
  new darwin script. No `/etc`, data, or facts changes.
- Adds one render-time network call (`curl LATEST.4`) per apply per surface (external +,
  on macOS, the script), consistent with the claude/codex/agy externals.
- No `.chezmoiignore` change needed — `applications/` is already Linux-gated and the macOS
  script self-gates by rendering empty elsewhere.

---

## Sources & Research

- MikroTik download page — https://mikrotik.com/download/winbox (stable 4.3, 2026-07-20).
- Version endpoint — `.../winbox/LATEST.4` → `4.3`.
- Archive layouts + `chezmoi archive` exec-bit preservation verified locally via `curl`,
  `unzip -l`, extraction, and a throwaway `chezmoi apply` test.
- Repo patterns: `ai-agents.toml` (`claude`, `codex`, `cli-proxy-api`, `pi` post-external
  script), `system.toml` (`marksman`), `fonts.toml` (`type=archive`),
  `dot_local/share/applications/*.desktop`, `dot_local/share/.chezmoiignore`.
- Repo conventions: `AGENTS.md` — grouped externals, script fingerprint/gating, container
  skips, verification harness.
