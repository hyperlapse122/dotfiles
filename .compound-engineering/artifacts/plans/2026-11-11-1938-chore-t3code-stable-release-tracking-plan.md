---
title: T3 Code Stable Release Tracking - Plan
type: chore
date: 2026-11-11
artifact_contract: ce-unified-plan/v1
product_contract_source: ce-plan-bootstrap
execution: code
---

# T3 Code Stable Release Tracking - Plan

## Goal Capsule

- **Objective:** Both machines run the latest stable T3 Code release (desktop app and CLI), and the scheduled dependency job keeps them on stable releases instead of moving them onto nightly builds.
- **Means:** Change the release selector in `scripts/t3code-release` to stable tags only (KTD1, KTD2), re-pin `packages/t3code-release.json` with the updated script (KTD3), and align the bundle name, descriptions, docs, and tests (KTD4).
- **Authority:** Issue #146 is the request of record. Repository instructions in `AGENTS.md` govern checks, commits, and the PR.
- **Execution profile:** One PR.
- **Stop conditions:** Stop if the latest stable release lacks a required asset or digest, if its Antigravity table cannot be read, or if the runtime rebuild check refuses it. Each of these leaves the pin without a verified stable release.
- **Finishes and ships:** The implementing agent opens the PR. The repository owner merges and switches hosts.

---

## Product Contract

### Summary

`scripts/t3code-release` picks the newest stable `v<major>.<minor>.<patch>` release that is neither a draft nor a prerelease. The pin moves from `0.1.9-nightly.20261110.4491` to stable `0.1.8`, with an `antigravity` section read from that release. Package descriptions, the macOS bundle name, docs, comments, and tests follow the stable track.

### Problem Frame

