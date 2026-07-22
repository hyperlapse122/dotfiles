---
title: Manage Kimi Code CLI as a standalone external
date: 2026-07-22
type: refactor
artifact_contract: ce-unified-plan/v1
artifact_readiness: implementation-ready
execution: code
product_contract_source: ce-plan-bootstrap
origin: user request and Kimi Code CLI official documentation
---

# Manage Kimi Code CLI as a standalone external

## Goal Capsule

- **Objective:** Move Kimi Code CLI from mise's npm backend to the repository's managed standalone-release mechanism, matching the ownership pattern used for Codex, codegraph, and other AI CLIs.
- **Authority:** The official Kimi Code CLI installation documentation and `MoonshotAI/kimi-code` release assets define the supported platform and artifact contract; repository instructions and existing externals define local ownership and verification.
- **Execution profile:** Configuration-only migration with isolated render and archive verification; do not apply to the live home directory.
- **Stop conditions:** Stop if the latest release lacks exactly one supported platform asset, a valid GitHub `sha256:` asset digest, or the expected executable archive entry for the active platform.
- **Tail ownership:** LFG owns implementation, review, commit, PR creation, and CI observation.

---

## Product Contract

### Summary

Kimi Code CLI is already installed by mise from `npm:@moonshot-ai/kimi-code`. Replace that registry-backed installation with a checksum-verified standalone release managed in `.chezmoiexternals/ai-agents.toml`, so Kimi follows the same source-of-truth and apply lifecycle as Codex, codegraph, Claude Code, and agent-browser without leaving two competing `kimi` executables on `PATH`.

### Problem Frame

The repository's current convention assigns standalone release CLIs to grouped chezmoi externals and reserves mise for language runtimes and registry-backed tools. Kimi now publishes self-contained native archives for Linux, macOS, and Windows, but the dotfiles still install its npm package through mise, including native build allowances and a cooldown exception. That older path duplicates runtime dependencies and diverges from the current AI CLI installation pattern.

### Requirements

- R1. Kimi Code CLI must be installed from the latest official `MoonshotAI/kimi-code` GitHub release for supported Linux, macOS, and Windows architectures.
- R2. The selected platform asset must be checksum-verified from its GitHub release-asset SHA-256 digest, and rendering must fail closed for missing, duplicate, or malformed release data. The official SHA-256 sidecar remains independent verification evidence.
- R3. The managed executable must be exposed as `~/.local/bin/kimi` on POSIX and the equivalent `.exe` target on Windows without requiring a system Node.js runtime.
- R4. The existing mise npm declaration, its package build allowances, and its minimum-release-age exclusion must be removed so exactly one managed installation owns `kimi`.
- R5. Repository-facing inventories and comments must identify Kimi as an externally managed AI CLI without claiming npm/mise ownership.
- R6. Isolated rendering must prove the external resolves on the current platform, the downloaded archive contains the expected executable, and the mise configuration remains valid without Kimi-specific residue.

### Scope Boundaries

- Do not manage `~/.kimi-code/`, OAuth credentials, API keys, provider configuration, sessions, or user-generated `AGENTS.md` files.
- Do not add Kimi as an MCP server or plugin; the official CLI install contract does not require either surface.
- Do not run the upstream installer, `kimi upgrade`, `/login`, or a live chezmoi apply.
- Do not change the repository-wide latest-release policy for standalone CLIs.

### Acceptance Examples

- AE1. **Covers R1-R3.** Given a supported OS and architecture, when chezmoi renders and materializes the AI-agent externals, then the official Kimi release archive is selected, its checksum is verified, and `kimi` is installed at the repository's user-local executable path.
- AE2. **Covers R2.** Given an upstream release with a renamed or missing platform asset or invalid checksum data, when the external template renders, then rendering fails instead of producing an unverified executable.
- AE3. **Covers R4.** Given the resulting dotfiles source, when mise configuration is inspected or installed, then it contains no Kimi npm package, Kimi build allowance, or Kimi cooldown exception.
- AE4. **Covers R5-R6.** Given isolated render verification, when the changed templates and configuration are checked, then Kimi appears only under the standalone external ownership path and no live home state changes.

