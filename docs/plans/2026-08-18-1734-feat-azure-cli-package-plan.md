---
title: Add Azure CLI package - Plan
type: feat
date: 2026-08-18
artifact_contract: ce-unified-plan/v1
artifact_readiness: implementation-ready
execution: code
product_contract_source: ce-plan-bootstrap
---

# Add Azure CLI package - Plan

## Goal Capsule

- **Objective:** `az` (Azure CLI) is installed and kept current by the native package manager on every managed Fedora and macOS host.
- **Means:** manifest-declared native delivery — DNF from the Microsoft RHEL 10 prod repo on Fedora, the homebrew-core formula on macOS (KTD1, KTD4).
- **Authority:** the user's in-session direction (RHEL 10 repo for Fedora; no Jetson install) → the cited Microsoft install docs → repo conventions (AGENTS.md, the packages.yaml header contract).
- **Stop conditions:** the manifest validator or CI packages tests fail in a way the manifest cannot satisfy, or a load-bearing fact below proves false (e.g. the RHEL 10 prod repo stops carrying azure-cli).
- **Execution profile:** data-only packaging change; smoke-first verification through existing CI scripts and scratch renders; no new test files.
- **Tail ownership:** LFG ships the branch (commit, push, PR, CI watch).

---

## Product Contract

### Summary

Add Azure CLI to `.chezmoidata/packages.yaml` — the single source of truth for package provisioning — so Fedora hosts install `azure-cli` from the Microsoft RHEL 10 prod DNF repo, macOS hosts install the `azure-cli` Homebrew formula, and the Ubuntu/Jetson target is explicitly excluded. The authority ledger gains the new source and an `azureCli` capability, and the render-time validator gains the matching canonical-origin entry.

### Problem Frame

The user needs `az` on managed hosts. Repo policy forbids ad-hoc installs: every package, repo, and key is declared in packages.yaml, and the cross-platform authority ledger records one delivery owner per OS. Azure CLI is absent from the manifest today, so nothing installs it.

### Requirements

**Fedora delivery**

- R1. The Fedora installer imports the Microsoft 2025 signing key, writes the `packages-microsoft-com-prod` DNF repo (baseurl `https://packages.microsoft.com/rhel/10/prod/`, `gpgcheck=1`), and installs `azure-cli` in its main package transaction.

**macOS delivery**

- R2. The Homebrew installer converges the `azure-cli` homebrew-core formula on macOS.

**Platform scope**

- R3. Ubuntu/Jetson receives no Azure CLI delivery; the authority ledger records the exclusion as `notApplicable` with a reason.

**Ledger integrity**

- R4. The authority ledger declares the new DNF source (backend `dnf`, canonical origin, trusted) and an `azureCli` capability with sentinel `az`, complete per-platform dispositions, and full architecture coverage.
- R5. `packages-validate.tmpl` accepts the new source through its canonical-origin allowlist, so render-time and CI validation keep passing.

### Key Decisions

- **Ubuntu/Jetson is excluded from Azure CLI delivery.** (session-settled: user-directed — chosen over apt delivery from `packages.microsoft.com/repos/azure-cli`, which supports Ubuntu 24.04 noble on arm64: the host owner scoped Azure CLI off Thor.) Governs R3.

### Scope Boundaries

- No pipx, mise, or install-script delivery of Azure CLI on any platform — the manifest's native-manager-only ownership rule applies.
- No Fedora COPR or Flatpak for Azure CLI.
- No Jetson apt source or keyring for `packages.microsoft.com` — revisit only with an explicit host-owner decision.
- No teardown or removal handling for hosts that installed `az` by hand; the repo adds no teardown scripts.

---

## Planning Contract

### Key Technical Decisions