The flake cutover seeded the pin at stable `v0.1.7`, but `scripts/t3code-release` still selects only `-nightly.` prereleases. The first scheduled dependency run (#143) moved the pin onto `0.1.9-nightly.20261110.4491` instead of advancing to stable `v0.1.8`. The owner wants stable builds on both hosts. Nightly builds also ship a different signed macOS bundle (`T3 Code (Nightly).app`), so the Dock entry and app path change whenever the track flips.

### Requirements

**Release selection**

- R1. The updater selects the newest release whose tag is exactly `v<major>.<minor>.<patch>`, with `draft == false` and `prerelease == false`, ordered by the numeric semver tuple.
- R2. The updater ignores `-nightly.`, `-preview.`, `android-beta-*`, and any other tag that is not plain semver, as well as drafts and releases marked prerelease.
- R3. The updater refuses to replace a stable pin with an older stable release, and writes nothing when the resolved stable equals the pin and its `antigravity` section matches.
- R4. Asset and digest validation, the embedded `antigravity` table read, the `antigravity-acp-repack --check` rebuild check, the exit statuses (1 and 2), and the atomic write keep their current behavior.

**Pin**

- R5. `packages/t3code-release.json` pins the latest stable T3 Code release (`0.1.8` at planning time) with a verified `antigravity` section.

**Consumers and descriptions**

- R6. The macOS desktop package installs the bundle name the stable Darwin zip ships (`T3 Code (Beta).app`, verified in `T3-Code-0.1.8-arm64.zip`), and the Dock and checks use that same name.
- R7. Descriptions, comments, and docs that call the pin a nightly describe it as the stable release, and docs name the new pinned version.

**Coverage**

- R8. Tests cover stable selection, rejection of prereleases, drafts, and non-semver tags, downgrade refusal, and the stable bundle name, and the reconcile fixtures use stable versions.

### Scope Boundaries

- Out of scope: a channel option to switch between stable and nightly. The request asks for stable only.
- Out of scope: the `T3 Code 0.1.7` driver limitations named in `AGENTS.md` and `docs/agent-routing.md`. They describe driver behavior, not the pin, and re-verifying them against `0.1.8` needs signed-in sessions.
- Not built: a guard in `packages/t3code-app-bundle.nix` that throws on a non-stable pin. `checks.aarch64-darwin.darwin-outputs` already unzips the pinned zip and fails when the bundle name is wrong, so a hand-edited nightly pin is caught before it ships. Evidence that would change this: that check being removed or unable to run on CI.

---

## Planning Contract

### Key Technical Decisions

- KTD1. **Stable tag pattern and version key.** The tag pattern becomes `^v(\d+)\.(\d+)\.(\d+)$`, and the version key becomes the integer triple. The nightly date/build ordering and the `float('inf')` stable bonus go away because only one track remains. Selection filters `prerelease is False` and `not draft`. Rationale: GitHub's flags plus a strict tag shape exclude the preview, nightly, and Android tags seen in the live release list, even if one of them were published without the prerelease flag.
- KTD2. **A pin that is not plain semver counts as older.** `version_key` raises `ValueError` for any non-stable string, and `main` already treats that as "the resolved release is newer". The current nightly pin is therefore replaced by `0.1.8` on the next run, although `0.1.9` has a higher base triple. A stable pin is never replaced by an older stable. Rationale: this matches `scripts/grok-build-release`, where a non-numeric pin is treated as older than the stable. Moving off the nightly track is the intended migration, not a downgrade on one track.
- KTD3. **Re-pin by running the updated script.** The new pin comes from `scripts/t3code-release --output packages/t3code-release.json` after U1. It is not hand-edited. Rationale: the script checks every digest, reads the `antigravity` table from the release's own CLI, and runs the rebuild check. A hand-written pin would skip all three.
- KTD4. **`packages/t3code-app-bundle.nix` returns the stable name only.** It returns the constant `"T3 Code (Beta).app"` and stops branching on the version. It stays a separate file because `packages/t3code.nix`, `modules/darwin/dock.nix`, `tests/darwin-config.nix`, and `tests/darwin-outputs.nix` import it.

### Assumptions

- `T3 Code (Beta).app` stays the stable bundle name. It is the name in `v0.1.8`, and `docs/macos.md` recorded the same name for `0.1.7`. If a later stable release renames the bundle, `darwin-outputs` fails on that bump.
- Stable releases keep the nightly asset names (`T3-Code-<v>-x86_64.AppImage`, `-arm64.AppImage`, `-arm64.zip`, `t3-<v>-{linux-x64,linux-arm64,darwin-arm64}.tar.gz`) with digests. This was confirmed for `v0.1.8`.

### Risks & Dependencies

- The `0.1.8` CLI may embed a different Antigravity runtime than `1.4.5`. In that case the re-pin downloads every system's runtime archive (several hundred MB) and runs the rebuild check. If the check refuses, the stop condition applies.
- Python 3.11+ (`hashlib.file_digest`) is required to run the script locally, as it is today.

### Sources

- Live release list: stable tags `v0.1.2` through `v0.1.8`, with `v0.1.8` published 2026-11-09. The list also mixes in `-preview.`, `-nightly.`, and `t3code-android-*` tags.
- `T3-Code-0.1.8-arm64.zip` (sha256 `8392a4f5…2136`) holds a single top-level `T3 Code (Beta).app` with executable `Contents/MacOS/T3 Code (Beta)`.
- `scripts/grok-build-release` and `tests/test_grok_build_release.py` show the stable-only pattern and the non-numeric-pin rule.

---

## Implementation Units

### U1. Stable release selector

- **Goal:** `scripts/t3code-release` resolves only stable releases (R1-R4).
- **Requirements:** R1, R2, R3, R4
- **Dependencies:** none
- **Files:** `scripts/t3code-release`, `tests/test_t3code_release.py`
- **Approach:**
  1. Replace `TAG_PATTERN` and `VERSION_PATTERN` per KTD1, simplify `version_key` to the triple, and rename `newest_nightly` to a stable-named function with the KTD1 filter. Its error message names "no stable release".
  2. Rewrite the module docstring and comments to describe stable selection. Keep the paragraphs on `antigravity` and the rebuild check.
  3. Leave `parse_release`, `embedded_table`, `parse_table`, `check_rebuild`, and the write path unchanged.
  4. Move test fixtures to stable tags (for example `NEWEST = "v0.0.47"`). Make the `release()` helper default to `prerelease=False`, and keep nightly, preview, and Android entries in the release list as distractors.
- **Patterns to follow:** `scripts/grok-build-release` (stable pointer, non-numeric pin rule) and the existing test helpers in `tests/test_t3code_release.py`.
- **Test scenarios:**
  - A list holding an older stable, a newer nightly, a newer preview, an `android-beta-*` tag, and the newest stable not listed first resolves to the newest stable.
  - A higher stable patch beats a lower one regardless of list order (for example `v0.0.47` over `v0.0.46` listed later).
  - A newer plain-semver tag marked `prerelease: true` is ignored.
  - A newer plain-semver tag marked `draft: true` is ignored.
  - Tags `v0.0.48-rc.1`, `0.0.48` without the `v`, and `v0.0` are ignored.
  - A list with only nightlies and previews exits 1 with a "no stable release" message and writes nothing.
  - A stable pin newer than every listed stable writes nothing and prints "already up to date".
  - A pin `0.1.9-nightly.20261110.4491` is replaced by stable `v0.1.8` (KTD2).
  - The existing missing-asset, duplicate-asset, bad-digest, unreadable-table (exit 2), digest-mismatch, rebuild-refusal, unchanged-runtime, dry-run, malformed-pin, fetch-error, and non-list-body tests pass with stable fixtures.
  - This seam runs the real script against fixture HTTP bodies and archives. It catches selection and refusal logic. It does not prove that the live GitHub list parses, which U2's re-pin proves.
- **Verification:** `tests/test_t3code_release.py` passes, and no test name or message in it still says "nightly" except the distractor fixtures.

### U2. Re-pin to the latest stable release

- **Goal:** `packages/t3code-release.json` pins stable `0.1.8` with a verified `antigravity` section (R5).
- **Requirements:** R5
- **Dependencies:** U1
- **Files:** `packages/t3code-release.json`
- **Approach:** Run the updated script against the live release API with `--output packages/t3code-release.json` (KTD3). Use `GH_TOKEN` from `gh auth token` when rate limits require it. Inspect the diff: version `0.1.8`, tag `v0.1.8`, all six asset digests, and the `antigravity` section.
- **Execution note:** This is a data refresh. The proof is the script's own validation plus the `t3code` and `darwin-outputs` package checks in U3.
- **Test expectation:** none -- data-only change validated by the updater and the package checks.
- **Verification:** The pin digests match the GitHub release digests listed for the resolved tag, and the script exits 0. If a stable newer than `0.1.8` exists when U2 runs, every `0.1.8` in this plan (U3 docs edit, Verification Contract, Definition of Done) means the version the script resolved.

### U3. Stable bundle name and descriptions

- **Goal:** Packages, the Dock, docs, and checks name the stable release and its bundle (R6, R7).
- **Requirements:** R6, R7
- **Dependencies:** U2
- **Files:** `packages/t3code-app-bundle.nix`, `packages/t3code.nix`, `packages/t3code-cli.nix`, `packages/agent-tools.nix`, `modules/shared/darwin-apps.nix`, `.github/workflows/update-dependencies.yml`, `docs/macos.md`, `tests/fixtures/hosts/magnolia/default.nix`
- **Approach:**
  1. `packages/t3code-app-bundle.nix` returns the constant per KTD4. Drop the "Stable beta and nightly artifacts" comment in `packages/t3code.nix`.
  2. Remove "(nightly)" from the `meta.description` of `packages/t3code.nix` and `packages/t3code-cli.nix`.
  3. Update the `t3codeRelease` comment in `packages/agent-tools.nix`, the `t3code-desktop.nix` reason in `modules/shared/darwin-apps.nix` ("from the stable pin"), and the step 8 comment in `.github/workflows/update-dependencies.yml` ("A release can be published before its assets…").
  4. Change the T3 Code version in `docs/macos.md` from `0.1.7` to `0.1.8` everywhere it names the pin (Nix apps, User environment, App notes).
  5. Reword the "nightly desktop app" comment in the magnolia fixture.
- **Patterns to follow:** existing `meta` descriptions of the other pinned packages.
- **Test expectation:** none -- strings and a constant. U4 adds the checks that read them.
- **Verification:** `git grep -n -i nightly` outside `.compound-engineering/artifacts/` finds no T3 Code reference except test distractor fixtures.

### U4. Checks follow the stable track

- **Goal:** The Nix and shell checks assert the stable track and its bundle (R8).
- **Requirements:** R6, R8
- **Dependencies:** U1, U3
- **Files:** `tests/update-dependencies-reconcile.sh`, `tests/t3code-traits.nix`, `tests/darwin-outputs.nix`
- **Approach:**
  1. In `tests/update-dependencies-reconcile.sh`, change the T3 Code fixture versions (`0.0.46-nightly.…`, `0.0.47-nightly.…`) to stable strings, and keep the bump-commit subject assertion matching.
  2. In `tests/t3code-traits.nix`, change the failure message "off the nightly pin" to "off the pin".
  3. In `tests/darwin-outputs.nix`, rename "the T3 Code nightly bundle is missing" to name the stable bundle. The existing checks already cover a wrong bundle name: `packages/t3code.nix` fails to copy a bundle the zip does not hold, and `darwin-outputs` compares the installed executable with the one in the pinned zip.
- **Patterns to follow:** the existing `bad` helper in `tests/darwin-outputs.nix`.
- **Test scenarios:**
  - `update-dependencies-reconcile` passes with stable fixture versions, including the separate-commit assertion for the T3 Code bump.
  - `darwin-outputs` passes with the `0.1.8` zip and the `T3 Code (Beta).app` constant.
  - `t3code-traits` passes unchanged apart from the message.
- **Verification:** The listed checks pass on the builders that can run them, and the CI-only ones pass in CI.

---

## Verification Contract

| Check | Proves | Where it runs |
| --- | --- | --- |
| `python3 tests/test_t3code_release.py` / `.#checks.<system>.t3code-release` | R1-R4 | macOS locally, Linux in CI |
| `.#checks.<system>.update-dependencies-reconcile` | R8 reconcile fixtures | locally where it builds, otherwise CI |
| `.#checks.<system>.t3code` | R5 binaries report `0.1.8` | CI host/closure shard |
| `.#checks.<system>.t3code-traits` | R6, R7 traits | CI |
| `.#checks.aarch64-darwin.darwin-config` | R6 Dock path | macOS locally |
| `.#checks.aarch64-darwin.darwin-outputs` | R6 bundle in zip | macOS locally (heavy) and `build-darwin` |
| `nix flake check --no-build`, `git diff --check`, `markdownlint-cli2` on changed Markdown | evaluation and hygiene | locally |

The PR needs the `full-ci` label and a green run of `host-checks`, `vm-checks`, `build`, and `build-darwin` on its head, per `AGENTS.md`.

## Definition of Done

- R1-R8 hold, with every unit's verification met.
- `packages/t3code-release.json` was written by the updated script and pins `0.1.8`.
- No T3 Code "nightly" wording remains outside test distractors and historical artifacts.
- No abandoned experimental code remains in the diff.
