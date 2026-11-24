---
title: "Install omp as a managed CLI harness - Plan"
type: feat
date: 2026-11-24
topic: omp-managed-cli-harness
artifact_contract: ce-unified-plan/v1
product_contract_source: ce-brainstorm
execution: code
---

# Install omp as a managed CLI harness - Plan

## Goal Capsule

- **Objective:** After a rebuild, `omp` runs as a flake-managed CLI on both hosts with the user's current omp settings owned by the configuration, and both hosts trust the nix-community binary cache.
- **Means:** Add `github:can1357/oh-my-pi` as a flake input, install through its Home Manager module (`programs.omp`), migrate the existing `~/.omp/agent/config.yml` values into `programs.omp.settings`, and add the nix-community substituter and public key to the shared nix settings.
- **Product authority:** The repository owner decides scope; this plan covers installation, settings migration, and cache trust only. Deeper omp harness integration (skills, plugins, model catalogs, per-host differences) is future work, not active scope.
- **Execution profile:** One feature branch, one pull request. The owner runs host rebuilds (`nr switch`); verification in this run is evaluation and checks only.
- **Stop conditions:** A conflict with a session-settled decision, or a failed flake evaluation, stops before shipping.
- **Open blockers:** None.

## Product Contract

### Summary

Install the omp coding agent purely through nix as a managed CLI on both hosts, move the current runtime config file into declarative Home Manager settings, and trust `nix-community.cachix.org` in the shared nix settings. No other harness integration changes.

Product Contract preservation: unchanged (R-IDs, Key Decisions, AE-IDs carried forward as written).

### Problem Frame

omp is used today as an unmanaged binary: it was installed outside the flake, so it sits outside the rebuild-and-rollback system, receives self-updates, and does not exist on a fresh host restore. Its runtime config (`~/.omp/agent/config.yml`) is hand-edited, so the two machines can drift and a rebuild cannot restore it. Separately, the shared nix settings declare no substituters, so every nix-community-sourced build (several flake inputs already come from `nix-community`) builds from source on both hosts.

### Requirements

**Installation**

- R1. `omp` is installed on both hosts through the `programs.omp` Home Manager option from a new `github:can1357/oh-my-pi` flake input; installation is purely nix-managed with no Homebrew cask, curl script, or self-update path. (session-settled: user-directed — chosen over Homebrew tap and release-binary pin: nix-only, reproducible, and upstream ships a Home Manager module)
- R2. omp's own updater stays off via the migrated `update.auto: false` setting, consistent with nix-only ownership.

**Settings migration**

- R3. The declarative settings reproduce the current runtime config: `modelRoles.default = "synthetic/hf:zai-org/GLM-5.3-Flash"`, `composer.shape = "band"`, `composer.tokenRate = true`, `theme.dark = "titanium"`, `theme.light = "light"`, and `symbolPreset = "nerd"`. `setupVersion` is not migrated; omp manages it.
- R4. The declared settings cover the whole previous file's kept content, so a rebuild restores `~/.omp/agent/config.yml` to the declared values. Settings changed from inside omp after that revert on the next rebuild (the repository's declared-set tradeoff, accepted for this file).

**Cache trust**

- R5. The shared nix settings add `https://nix-community.cachix.org` to the substituters with its published public key as trusted, reaching both hosts through the existing shared module.

### Key Decisions

- KD1. Install via upstream flake input + Home Manager module, not Homebrew or a pinned release binary. (session-settled: user-directed — chosen over `can1357/tap/omp` and the `opencode-release.json` pattern: nix-only ownership and version pinning through `flake.lock`)
- KD2. omp settings live at the user layer (`home/h82`), so both hosts share one declared config; per-host divergence waits for a trait, which is future scope.
- KD3. Cache trust goes in `modules/shared/nix-settings.nix` because it is host-independent and that module already reaches both host kinds.

### Dependencies / Assumptions

- The `programs.omp` Home Manager option supports the settings keys in R3 verbatim; if a key is not declared upstream, planning resolves the correct declarative surface (this is the one planning-level unknown).
- omp discovers the Synthetic provider itself; R3 only carries the model role string.
- The nix-community cachix public key is taken from cachix's published configuration at planning time.

### Scope Boundaries

