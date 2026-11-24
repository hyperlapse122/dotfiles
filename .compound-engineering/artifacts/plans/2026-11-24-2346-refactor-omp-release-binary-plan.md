---
title: omp Release Binary Install - Plan
type: refactor
date: 2026-11-24
topic: omp-release-binary
artifact_contract: ce-unified-plan/v1
product_contract_source: ce-brainstorm
execution: code
---

# omp Release Binary Install - Plan

## Goal Capsule

- **Objective:** A rebuild on either host installs omp without compiling it, and the omp settings the owner set by hand survive the next switch.
- **Means:** Pin the upstream release binary in a release JSON like `packages/opencode-release.json`, keep the upstream Home Manager module from a release-tag flake input, and move the live `~/.omp/agent/config.yml` values into `home/h82/agents/omp.nix` (KTD1–KTD5).
- **Product authority:** The repository owner. Decisions below marked `session-settled` were made by the owner and are not reopened in planning.
- **Execution profile:** One PR, units U1–U6 in order. `lfg` finishes and ships it; merging stays with the owner.
- **Stop conditions:** Stop if the Linux release binary cannot run unmodified under nix-ld, or if setting `programs.omp.package` still pulls the upstream source build into a Home Manager generation.
- **Open blockers:** None.

---

## Product Contract

### Summary

omp installs from the official GitHub release binary, recorded in `packages/omp-release.json` together with the release tag's commit rev. The `omp` flake input pins the same release tag and supplies only the Home Manager module. One update step bumps the JSON, the flake URL tag, and the lock together. The owner's current model roles and thinking level become declared settings on every host.

### Problem Frame

The `omp` input follows upstream `main` (`github:can1357/oh-my-pi`, locked at `6b96042`). Its Home Manager module defaults `programs.omp.package` to a source build through bun2nix and a Rust native crate, so every relock that moves `main` triggers a slow rebuild. Upstream already publishes per-platform single binaries and `SHA256SUMS.txt` on each release (v19.1.1 at commit `31ffee5`).

The module also copies declared settings over `~/.omp/agent/config.yml` on every switch. The owner configured eight model roles and a default thinking level by hand. The flake declares only `modelRoles.default = synthetic/hf:zai-org/GLM-5.3-Flash`, so the next switch would overwrite those choices.

### Key Decisions

- **Keep `omp` as a flake input, pinned to a release tag, and import `homeManagerModules.default`.** (session-settled: user-directed — chosen over a `flake = false` input importing `nix/home-manager.nix` and over a JSON-only `builtins.fetchTree` source: smallest change, keeps the upstream module entry point.) Governs R4, R5.
- **Move the flake tag, the lock, and the JSON in one update step.** (session-settled: user-approved — chosen over tracking `main`, which drifts from the release rev on every `nix flake update`: a tag ref holds the lock still until the tag in `flake.nix` changes.) Governs R6, R7.
- **Apply the same omp settings on every host.** (session-settled: user-directed — chosen over darwin-only local roles and over adding `clef-flash` provisioning: keep one settings set for now.) Governs R9.

### Requirements

**Release pin and package**

- R1. `packages/omp-release.json` records the release version, the commit rev the release tag names, and for each of `x86_64-linux` and `aarch64-darwin` the asset name, hex sha256, and SRI hash.
- R2. A package in `packages/` installs the pinned release binary for the current system, unmodified, and exposes `omp` on PATH.
- R3. Building the omp package or the Home Manager configuration does not build omp from source on either host.

**Module source**

- R4. The `omp` flake input points at the release tag recorded in R1, and `home/h82/agents/omp.nix` keeps importing `inputs.omp.homeManagerModules.default`.
- R5. `programs.omp.package` is set to the R2 package.

**Update flow**

- R6. `scripts/omp-release` resolves the newest stable upstream release and writes the R1 pin. Like the existing `*-release` scripts, it refuses a release missing any target asset or digest and refuses a version that is not strictly newer than the pinned one.
- R7. The dependency update workflow (`.github/workflows/update-dependencies.yml`) runs R6 and, in the same change, rewrites the tag in the `omp` input URL in `flake.nix` and relocks only that input, following the existing compound-engineering bump step.
- R8. A repository check fails when the rev in `packages/omp-release.json` differs from the locked rev of the `omp` input in `flake.lock`, or when the locked ref is not the tag `v<version>`.

**Settings migration**

- R9. `programs.omp.settings` declares, on every host, the values below in addition to the existing `composer`, `theme`, `update.auto = false`, and `symbolPreset` values. The `modelRoles.default` value replaces the current `synthetic/hf:zai-org/GLM-5.3-Flash`.

