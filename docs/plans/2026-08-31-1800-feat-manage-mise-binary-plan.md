---
artifact_contract: ce-unified-plan/v1
artifact_readiness: implementation-ready
product_contract_source: ce-plan-bootstrap
execution: code
---

# Manage mise CLI as Managed Binary

## Goal Capsule

- **Objective**: Manage the `mise` CLI as an authoritative standalone external binary tracked through `packages/release-lock` across Linux (glibc & musl) and macOS architectures, removing reliance on host OS package managers (DNF COPR).
- **Means**: Register `mise` in `packages/release-lock/src/registry.ts`, lock release checksums into `.chezmoidata/releases.json`, declare its delivery in `.chezmoiexternals/dev-tools.toml`, register the command unit in `.chezmoidata/commands.yaml`, and prune legacy COPR/RPM package declarations (KTD1-KTD4).
- **Authority Hierarchy**: `packages/release-lock` lock data > `.chezmoiexternals/dev-tools.toml` delivery > `.chezmoidata/commands.yaml` reconciliation > `.chezmoidata/packages.yaml` OS packages.
- **Stop Conditions**: Stop and report if upstream `jdx/mise` asset naming changes or if `packages/release-lock` fails to resolve releases.

## Product Contract

### Summary

`mise` (https://github.com/jdx/mise) is the polyglot runtime and tool manager in this dotfiles repository. Previously installed on Fedora via DNF through the `jdxcode/mise` COPR repository, it is now transitioned to a first-class managed binary managed by `.chezmoiexternals/dev-tools.toml` and locked in `.chezmoidata/releases.json`.

### Problem Frame

Operating system package managers (DNF Copr on Fedora, extrepo on Debian/Ubuntu) couple `mise` version updates to distro-specific package repositories. Other developer CLI binaries in this repository (`uv`, `omp`, `agent-browser`, `buf`, `marksman`, `gh`, `garden`) are managed deterministically via `packages/release-lock` and `.chezmoiexternals/`. Managing `mise` as an external binary unifies CLI provisioning across all platforms (Linux x86_64, Linux aarch64, musl Linux, and macOS) with cryptographically verified checksums.

### Requirements

- **R1**: `packages/release-lock` must declare `mise` in `REGISTRY` using `githubRelease` against `jdx/mise`, with asset selectors covering `linux-amd64`, `linux-arm64`, `linux-amd64-musl`, `linux-arm64-musl`, `darwin-amd64`, and `darwin-arm64`.
- **R2**: `packages/release-lock` test suite in `packages/release-lock/test/registry.test.ts` must assert expected asset name patterns for all 6 target platform variants of `mise`.
- **R3**: `.chezmoidata/releases.json` must be updated with the latest resolved release version, per-platform URLs, and sha256 checksums for `mise`.
- **R4**: `.chezmoiexternals/dev-tools.toml` must declare the `[mise]` file external targeting `.local/share/chezmoi-commands/incomplete/mise/mise` with URL and sha256 derived from `release-lock-ref.tmpl`.
- **R5**: `.chezmoidata/commands.yaml` must register the `mise` unit under `commands.units` as an external producer (`producer: external`, `safetyProfile: native-single-file`, `tool: mise`, command `mise`).
- **R6**: `.chezmoidata/packages.yaml`, `.chezmoiscripts/20-base/fedora/run_onchange_before_base.sh.tmpl`, and `.chezmoiscripts/30-components/fedora/run_onchange_before_80-devtools.sh.tmpl` must remove DNF COPR `jdxcode/mise` and package `mise` declarations.
- **R7**: `.install-prerequisites.sh` and `README.md` must be updated to remove references to the Fedora `jdxcode/mise` COPR.

### Success Criteria

1. `bun test` in `packages/release-lock` passes cleanly with `mise` selector assertions verified.
2. `mise` is locked in `.chezmoidata/releases.json` with all 6 platform assets having valid URLs and sha256 digests.
3. `chezmoi execute-template` renders `.chezmoiexternals/dev-tools.toml` and `.chezmoidata/commands.yaml` with the complete `mise` configuration and valid checksums.
4. No leftover `jdxcode/mise` COPR or DNF package references remain in `.chezmoidata/packages.yaml` or provisioning scripts.

## Planning Contract

### Key Technical Decisions

- **KTD1: Asset naming pattern**: Upstream `jdx/mise` publishes GitHub releases with tag format `vYYYY.M.D`. Assets are named `mise-${tag}-${os}-${arch}${libc === "musl" ? "-musl" : ""}` where `os` is `linux` or `macos` (mapped from `darwin`), and `arch` is `x64` (mapped from `amd64`) or `arm64`. `linuxMusl: true` enables static musl targets.
- **KTD2: External delivery mechanism**: `.chezmoiexternals/dev-tools.toml` uses `type = "file"` with `executable = true` placing the binary at `.local/share/chezmoi-commands/incomplete/mise/mise`, with sha256 checksum validation.
- **KTD3: Command reconciliation unit**: `.chezmoidata/commands.yaml` registers `mise` with `producer: external`, `proofEligible: true`, `mode: "0755"`, `platforms: [linux, macos]`, linking `mise` to `~/.local/bin/mise`.
- **KTD4: Removal of OS package references**: Pruning `jdxcode/mise` COPR and `mise` package from Fedora manifests prevents duplicate or conflicting versions between RPM and `~/.local/bin/mise`.

### Technical Design

```
GitHub Release (jdx/mise)
       │
       ▼
packages/release-lock (resolves URLs & sha256 per platform)
       │
       ▼
.chezmoidata/releases.json
       │
       ├──► .chezmoiexternals/dev-tools.toml (downloads binary to staging)
       │           │
       │           ▼
       │     .local/share/chezmoi-commands/incomplete/mise/mise
       │           │
       └──► .chezmoidata/commands.yaml ──► command-reconcile (links ~/.local/bin/mise)
```

### Implementation Constraints

- Never hand-edit `.chezmoidata/releases.json`; generate it via `packages/release-lock` CLI.
- Ensure `$isMuslLinux` probe is correctly positioned in `.chezmoiexternals/dev-tools.toml` to support musl Linux targets.
- All tests in `packages/release-lock` must pass.

## Implementation Units

### U1. Register `mise` in `packages/release-lock` and update tests
- **Goal**: Add `mise` specification to `REGISTRY` in `packages/release-lock/src/registry.ts` and update expected test cases in `packages/release-lock/test/registry.test.ts`.
- **Files**: `packages/release-lock/src/registry.ts`, `packages/release-lock/test/registry.test.ts`
- **Verification**: Run `bun test` in `packages/release-lock` to verify registry tests pass.

### U2. Resolve `mise` into `.chezmoidata/releases.json`
- **Goal**: Run `packages/release-lock` CLI to fetch and lock the latest `mise` release metadata into `.chezmoidata/releases.json`.
- **Files**: `.chezmoidata/releases.json`
- **Verification**: Inspect `.chezmoidata/releases.json` to ensure `mise` entry is present with valid `version`, `artifacts` for all 6 platforms, and non-null `sha256` digests.

### U3. Declare `mise` in `.chezmoiexternals/dev-tools.toml` and `.chezmoidata/commands.yaml`
- **Goal**: Configure chezmoi external for `mise` and register the command unit in `commands.yaml`.
- **Files**: `.chezmoiexternals/dev-tools.toml`, `.chezmoidata/commands.yaml`
- **Verification**: Run template execution test using scratch `op` stub to verify `dev-tools.toml` and `commands.yaml` render without errors.

### U4. Prune legacy DNF package and COPR references
- **Goal**: Remove `jdxcode/mise` COPR and `mise` package entries from package manifests, provisioners, and installation prerequisites.
- **Files**: `.chezmoidata/packages.yaml`, `.chezmoiscripts/20-base/fedora/run_onchange_before_base.sh.tmpl`, `.chezmoiscripts/30-components/fedora/run_onchange_before_80-devtools.sh.tmpl`, `.install-prerequisites.sh`, `README.md`
- **Verification**: Grep for `jdxcode/mise` to ensure zero unintended occurrences remain.

### U5. Full validation
- **Goal**: Run all test suites and chezmoi dry-run checks.
- **Files**: All touched files
- **Verification**: Run `bun test` across workspaces, execute template rendering tests, and verify git diff cleanliness.

## Verification Contract

- Run `bun test` in `packages/release-lock` (or `mise -C packages exec -- vp run test`).
- Run `chezmoi execute-template` with scratch environment against `.chezmoiexternals/dev-tools.toml` and `.chezmoiscripts/00-tools/run_after_90-activate-command-links.sh.tmpl`.
- Run skip declarations check `.ci/check-skip-declarations.sh`.
- Run git diff check `git diff --check`.

## Definition of Done

- All 5 units (U1–U5) completed and verified.
- `mise` is completely managed as a standalone binary in `.chezmoiexternals/dev-tools.toml` and `.chezmoidata/commands.yaml`.
- Releases lock file `.chezmoidata/releases.json` holds locked release info for `mise`.
- No lingering references to `jdxcode/mise` COPR in Fedora package configs.
- All tests pass cleanly.