---

## Planning Contract

### Key Technical Decisions

- KTD1. **Use the official native release, not npm.** Kimi's official documentation recommends its standalone installer and the release publishes native assets for Linux, macOS, and Windows. The repository consumes those assets directly through chezmoi rather than executing the mutable upstream install script.
- KTD2. **Install the single executable directly.** Each current Kimi platform ZIP contains one `kimi`/`kimi.exe` entry, so use an `archive-file` external targeting `.local/bin` instead of adding a version-directory linker/pruner that only benefits multi-file layouts such as Codex and codegraph. This preserves their core pattern—latest official release resolved by chezmoi—without unnecessary state.
- KTD3. **Resolve release identity, URL, and digest from one GitHub API snapshot.** Follow the agent-browser fail-closed pattern: fetch the latest release once, validate Kimi's scoped-package tag shape, find exactly one platform asset, validate its `sha256:` digest, and use that selected asset's `browser_download_url`. The official `.sha256` sidecars remain independent upstream evidence, while GitHub's asset metadata avoids a second mutable lookup or reconstructed-URL assumption.
- KTD4. **Migrate ownership atomically.** Add the external and remove all Kimi-specific mise configuration in the same change so no committed state can install two different `kimi` binaries.

### Assumptions

- The latest release continues to publish `kimi-code-{linux|darwin|win32}-{x64|arm64}.zip` with one executable entry and GitHub asset SHA-256 digests.
- `~/.local/bin` is already the repository's cross-platform executable target for managed standalone files, as used by agent-browser and AGY.
- Kimi authentication remains intentionally user-driven through `/login`; source state must not capture credentials.

### Risks and Mitigations

- **Release naming drift:** Scoped-package tags or asset names can change. Validate both and fail the render with a Kimi-specific error rather than selecting a fallback.
- **Latest-release movement between operations:** Use one release API response for tag, asset match, and digest, then construct the download URL from that tag.
- **Hidden package-layout change:** Verify the selected archive contains exactly the expected executable during implementation and preserve `archive-file` extraction so extra future entries are ignored rather than deployed.
- **PATH ownership regression:** Search both source and rendered mise configuration for Kimi residue after removal.

### Sources and Research