| Key | Value |
| --- | --- |
| `modelRoles.default` | `openrouter/deepseek/deepseek-v4.1-flash-1017:max` |
| `modelRoles.smol` | `openrouter/deepseek/deepseek-v4.1-flash-1017:auto` |
| `modelRoles.slow` | `openrouter/anthropic/claude-opus-5.5:medium` |
| `modelRoles.judge` | `ollama/clef-flash:latest` |
| `modelRoles.dictation` | `openrouter/openai/whisper-large-v3` |
| `modelRoles.speech` | `local/phonon-31m` |
| `modelRoles.image` | `openrouter/bytedance-seed/seedream-5-5` |
| `modelRoles.web` | `web/parallel` |
| `defaultThinkingLevel` | `auto` |
| `setupVersion` | `3` |

**Retirement guard**

- R10. `tests/agent-unmanaged.nix` / `tests/agent-unmanaged.py` stop treating omp as a retired tool, so an installed `omp` binary, the `ompConfig` activation, and `omp.nix` pass, while the remaining retired names (`agy`, `agy_acp_server.par`, `localharness_external`, `.gemini`) stay rejected.

### Acceptance Examples

- AE1. **Covers R4, R7, R8.** **Given** upstream publishes v19.2.0, **when** the update workflow runs, **then** one commit changes `packages/omp-release.json`, the tag in `flake.nix`, and the `omp` node in `flake.lock`, and the R8 check passes.
- AE2. **Covers R8.** **Given** someone edits only the JSON rev, or a relock picks up an upstream tag force-moved to another commit, **when** the R8 check runs, **then** it fails and names both revs.
- AE3. **Covers R4.** **Given** a plain `nix flake update` with no new release, **when** the lock is regenerated, **then** the `omp` locked rev does not change.
- AE4. **Covers R9.** **Given** the NixOS host has no `clef-flash` model in ollama, **when** omp starts there, **then** it starts normally and only the judge role fails when used.

### Scope Boundaries

- Provisioning `clef-flash` or any other local model for the `judge` or `speech` roles on any host.
- Per-host differences in omp settings.
- Removing upstream's transitive inputs (bun2nix, crane, rust-overlay, and others) from `flake.lock`.
- Platforms other than `x86_64-linux` and `aarch64-darwin`.
- Preserving runtime `/settings` changes across switches; the module still overwrites `config.yml` on each switch.

### Dependencies / Assumptions

- The Linux release binary runs under NixOS nix-ld when installed unmodified, as the opencode Bun binary does. KTD1 confirms that the glibc asset needs only libraries nix-ld supplies. If it still fails on the NixOS host, stop per the Goal Capsule stop condition.
- Setting `programs.omp.package` keeps Nix from evaluating or building the upstream source package. This is inferred from lazy evaluation of the module's `default`. U3 verifies it with a build that shows no `bun2nix` or `omp-native` derivations.
- GitHub's per-asset `digest` field supplies the sha256 for each binary, per KTD2.

### Sources / Research

- `packages/opencode-release.json`, `packages/opencode.nix`, `scripts/opencode-release`, `scripts/release_pin.py`: the pin, package, and update pattern to follow.
- `.github/workflows/update-dependencies.yml` (compound-engineering bump step near line 217): tag rewrite and single-input relock pattern.
- `home/h82/agents/agent-plugin-pins.nix`: existing check comparing a tag's recorded rev with `flake.lock`.
- Upstream `nix/home-manager.nix` at the locked input: `programs.omp.package` option and the activation that copies `config.yml` on each switch.
- `home/h82/agents/omp.nix`: current declared settings.

Product Contract preservation: R8 changed from "`./scripts/agent-check` fails" to "a repository check fails". `agent-check` runs only formatting, Markdown lint, and advisories. The repository's rev-drift guards are flake checks (`tests/agent-plugins.nix`), which `nix flake check` and the update workflow's verification build. The intent, a failure on rev drift, is unchanged. R8 also adds the tag-ref condition so a branch ref cannot pass.

---

## Planning Contract

### Key Technical Decisions