- No omp harness integration beyond install and settings migration: no skills, plugins, marketplaces, model catalogs, `models.yml`, or instructions delivery.
- No compound-engineering marketplace install or `marketplace.autoUpdate` configuration (removed from scope by the owner).
- No per-host omp differences or new host traits.
- No changes to the existing `agent-plugin-sync` flow or other harnesses (claude, codex, pi, opencode).

### Acceptance Examples

- AE1. **Covers R1, R5.** **Given** a fresh checkout on either host, **when** the host rebuilds, **then** `omp` resolves from the store via the user profile and `nix-community.cachix.org` appears among the daemon's trusted substituters.
- AE2. **Covers R3, R4.** **Given** `~/.omp/agent/config.yml` with `modelRoles.default` reading `synthetic/hf:zai-org/GLM-5.3-Flash` plus the migrated theme, composer, and symbol values, **when** the host rebuilds, **then** the file keeps exactly those values and no `setupVersion` line is restored by the configuration.
- AE3. **Covers R2.** **Given** the declared settings materialized on a host, **when** omp runs, **then** `update.auto` reads `false` in `~/.omp/agent/config.yml` and no self-update path is reachable — version changes come only from a `flake.lock` update.

### Key Decisions carried forward into planning

Resolved during planning, recorded here for the cold reader: the exact declarative surface for every migrated key is `programs.omp.settings.<key>` verbatim (free-form YAML, KTD2), and the shared substituters list carries both `cache.nixos.org` and `nix-community.cachix.org` (KTD4).

## Planning Contract

### Key Technical Decisions

- KTD1. Add `inputs.omp = { url = "github:can1357/oh-my-pi"; inputs.nixpkgs.follows = "nixpkgs"; }` to `flake.nix`, matching the existing pinned-input pattern (home-manager, disko, lanzaboote all follow the base nixpkgs). Governs R1.
- KTD2. Enable `programs.omp` from `inputs.omp.homeManagerModules.default` in a new `home/h82/agents/omp.nix`, imported from `home/h82/agents/default.nix` alongside the other harness modules. The module's `settings` option takes a free-form YAML mapping (`pkgs.formats.yaml`) and copies it to `~/.omp/agent/config.yml` as a writable file on activation, so every R3 key is expressible verbatim with no schema lookup. Governs R3, R4.
- KTD3. `update.auto = false` rides inside `programs.omp.settings` (it is a normal settings key), not a separate option; combined with flake-lock pinning this keeps omp on nix-only updates. Governs R2.
- KTD4. Extend `modules/shared/nix-settings.nix` with `nix.settings.substituters` and `nix.settings.trusted-public-keys` adding `https://nix-community.cachix.org` and its published key `nix-community.cachix.org-1:mB9FSh9qf2dCimDSUo8Zy7bkq5CX+/rkCWyvRCYg3Fs=`. Setting `nix.settings.substituters` (not `extra-substituters`) replaces the default cache.nixos.org entry, so the list must also carry `https://cache.nixos.org` with its public key to keep the default cache. Both host kinds import this module (`modules/nixos/system/base.nix`, `modules/darwin/nix.nix`), and the darwin side `mkForce`s only `auto-optimise-store`, so the new keys pass through. Governs R5.
- KTD5. No instruction-template, skill-root, plugin-sync, or `models.json` wiring in this change: omp reads its own `~/.omp` config, and deeper integration (shared skills, instructions delivery, model catalogs) is explicitly deferred scope. Governs R1's "installation only" boundary and the Scope Boundaries.

### Assumptions

- The upstream HM module at the pinned commit keeps the `programs.omp.settings` free-form-YAML shape verified in research (`nix/home-manager.nix`: `settings = lib.mkOption { type = lib.types.nullOr yaml.type; ... }` writing to `~/.omp/agent/config.yml`); a future upstream change to that option shape is caught by `nix flake check` evaluation, not by a repository check.
- omp discovers the Synthetic provider catalog itself; the migrated `modelRoles.default` string is carried verbatim, and no provider credential wiring is added.
- The nix-community public key is upstream's own `nixConfig` declaration in the oh-my-pi flake, so pinning it in shared settings matches what upstream asks users to trust.

### Sequencing