- KTD1. **Fedora delivery uses the Microsoft RHEL 10 prod repo.** (session-settled: user-directed — chosen over the legacy `https://packages.microsoft.com/yumrepos/azure-cli` repo: that repo is retired — el7-only, newest azure-cli 2.38.2 of 2024-06 — while `https://packages.microsoft.com/rhel/10/prod/` carries current azure-cli builds for x86_64 and aarch64, both verified against live repodata on 2026-08-18.) The manifest writes the `.repo` verbatim through `dnfRepos`, matching the existing declarative entries, instead of installing the vendor's `packages-microsoft-prod.rpm` config RPM from the Microsoft dnf doc.
- KTD2. **The repo trusts the Microsoft 2025 signing key.** Microsoft's dnf install doc keys RHEL 10-family repos on `https://packages.microsoft.com/keys/microsoft-2025.asc` (HTTP 200 verified). The key joins `keys:` for `rpm --import` and the repo's `gpgkey`. The repo file enables `gpgcheck=1` only, matching the Edge/Cider/Chrome entries; `repo_gpgcheck` stays off.
- KTD3. **The validator's canonical-origin allowlist gains the new source in the same change.** `.chezmoitemplates/packages-validate.tmpl` hard-fails any authority source missing from its `$canonicalOrigins` map, and it runs at render time in every package installer and in CI. Adding the source to packages.yaml without the validator entry would break every render. New source name `microsoftProd`, origin `https://packages.microsoft.com/rhel/10/prod`.
- KTD4. **macOS uses the homebrew-core formula.** Per Microsoft's macOS install doc (`brew install azure-cli`, requires macOS 13+). The capability follows the `gpgSuite`/`jq` formula pattern: `kind: formula, source: homebrewCore, elevation: none, greedy: false`.
- KTD5. **Fedora arm64 is native.** The RHEL 10 prod repo publishes azure-cli aarch64 RPMs (verified in `repodata/primary.xml.gz` on 2026-08-18), so the fedora architectures are `{ amd64: native, arm64: native }` — unlike the x86_64-only Edge/Chrome/Cider rows, which carry `arm64: unresolved`.

### Assumptions

- Managed macOS hosts run macOS 13 or later; the azure-cli formula requires it.
- The azure-cli RHEL 10 RPM's dependencies resolve on current Fedora releases; the package is Python-based with few system dependencies. If a future Fedora release breaks resolution, the tracked response is re-evaluating delivery, not a silent pipx fallback.
- The capability is unconditional on every Fedora and macOS host. The G0/G1 release-gate counters are unaffected: no `gateClosing` is added and no new ubuntu `unresolved` state appears.

### Risks

| Risk | Mitigation |
|---|---|
| The prod repo exposes every Microsoft prod package to dnf, not only azure-cli | Same trust anchor as the existing Edge repo (packages.microsoft.com plus a Microsoft key); accepted scope of the supported RHEL 10 delivery path |
| An RHEL 10 repo on Fedora is a cross-distribution substitution Microsoft does not list as supported | azure-cli RPMs are dependency-light; the next apply smokes the install path; rollback is removing the manifest entries |
| Microsoft rotates signing keys (the 2025 key supersedes `microsoft.asc` for RHEL 10) | The key URL is pinned verbatim in `keys:` and `gpgkey`; a rotation surfaces as a dnf GPG error at install time, never silent drift |

### Sources

- User-supplied Microsoft docs: `install-azure-cli-linux.md`, `includes/cli-install-linux-dnf.md`, `includes/cli-install-linux-apt.md`, `install-azure-cli-macos.md` (MicrosoftDocs/azure-docs-cli, main).
- Live probes, 2026-08-18: `yumrepos/azure-cli` package listing (el7-only, max 2.38.2); `rhel/10/prod/repodata/primary.xml.gz` (azure-cli x86_64 and aarch64 present); `keys/microsoft-2025.asc` (HTTP 200).
- Repo consumers: `.chezmoiscripts/20-linux-fedora/run_onchange_before_fedora.sh.tmpl` (legacy lists), `.chezmoiscripts/20-darwin/run_onchange_before_homebrew.sh.tmpl` (authority `macos.owner == "homebrew"`), `.chezmoiscripts/20-linux-ubuntu/run_onchange_before_jetson.sh.tmpl` (authority `ubuntu.owner == "apt"`), `.chezmoitemplates/packages-validate.tmpl` (schema and canonical origins).

---

## Implementation Units

### U1. Declare Azure CLI in the manifest and the validator

**Goal:** Azure CLI is declared across the legacy Fedora lists, the authority ledger, and the validator allowlist in one atomic change, so every managed Fedora and macOS host converges `az` and the Jetson stays excluded.

**Requirements:** R1, R2, R3, R4, R5.

**Dependencies:** none.

**Files:**

- `.chezmoidata/packages.yaml`
- `.chezmoitemplates/packages-validate.tmpl`

**Approach:**