- KTD1. **Install the release binary unmodified with `dontFixup`, as `packages/opencode.nix` does.** omp release binaries are Bun-compiled executables with the bundle appended to the file, so stripping would turn them into a bare Bun runtime. The Linux ELF needs only glibc (`libc`, `libm`, `libdl`, `libpthread`) through `/lib64/ld-linux-x86-64.so.2`, which `modules/nixos/system/nix-ld.nix` supplies. Darwin runs `omp --version` in `installCheck`. Linux compares the installed file with the fetched one, because the build sandbox has no nix-ld. Governs R2.
- KTD2. **`scripts/omp-release` reads `releases/latest` and resolves the tag's commit through `commits/<tag>`.** Unlike opencode, omp has a single release line, so `latest` is enough. The release JSON's `target_commitish` is a branch name (`main`), not a sha, so the rev needs its own lookup. The pin uses GitHub's per-asset `digest`, which matches upstream `SHA256SUMS.txt` for v19.1.1. Governs R1, R6.
- KTD3. **The tag is derived from the version (`v<version>`) and is not stored separately.** It keeps one source of truth in the JSON. The workflow writes `github:can1357/oh-my-pi/v<version>` into `flake.nix`, and the check compares `flake.lock`'s `original.ref` with it. Governs R4, R7, R8.
- KTD4. **The workflow's omp step runs after `nix flake update`, mirroring the compound-engineering step.** A failing `omp-release` (for example, assets not yet uploaded) is soft: it restores only `packages/omp-release.json` before `flake.nix` or `flake.lock` is touched. Once the JSON moved, the step rewrites the tag, runs `nix flake lock --update-input omp`, and exits non-zero if the locked rev differs from the JSON rev. This matches the compound-engineering step's hard failure on an unusable rev and never restores `flake.lock` wholesale, which would drop other input updates. Governs R7.
- KTD5. **One check, `tests/omp.nix`, owns omp's package identity, settings, and pin agreement, and runs on both systems.** It already executes the activation block and compares bytes. It now also compares the user's omp package with `packages/omp.nix` at the pinned version, and the JSON pin with `flake.lock`. Registering it in `tests/linux-checks.nix` puts it in the update workflow's verification (`checks.x86_64-linux`). Governs R3, R5, R8, R9.

### Assumptions

- The declared `setupVersion = 3` equals upstream `CURRENT_SETUP_VERSION` (`packages/coding-agent/src/config/setup-version.ts`) at v19.1.1. A later omp release that raises it would rerun the setup wizard on each switch until the declared value is bumped. The risk is accepted with R9.
- An omp bump commit may also carry other `flake.lock` changes from the same run's `nix flake update`, as the compound-engineering bump commit already does.
- `defaultThinkingLevel` is a valid omp setting key: omp itself wrote it to the live `config.yml`.

### Risks

- An upstream force-moved tag surfaces as a check failure (AE2), not a silent lock change. That failure blocks dependency publication until the pin is fixed. Re-pin `rev` in `packages/omp-release.json` by hand after confirming the moved tag, or wait for the next release. `omp-release` leaves an equal version untouched.
- A future upstream release could ship a Linux binary that needs more libraries than nix-ld provides. `installCheck` cannot catch this on Linux, so the owner's first run after a bump is the signal, as for opencode.

---

## Implementation Units

### U1. Release resolver `scripts/omp-release`

- **Goal:** Resolve the newest stable omp release into the R1 pin shape.
- **Requirements:** R1, R6; KTD2, KTD3.
- **Files:** `scripts/omp-release` (new), `tests/test_omp_release.py` (new), `tests/python-script-checks.nix`, `packages/agent-tools.nix`, `packages/default.nix`.
- **Approach:** Follow `scripts/opencode-release` and `scripts/release_pin.py` (`fetch`, `hex_to_sri`, `pinned_version`, `version_tuple`, `Failure`). Target assets: `x86_64-linux` → `omp-linux-x64`, `aarch64-darwin` → `omp-darwin-arm64`. Output `{ version, rev, platforms: { <system>: { asset, sha256, hash } } }`. Accept only tags matching `^v(\d+\.\d+\.\d+)$`, and require a 40-hex `sha` from `commits/<tag>`. Package it as `ompRelease = releaseHelper "omp-release" ../scripts/omp-release` and expose `omp-release` in the Linux section of `packages/default.nix`. Register `releaseScriptCheck "omp-release"`.
- **Test scenarios** (stubbed `curl` on `PATH`, as in `tests/test_opencode_release.py`):
  - Happy path: latest `v19.2.0` with both assets and a commit sha writes the pin with `rev` and the SRI hashes derived from the digests.
  - Refusal: a missing `omp-darwin-arm64` asset, a duplicated asset, a malformed digest, or a non-40-hex commit sha exits 1 and leaves the pin file unchanged.
  - Refusal: a prerelease or draft `latest`, or a tag like `v19.2.0-rc1`, exits 1.
  - No downgrade: a resolved version equal to or older than the pinned one leaves the file byte-identical and exits 0.
  - `--dry-run` prints the JSON without writing.