1. Flake input + module import (U1) — everything else evaluates against it.
2. Settings migration (U2) — depends on U1's module import.
3. Cache trust (U3) — independent of U1/U2; lands in the same PR.

### Sources / Research

- Upstream module source, verified this session: `nix/home-manager.nix` in `can1357/oh-my-pi` — `programs.omp.enable`, `programs.omp.package` (defaults to the input's own package), `programs.omp.settings` (free-form YAML → `~/.omp/agent/config.yml` via a writable-file activation entry, documented lock/EACCES rationale).
- Upstream flake outputs verified this session: `packages.<system>.omp`, `homeManagerModules.default` / `.omp`, `nixosModules.default`; package supports `aarch64-darwin` and `x86_64-linux` (plus two more platforms).
- Upstream `nixConfig` in `can1357/oh-my-pi/flake.nix` declares `extra-substituters = ["https://nix-community.cachix.org"]` and key `nix-community.cachix.org-1:mB9FSh9qf2dCimDSUo8Zy7bkq5CX+/rkCWyvRCYg3Fs=`.
- Upstream `docs/settings.md`: `~/.omp/agent/config.yml` is the global settings file; `marketplace.autoUpdate` (`off|notify|auto`) exists but is not used this scope.
- Existing runtime config to migrate: `~/.omp/agent/config.yml` (outside the repository).
- Repository evidence (claim verifier, this session): no omp input/install exists (`flake.nix` inputs and `home/h82/agents/` listings); `modules/shared/nix-settings.nix` carries no substituter keys; shared module reaches both hosts via `modules/nixos/system/base.nix` and `modules/darwin/nix.nix`; `home/h82` is the common user layer imported by both `lib/nixos-host.nix` and `lib/darwin-host.nix`.
- Precedent for flake-input tools: `flake.nix` inputs for home-manager, disko, lanzaboote, compound-engineering-plugin.

## Implementation Units

### U1. Add the omp flake input and enable programs.omp

- **Goal:** `omp` builds from the pinned upstream input and installs on both hosts through the Home Manager module.
- **Requirements:** R1. Decisions: KTD1, KTD2, KTD5.
- **Dependencies:** None (first unit).
- **Files:** `flake.nix`, `home/h82/agents/omp.nix` (new), `home/h82/agents/default.nix`.
- **Approach:**
  1. Add `inputs.omp` with `nixpkgs.follows` and run `nix flake lock update omp` so `flake.lock` records the pin.
  2. Create `home/h82/agents/omp.nix` importing `inputs.omp.homeManagerModules.default` and setting `programs.omp.enable = true`.
  3. Import it from `home/h82/agents/default.nix` in the existing alphabetical import list.
- **Patterns to follow:** `flake.nix`'s existing pinned inputs (`home-manager`, `disko`, `lanzaboote` all with `inputs.nixpkgs.follows`); `home/h82/agents/default.nix`'s import list.
- **Test scenarios:** covered by U1's verification (evaluation-level; no behavioral code).
- **Verification:** `nix flake check --no-build` passes on the macOS host; `nix eval .#darwinConfigurations --apply builtins.attrNames` and the NixOS side via `nix derivation show` (Linux-only check inputs verified on macOS per repository-reference guidance) both evaluate with `omp` present in the user environment. `Test expectation: none -- config wiring only; repository checks for it land with U2's materialized-output check if added.`
- **Execution note:** mostly config wiring; prefer evaluation smoke verification over unit coverage.

### U2. Migrate the runtime settings into programs.omp.settings

- **Goal:** A rebuild restores `~/.omp/agent/config.yml` to the declared values (R3, R4), with omp's own updater disabled (R2, KTD3).
- **Requirements:** R2, R3, R4.
- **Dependencies:** U1.
- **Files:** `home/h82/agents/omp.nix`.
- **Approach:**
  1. Declare `programs.omp.settings` with exactly: `modelRoles.default = "synthetic/hf:zai-org/GLM-5.3-Flash"`, `composer.shape = "band"`, `composer.tokenRate = true`, `theme.dark = "titanium"`, `theme.light = "light"`, `update.auto = false`, `symbolPreset = "nerd"`.
  2. Do not declare `setupVersion` — omp manages that migration key itself.
- **Patterns to follow:** the upstream module's own example (`settings.theme.dark = "titanium"`); the settings-as-declared-set convention in `CONCEPTS.md` (a rebuild reverts runtime edits to declared keys).
- **Test scenarios:**
  - Happy path: the generated activation writes `~/.omp/agent/config.yml` whose parsed YAML equals the declared mapping, `setupVersion` absent.
  - Edge: the upstream activation copies the YAML as a writable regular file (not a store symlink), so omp's config lock works after activation — assert the materialized path is a regular file with mode 600 when such a check is cheap.
- **Verification:** `nix build` a darwin `homeConfigurations`-equivalent generation output or read the activation script from `nix derivation show` to confirm the `install -m 600` line carries the generated YAML containing all seven keys; run the applicable `tests/`-style materialized-output check if a check is added (see below). Manual verification on the host (owner-run rebuild) is a hardware check, recorded separately.
- **Execution note:** pure configuration; the right proof is the materialized activation content, not a unit test. If the repository's check conventions call for one, add a check that reads the materialized `home-files`/activation output (per the mutation-testing learnings: read the materialized output, never the option value), registered in `tests/shared-checks.nix`.

### U3. Trust the nix-community cache in shared nix settings

- **Goal:** Both hosts fetch from `https://nix-community.cachix.org` as a trusted substituter (R5, KTD4).
- **Requirements:** R5.
- **Dependencies:** None (independent of U1/U2).
- **Files:** `modules/shared/nix-settings.nix`.
- **Approach:**
  1. Add `nix.settings.substituters = [ "https://cache.nixos.org" "https://nix-community.cachix.org" ]` and `nix.settings.trusted-public-keys = [ "cache.nixos.org-1:6NCHdD59X431o0gWypbMrAURkbJ16ZPMQFGspcDShjY=" "nix-community.cachix.org-1:mB9FSh9qf2dCimDSUo8Zy7bkq5CX+/rkCWyvRCYg3Fs=" ]`.
  2. Setting the full lists (not `extra-*`) is deliberate: it makes the trusted set declarative on both hosts; dropping cache.nixos.org would break default-cache fetches.
- **Patterns to follow:** the module's existing `nix.settings.*` declarations; the darwin `mkForce` is scoped to `auto-optimise-store` and does not conflict.
- **Test scenarios:**
  - Happy path: both hosts' generated `/etc/nix/nix.conf` (NixOS) and nix-daemon settings (darwin) contain both substituters and both keys.
  - Edge: the darwin host's `nix.enable = true` means nix-darwin owns `/etc/nix/nix.conf`, so the shared settings must appear there too — verify the materialized darwin config, not just the NixOS one.
- **Verification:** `nix eval` the host toplevels' `nix.settings` values (or read the materialized `etc` entries through `tests/lib/etc-file.nix` conventions) for both host kinds; add a check in the applicable registry only if the conventions require one for this file.
- **Execution note:** pure config; materialized-output verification is the proof.

## Verification Contract

- `nix fmt -- --ci` — formatting (macOS has no local formatter; deferred to CI's `fmt` job when not run on a Linux builder).
- `nix flake check --no-build` — the primary gate for this change: catches the omp input resolution, module evaluation, and check registration.
- `nix eval .#darwinConfigurations --apply builtins.attrNames` and per-host derivation evaluation per the repository-reference commands — proves both host kinds still evaluate.
- Materialized-output reads (activation script content for `~/.omp/agent/config.yml`, `/etc/nix/nix.conf` entries) — the evidence for R3/R4/R5.
- Owner-run `nr switch` on each host is the hardware check; results reported separately, never substituted by this run's evidence.
- Pre-push: `git diff --check`, `markdownlint-cli2` on changed Markdown (the plan artifact), `nix fmt -- --ci` where available.

## Definition of Done

- All three units complete with their verification evidence recorded.
- `nix flake check --no-build` green on the current head.
- No dead ends left: no commented-out omp settings, no unused module imports, no leftover scratch artifacts in the diff.
- The plan artifact itself is the only untracked file a reviewer expects; the code diff carries no plan-ID references.
- Unapplied review findings, if any, listed under `Unapplied review findings` in the PR body with their tags and evidence.