1. In packages.yaml `linux.fedora.keys`, append `https://packages.microsoft.com/keys/microsoft-2025.asc` with a comment naming it the Azure CLI RHEL 10 prod repo key.
2. In `linux.fedora.dnfRepos`, append an entry with `id: azure-cli` whose `content` is the `[packages-microsoft-com-prod]` repo block — baseurl `https://packages.microsoft.com/rhel/10/prod/`, `enabled=1`, `gpgcheck=1`, `gpgkey=https://packages.microsoft.com/keys/microsoft-2025.asc` — with a comment recording KTD1's rejected alternative.
3. In `linux.fedora.packages`, append `azure-cli` under a `# Cloud provider CLI` comment near the CLI utilities group.
4. In `authority.sources`, append `microsoftProd` with `backend: dnf`, `origin: https://packages.microsoft.com/rhel/10/prod`, `trusted: true`.
5. In `authority.capabilities`, append the `azureCli` capability (sentinel `az`) in the CLI cluster near `githubCli`/`powershell`: fedora `managed` / `dnf` / `azure-cli` / source `microsoftProd` / both arches `native`; macos `managed` / `homebrew` / formula `azure-cli` / `homebrewCore` / `elevation: none` / `greedy: false`; ubuntu `notApplicable` with a reason naming the host-owner exclusion and the apt path that remains if it is revisited.
6. In packages-validate.tmpl, add `"microsoftProd" "https://packages.microsoft.com/rhel/10/prod"` to the `$canonicalOrigins` dict.

**Execution note:** This is manifest data plus its validator; prefer render and smoke verification over unit coverage. The scenarios below run through the repo's existing CI scripts and scratch renders.

**Patterns to follow:** the `microsoftEdge` source plus `edge` capability in packages.yaml; the `1password` and `cider` `dnfRepos` entries; the `gpgSuite` and `jq` Homebrew formula capabilities; the `$canonicalOrigins` dict in packages-validate.tmpl.

**Test scenarios:**

- Scratch-render the Fedora installer with the AGENTS.md verification harness: the rendered script imports `microsoft-2025.asc`, writes the `packages-microsoft-com-prod` repo with the RHEL 10 prod baseurl, and installs `azure-cli`.
- Render the Homebrew installer: the generated Brewfile carries the `azure-cli` formula.
- Render the Jetson installer: no `azure-cli` line renders (ubuntu is `notApplicable`), and `.ci/test-jetson-installer-render.sh` still passes.
- `.ci/test-packages-manifest.sh` passes, including its mutation tests — the validator still rejects undeclared sources while accepting `microsoftProd`.
- `.ci/test-package-ownership.sh` passes — sentinel `az` is unique and `azure-cli` has no owner conflict with mise, externals, or the release lock.

**Verification:** all three CI scripts exit 0; the scratch renders show the expected lines; `git diff --check` and a scoped `git status` stay clean.

---

## Verification Contract

| Gate | Command / check | Done signal |
|---|---|---|
| Manifest schema and mutation tests | `.ci/test-packages-manifest.sh` | exits 0 |
| Cross-owner consistency | `.ci/test-package-ownership.sh` | exits 0 |
| Jetson render assertions | `.ci/test-jetson-installer-render.sh` | exits 0 |
| Fedora installer render | scratch render of `.chezmoiscripts/20-linux-fedora/run_onchange_before_fedora.sh.tmpl` per the AGENTS.md harness | key import, repo block, and `azure-cli` package all present |
| Homebrew render | scratch render of `.chezmoiscripts/20-darwin/run_onchange_before_homebrew.sh.tmpl` | Brewfile contains the `azure-cli` formula |
| Diff hygiene | `git diff --check`, scoped `git status` | clean, limited to the two files |
| Push-time CI | `render-dotfiles.yml` and `ci.yml` on the PR | terminal green (watched in the shipping tail) |

First-apply side effect to disclose in the PR: the onchange Fedora installer reruns, imports the Microsoft 2025 key, writes the new repo, and installs `azure-cli`. No service reloads are involved.

---

## Definition of Done

- One commit carries both files (data and validator must land together; KTD3).
- Every Verification Contract gate above passes locally.
- No Jetson apt source, keyring, or package line was added anywhere (R3).
- The diff is limited to `.chezmoidata/packages.yaml` and `.chezmoitemplates/packages-validate.tmpl`.
- No abandoned-attempt artifacts remain in the working tree.