- **Verification:** `python3 tests/test_omp_release.py` passes locally, and `nix run .#omp-release -- --dry-run` (or running the script directly) against live GitHub resolves v19.1.1 with rev `31ffee513f27a01bba7d4dfbe12bae239cdc646a`.

### U2. Release-binary package and pinned input

- **Goal:** A `packages/omp.nix` derivation that installs the pinned binary, plus the `omp` input on the matching tag.
- **Requirements:** R1, R2, R4; KTD1, KTD3.
- **Files:** `packages/omp-release.json` (new, written by U1's script), `packages/omp.nix` (new), `packages/default.nix`, `flake.nix`, `flake.lock`.
- **Approach:** Model on `packages/opencode.nix`, but use a bare-binary `fetchurl` (no archive, `dontUnpack`), `install -Dm755` to `$out/bin/omp`, and `dontFixup = true`. On Darwin, run `versionCheckHook` and `writableTmpDirAsHomeHook`. On both systems, `postInstallCheck` runs `cmp` against the source. Set `meta.platforms` from the JSON and `mainProgram = "omp"`. Change `flake.nix` to `url = "github:can1357/oh-my-pi/v19.1.1"`, keep `inputs.nixpkgs.follows`, and update the comment. Then relock only that input (`nix flake lock --update-input omp`). Expose `omp` in `packages/default.nix` beside `opencode`.
- **Test expectation:** Covered by U3's check (package identity and version) and by the derivation's own install check.
- **Verification:** `nix build .#packages.aarch64-darwin.omp` or an equivalent darwin build succeeds, and `result/bin/omp --version` prints `omp/19.1.1`. `flake.lock`'s `omp` node shows `original.ref = "v19.1.1"` and `locked.rev = 31ffee5…`.

### U3. Home Manager wiring, settings migration, and the omp check

- **Goal:** Install the U2 package through upstream's module, declare the migrated settings, and guard both, together with the pin, in one check.
- **Requirements:** R3, R5, R8, R9; KTD5; Key Decision "same settings on every host" (Governs R9).
- **Files:** `home/h82/agents/omp.nix`, `tests/omp.nix`, `tests/linux-checks.nix`.
- **Approach:** In `omp.nix`, set `programs.omp.package = import ../../../packages/omp.nix { inherit pkgs; }` and declare the R9 table beside the existing composer, theme, update, and symbolPreset keys. In `tests/omp.nix`:
  - Replace the expected mapping with the full R9 set.
  - Assert that the omp package in each entry's `home.packages` is `packages/omp.nix`'s output and has the pinned version.
  - Read `../flake.lock` and `../packages/omp-release.json` directly, and fail when `nodes.omp.locked.rev` ≠ JSON `rev` or `nodes.omp.original.ref` ≠ `v<version>`. The message must name both values.
  - Make every lookup `or`-guarded, so a removed declaration fails in the builder rather than at evaluation, per `.compound-engineering/artifacts/solutions/best-practices/unguarded-derivation-interpolation-defeats-nix-check-mutation-testing.md`.
  - Generalize the darwin-only wording.

  Register `omp = import ./omp.nix { inherit pkgs; entries = configurations.userEntries; }` in `tests/linux-checks.nix` (light shard, no host closure).
- **Test scenarios:**
  - Happy path: the activation writes a `config.yml` byte-identical to the declared R9 mapping, on both darwin and nixos entries.
  - Mutation: dropping `programs.omp.package` from `omp.nix` makes the package identity assertion fail (the module default is the source build).
  - Mutation: editing the JSON `rev`, or changing the `flake.nix` URL to a branch and relocking, fails with both revs or refs named (AE2).
  - Mutation: removing one `modelRoles` key fails the byte comparison.
- **Verification:** `nix build .#checks.aarch64-darwin.omp` passes. `nix derivation show -r` of a darwin Home Manager generation lists no `bun2nix` or `omp-native` derivations (R3). `cargo` is not a signal, because `packages/impeccable.nix` already puts Rust builds in the generation. The Linux check's inputs are confirmed through `nix derivation show .#checks.x86_64-linux.omp`, per `.compound-engineering/artifacts/solutions/best-practices/verify-linux-only-nix-check-inputs-on-macos-through-derivation-show.md`.

### U4. Update workflow integration

- **Goal:** The scheduled dependency update bumps the JSON, the flake tag, and the lock together.
- **Requirements:** R7; KTD4.
- **Files:** `.github/workflows/update-dependencies.yml`, `tests/update-dependencies-reconcile.sh`.
- **Approach:** In the update step, after the compound-engineering block:
  1. Run `nix run .#omp-release -- --output packages/omp-release.json` with soft-fail restoring only the JSON.
  2. If the JSON changed, `sed` the `oh-my-pi/v<old>` tag to `v<new>` in `flake.nix` and run `nix flake lock --update-input omp`.
  3. Compare the locked rev with the JSON `rev` and exit 1 on mismatch.

  In the commit step, when `packages/omp-release.json` changed, commit `flake.nix flake.lock packages/omp-release.json` as `chore(packages): bump omp to <version>` before the generic `flake.lock` commit. When compound-engineering and omp bump in the same run, the first of the two commits carries both flake changes. Extend the reconcile test:
  - Add the omp URL to the fixture `flake.nix`, an `omp` lock node, and `packages/omp-release.json`.
  - Stub `run .#omp-release -- --output packages/omp-release.json` and `flake lock --update-input omp`.
  - Add an `omp` soft-fail branch.
  - Test the omp commit boundary in its own clone, where only the omp pin, tag, and lock node change. Leave the existing 10-commit per-pin fixture without an omp bump.
- **Test scenarios:**
  - Happy path: a bumped pin rewrites the `flake.nix` tag, updates the lock rev, and produces one `bump omp` commit carrying exactly `flake.lock flake.nix packages/omp-release.json`.
  - Soft fail: `FAIL_SOFT=omp` warns, restores the JSON, and leaves `flake.nix` untouched.
  - Rev mismatch: a stubbed lock rev that differs from the JSON stops the step with a non-zero status.
  - Unchanged pin: no tag rewrite and no `--update-input omp` call.
- **Verification:** `bash tests/update-dependencies-reconcile.sh` passes through its Nix check wrapper (`tests/workflow-checks.nix`). If it cannot run on macOS, confirm with `nix derivation show` and record that limit.

### U5. Documentation

- **Goal:** The repository reference describes the new install path.
- **Requirements:** R2, R4.
- **Files:** `docs/repository-reference.md`.
- **Approach:** Rewrite the omp clause in line 18: the release binary pinned in `packages/omp-release.json`, the HM module from the `omp` input pinned to the same release tag, and `omp-release` in the release-helper list.
- **Test expectation:** None. Documentation only.

### U6. Un-retire omp in the agent-unmanaged check

- **Goal:** The retirement guard from `f4e8e5a` ("stop managing OMP") no longer rejects the omp install this repository now manages.
- **Requirements:** R10.
- **Files:** `tests/agent-unmanaged.py`.
- **Approach:** Remove `omp` from the `TOKEN` regex-based package, module, activation, and home-files scans, and from the profile-binary name list. Keep the Antigravity binaries and `.gemini` assertions. If no retired-name token remains for the text scans, drop the scans and their self-tests rather than leaving a regex that matches nothing.
- **Test scenarios:**
  - Happy path: with U3 applied, the check passes on darwin and nixos entries whose profile has `bin/omp` and whose activation carries `ompConfig`.
  - Guard kept: a profile containing `bin/agy` still fails.
- **Verification:** `nix build .#checks.aarch64-darwin.agent-unmanaged` passes. The Linux variant is confirmed by `nix derivation show .#checks.x86_64-linux.agent-unmanaged`.

---

## Verification Contract

| Gate | Command | Covers |
| --- | --- | --- |
| Resolver unit tests | `python3 tests/test_omp_release.py` | U1 |
| Darwin package and checks | `nix build .#packages.aarch64-darwin.omp .#checks.aarch64-darwin.omp .#checks.aarch64-darwin.agent-unmanaged` | U2, U3, U6 |
| No source build | `nix derivation show -r` on a darwin HM generation; grep shows no `bun2nix`, `omp-native` | R3 |
| Linux check evaluates | `nix derivation show .#checks.x86_64-linux.omp` and `.#checks.x86_64-linux.omp-release` | U1, U3 |
| Workflow reconcile | `tests/update-dependencies-reconcile.sh` through `tests/workflow-checks.nix` | U4 |
| Flake evaluation | `nix flake check --no-build` | all |
| Repository check | `nix develop .#agent-check -c ./scripts/agent-check` | all |

## Definition of Done

- Every gate in the Verification Contract passed, or its limit (a Linux-only build on macOS) is recorded with the substitute evidence.
- `home/h82/agents/omp.nix` declares the full R9 set, and `programs.omp.package` points at `packages/omp.nix`.
- `flake.lock`'s `omp` node is the `v19.1.1` tag at `31ffee5`, matching `packages/omp-release.json`.
- No `switch` was run on any host. Applying the change stays with the owner.
- Throwaway downloads and experimental code are removed from the diff.