- [Kimi Code CLI installation and quick start](https://www.kimi.com/help/kimi-code/cli-getting-started) — official standalone installer recommendation, supported systems, npm alternative, verification, upgrade, and authentication behavior.
- [MoonshotAI/kimi-code](https://github.com/MoonshotAI/kimi-code) — official release source and native platform assets.
- `.chezmoiexternals/ai-agents.toml` — Codex/codegraph versioned-package patterns and agent-browser's single-file, atomic release-metadata/checksum pattern.
- `dot_config/mise/config.toml` — current Kimi npm ownership, build allowances, and cooldown exception to remove.

---

## Implementation Units

### U1. Add the checksum-verified Kimi external

- **Goal:** Install the current official Kimi native executable through the grouped AI-agent external.
- **Requirements:** R1-R3, R5; KTD1-KTD3.
- **Dependencies:** None.
- **Files:** `.chezmoiexternals/ai-agents.toml`.
- **Approach:** Extend the AI CLI inventory and add a Kimi section beside the other coding agents. Resolve the latest release once with optional `GITHUB_TOKEN`, validate the scoped tag, normalize OS and architecture to upstream asset names, require one matching asset and a valid SHA-256 digest, then declare an executable `archive-file` targeting `.local/bin/kimi` with the Windows extension where applicable.
- **Patterns to follow:** The agent-browser release API/digest validation and the opencode/AGY `archive-file` target shape in `.chezmoiexternals/ai-agents.toml`.
- **Test scenarios:** Render on the active Linux platform and assert one Kimi external with the expected asset URL, archive entry, executable target, and SHA-256. Inspect the official archive and assert its selected entry is `kimi`. Confirm malformed or absent metadata is guarded by explicit validation paths in the template.
- **Verification:** The template renders successfully through the isolated chezmoi setup and the resolved release metadata matches the official latest release snapshot.

### U2. Remove mise ownership of Kimi

- **Goal:** Eliminate the previous npm installation path and its policy exceptions.
- **Requirements:** R4-R5; KTD4.
- **Dependencies:** U1.
- **Files:** `dot_config/mise/config.toml`.
- **Approach:** Remove the `npm:@moonshot-ai/kimi-code` tool, its `allow_builds` entries, and its minimum-release-age exclusion. Extend the nearby standalone-agent comment so future editors know Kimi is external-managed rather than accidentally re-adding it to mise.
- **Patterns to follow:** The existing Codex ownership comment in `dot_config/mise/config.toml` and the repository's standalone-CLI ownership rule.
- **Test scenarios:** Parse or run the repository's normal mise config validation and search the file for `kimi`, `moonshot`, and obsolete build allowances; only the explanatory external-ownership comment may remain.
- **Verification:** mise accepts the edited configuration and no Kimi package or exception remains in its managed tool graph.

### U3. Reconcile user-facing inventory and regression checks

- **Goal:** Make the ownership change discoverable and prove it without deployment.
- **Requirements:** R5-R6; AE1-AE4.
- **Dependencies:** U1, U2.
- **Files:** `README.md`, `.chezmoiexternals/ai-agents.toml`, `dot_config/mise/config.toml`.
- **Approach:** Add Kimi to the README's external AI CLI inventory if that inventory enumerates managed examples. Run isolated render checks with the repository's empty config, stub `op`, and `--source "$PWD"`; inspect the rendered external and archive rather than applying it to `$HOME`.
- **Execution note:** This is packaging/configuration work; prefer render and artifact smoke evidence over adding a unit-test framework.
- **Patterns to follow:** Root `AGENTS.md` isolated verification contract and `.github/workflows/render-dotfiles.yml` platform rendering.
- **Test scenarios:** The external template renders with the active platform's Kimi stanza; the selected official ZIP exposes the expected executable; mise configuration validates; searches show no competing Kimi install declaration; `CLAUDE.md` remains the exact `@AGENTS.md` mirror; the scoped diff and whitespace checks are clean.
- **Verification:** All isolated checks pass, the diff contains only the planned installation migration and inventory update, and no command changed live home state.

---

## Verification Contract

- V1. Render `.chezmoiexternals/ai-agents.toml` with an empty chezmoi config, repository source, throwaway destination, stub `op`, and authenticated GitHub release lookup; inspect the Kimi stanza for target, archive entry, URL, and checksum.
- V2. Download the exact selected release asset with the native GitHub CLI and inspect its archive table; expect one `kimi` executable for the active platform.
- V3. Run mise's available configuration parse/diagnostic against `dot_config/mise/config.toml`; expect no syntax or trust failure and no Kimi npm tool in the resolved configuration.
- V4. Search changed source for Kimi ownership; expect the external and explanatory documentation only, with no npm declaration, build allowance, cooldown exclusion, credentials, or generated config.
- V5. Run `git diff --check`, confirm `CLAUDE.md` is exactly `@AGENTS.md`, inspect a request-scoped diff, and verify worktree status before delivery.
- V6. Let repository CI render Linux, macOS, and Windows variants and require both `render-dotfiles.yml` and `ci.yml` to reach terminal success after push.

---

## Definition of Done

- The supported platform receives the official checksum-verified Kimi Code CLI standalone executable through `.chezmoiexternals/ai-agents.toml`.
- mise no longer installs or grants special lifecycle policy to `npm:@moonshot-ai/kimi-code`.
- Documentation accurately places Kimi with externally managed AI CLIs.
- Isolated rendering, archive inspection, mise validation, mirror verification, whitespace checks, and both CI workflows pass.
- No credentials, Kimi user configuration, live-home deployment, MCP registration, or plugin integration is introduced.
