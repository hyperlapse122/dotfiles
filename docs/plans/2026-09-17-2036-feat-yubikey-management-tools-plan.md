---
title: YubiKey Management Tools - Plan
date: 2026-09-17
type: feat
artifact_contract: ce-unified-plan/v1
product_contract_source: ce-plan-bootstrap
execution: code
---

# YubiKey Management Tools - Plan

## Goal Capsule

- **Objective:** After the next `chezmoi apply`, an operator can manage a plugged-in YubiKey from the `ykman` CLI and from the Yubico Authenticator GUI on every managed Fedora host that enables the devtools and Flatpak features and on every managed macOS host, with no manual install step.
- **Means:** Add the packages to the three installers that already run on those hosts: the Fedora devtools package list, the Fedora Flatpak list, and the macOS Brewfile (KTD1, KTD2, KTD3).
- **Product authority:** the user's decision recorded in Key Decisions, then the Requirements.
- **Execution profile:** three independent Implementation Units, each a package-list edit in one existing installer; the render contract in the Verification Contract plus CI is the acceptance gate.
- **Stop conditions:** a change that needs a new installer script is a stop, because it moves the frozen CI fan-out matrix; an Ubuntu render that gains any YubiKey entry is a stop; a render that reaches the real `op` is a stop.
- **Who finishes:** the implementing run ships all three units in one change; no follow-up run is planned.
- **Open blockers:** none.

## Product Contract

### Summary

Fedora hosts with `features.devtools` get the `yubikey-manager` RPM through the devtools installer, and Fedora hosts with `features.flatpaks` get the Yubico Authenticator Flatpak `com.yubico.yubioath` through the Flatpak installer. macOS hosts get the `ykman` formula and the `yubico-authenticator` cask through the Brewfile. Every addition follows the installer's existing only-install-missing behavior, so a host that already has a package gets no new install. Ubuntu hosts and real containers stay exactly as they are; toolbox and distrobox environments count as managed hosts.

### Problem Frame

The dotfiles already provision the smartcard stack (`opensc`, `pcsc-lite`, `pcsc-tools`) on Fedora hosts, but no host has a tool that talks to a YubiKey's own applets. Managing OATH credentials, PIV slots, or FIDO settings today means installing `ykman` or a GUI by hand on each machine, which drifts from the managed baseline.

### Requirements

**Fedora hosts**

- R1. A Fedora host with `features.devtools` has the `ykman` CLI installed from the Fedora `yubikey-manager` RPM after apply.
- R2. A Fedora host with `features.flatpaks` has the Yubico Authenticator Flatpak `com.yubico.yubioath` installed system-wide from Flathub after apply.
- R3. An Ubuntu host and a real container receive no YubiKey package from this change, even though the Flatpak installer also runs on Ubuntu hosts. Toolbox and distrobox environments are treated as managed hosts by the existing `container` fact, so they follow R1 and R2.

**macOS hosts**

- R4. A macOS host has the `ykman` CLI installed from the Homebrew formula `ykman` after apply.
- R5. A macOS host has the Yubico Authenticator app installed from the Homebrew cask `yubico-authenticator` after apply.

**Installer behavior**

- R6. Each installer installs only the entries that are missing on the host; a second apply with nothing missing installs nothing new. Upgrades of already-installed entries follow each installer's existing behavior (the macOS installer upgrades outdated formulae and greedy casks on every run).

### Key Decisions

- **Install both the `ykman` CLI and the Yubico Authenticator GUI.** (session-settled: user-directed — chosen over CLI-only and GUI-only: the CLI serves scripting and the GUI serves hands-on OATH, PIV, and FIDO management.) Governs R1, R2, R4, R5.
- **Use Yubico Authenticator as the GUI, never `yubikey-manager-qt`.** Yubico ended support for the Qt manager in 2024 and names Yubico Authenticator as its successor. Governs R2, R5.
- **Scope is managed Fedora and macOS hosts only.** The user confirmed Ubuntu (Jetson) hosts and containers are out. Governs R3.

### Scope Boundaries

- **Outside this work:** moving GPG or SSH keys onto the YubiKey, PIN or PUK setup, and `gpg-agent` or `scdaemon` integration.
- **Outside this work:** Ubuntu (Jetson) hosts and real containers. Real containers already skip every package installer through the root `.chezmoiignore`, and no script edit changes that. Toolbox and distrobox environments are not real containers; they receive the packages like any managed host.
- **No pcscd work.** The devtools installer already installs `pcsc-lite` and `pcsc-lite-ccid` on every Fedora host with `features.devtools`, and Fedora's systemd preset enables `pcscd.socket`. The daemon that the GUI and the `ykman` CCID paths need is therefore already guaranteed; this plan adds no service or unit work.
- **No new udev rule.** The `yubikey-manager` RPM pulls in `u2f-hidraw-policy`, which grants user access to FIDO hidraw devices.
- **No new installer script and no CI matrix edit.** `.ci/skip-declaration-site-matrix.yaml` lists installers by path and changes only when a script is added; this work adds none.

## Planning Contract

### Key Technical Decisions

- KTD1. **The Fedora CLI goes into the devtools installer's `# Smartcard / code signing` group.** `yubikey-manager` is a CLI that belongs beside `opensc` and `pcsc-tools`, and that installer's `rpm -q` loop already gives R6 for free. The apps installer holds GUI apps and third-party-repo packages, so it is the wrong home. Serves R1, R6.
- KTD2. **The Fedora GUI goes into the Flatpak installer as a Fedora-only entry.** The `flatpaks` array in `.chezmoiscripts/30-components/run_onchange_before_40-flatpaks.sh.tmpl` is shared by the Fedora and Ubuntu branches, so the `com.yubico.yubioath` entry is emitted inside a template guard on `$isFedora`. The Ubuntu render stays byte-identical to today's, which is how R3 is proven. The Flathub ID is `com.yubico.yubioath`; the earlier candidate `com.yubico.yauth` does not exist on Flathub. `flatpak install` skips already-installed refs, which gives R6. Serves R2, R3, R6.
- KTD3. **macOS adds one formula line and one cask line to the Brewfile heredoc in alphabetical position.** `brew "ykman"` follows `brew "podman"`, and `cask "yubico-authenticator", greedy: true` follows `cask "wezterm"`, matching the neighboring GUI casks' `greedy: true` style. `brew bundle` installs only missing entries and upgrades outdated ones, which gives R6 as stated. Serves R4, R5, R6.

### Assumptions and constraints

- Fedora 44 ships `yubikey-manager` 5.9.2; Homebrew ships formula `ykman` 5.9.2 and cask `yubico-authenticator` 7.4.1, none deprecated or disabled (checked 2026-09-17). These versions are dated context, not a gate; no package is pinned.
- Every edited script is `run_onchange_`, so each of the three installers reruns once on every host whose rendered content changed. The reruns install only the missing YubiKey packages and restart no service.
- The devtools installer inspects which packages are missing with its `rpm -q` loop and installs only those. The Flatpak installer and the Brewfile pass their whole list to `flatpak install` and `brew bundle`, which skip already-installed entries. The plan keeps each existing mechanism unchanged.

### Sequencing

The three units touch three different files and share no dependency. Any order works, and they land as one change.

## Implementation Units

### U1. Add `yubikey-manager` to the Fedora devtools package list

- **Goal:** R1 holds on every Fedora host with `features.devtools`.
- **Requirements:** R1, R6.
- **Files:** `.chezmoiscripts/30-components/run_onchange_before_80-devtools.sh.tmpl`.
- **Approach:** Append `yubikey-manager` to the `# Smartcard / code signing` group of the Fedora `dev_packages` array (KTD1). Leave the Ubuntu branch untouched.
- **Execution note:** Pure package-list edit; verification is render and install smoke, not unit coverage.
- **Test expectation:** none -- the unit changes one array entry in a shell template and no logic.
- **Verification:**
  - The Fedora render through the scratch contract in the Verification Contract contains `yubikey-manager` exactly once, inside `dev_packages`, and the `rpm -q` loop is unchanged.
  - The diff is limited to that one added line.
  - Install smoke on a Fedora host after the next apply: `rpm -q yubikey-manager` succeeds, `ykman --version` exits successfully, and `ykman list` enumerates a plugged-in key.

### U2. Add the Yubico Authenticator Flatpak, Fedora-only

- **Goal:** R2 holds on every Fedora host with `features.flatpaks` while R3 keeps Ubuntu hosts unchanged.
- **Requirements:** R2, R3, R6.
- **Files:** `.chezmoiscripts/30-components/run_onchange_before_40-flatpaks.sh.tmpl`.
- **Approach:** Add `com.yubico.yubioath` to the `flatpaks` array inside a template guard on `$isFedora` (KTD2), keeping the existing three entries and the shared install call untouched.
- **Execution note:** Pure package-list edit with one template guard; verification is render comparison per OS plus install smoke.
- **Test expectation:** none -- the unit adds one guarded array entry and no logic.
- **Verification:**
  - The Fedora render contains `com.yubico.yubioath` exactly once, inside the `flatpaks` array, and the single `flatpak install --system` call is unchanged.
  - The Ubuntu override render in the Verification Contract contains no `yubioath` and is byte-identical to the same override render of the `main` checkout. This local render is the proof of R3; the `ubuntu-arm64` CI artifact is a secondary review aid, not a gate.
  - Install smoke on a Fedora host after the next apply: `flatpak list --system --app` lists `com.yubico.yubioath`, and the Yubico Authenticator window opens and shows a plugged-in key.

### U3. Add `ykman` and Yubico Authenticator to the macOS Brewfile

- **Goal:** R4 and R5 hold on every managed macOS host.
- **Requirements:** R4, R5, R6.
- **Files:** `.chezmoiscripts/20-darwin/run_onchange_before_homebrew.sh.tmpl`.
- **Approach:** Insert `brew "ykman"` after `brew "podman"` and `cask "yubico-authenticator", greedy: true` after `cask "wezterm"` in the Brewfile heredoc (KTD3). Nothing else in the script changes.
- **Execution note:** Pure package-list edit; the template renders to an empty file on Linux because of its darwin guard, so local proof is text review and the macOS CI render.
- **Test expectation:** none -- the unit adds two heredoc lines and no logic.
- **Verification:**
  - The diff is limited to the two added lines, each in alphabetical position, and the Linux render through the scratch contract is still empty.
  - The `apply-macos` job of `.github/workflows/render-dotfiles.yml` renders the script and the `shellcheck` job lints that darwin variant without new findings.
  - Install smoke on a macOS host after the next apply: the script's own `brew bundle check --verbose` reports every entry satisfied and prints `RESULT homebrew converged`, `ykman --version` exits successfully, and `/Applications/Yubico Authenticator.app` exists.

## Verification Contract

Every changed template is rendered through the repository's scratch contract from `AGENTS.md`: a per-user scratch directory, a stub `op`, an empty config, a throwaway destination, `--source "$PWD"`, and `PATH="$scratch/bin:/usr/bin:/bin"`. The render never touches the live `$HOME` and never reaches the real `op`. `.ci/lib/render-gate-helpers.sh` implements the same contract for CI.

```sh
scratch="$HOME/.cache/agent-scratch/chezmoi-op-stub"
mkdir -p "$scratch/bin" "$scratch/target"
: > "$scratch/empty.toml"
printf '#!/usr/bin/env bash\ncase "${1-}" in whoami) printf dummy@example.invalid;; *) printf dummy-secret;; esac\n' > "$scratch/bin/op"
chmod 700 "$scratch/bin/op"
chezmoi_bin=$(command -v chezmoi)
for tmpl in \
  .chezmoiscripts/30-components/run_onchange_before_80-devtools.sh.tmpl \
  .chezmoiscripts/30-components/run_onchange_before_40-flatpaks.sh.tmpl \
  .chezmoiscripts/20-darwin/run_onchange_before_homebrew.sh.tmpl; do
  env PATH="$scratch/bin:/usr/bin:/bin" "$chezmoi_bin" --config "$scratch/empty.toml" --source "$PWD" --destination "$scratch/target" execute-template < "$tmpl" > "$scratch/target/$(basename "$tmpl" .tmpl)"
done
```

The Ubuntu variant renders on the same workstation with the `--override-data` pattern that `.ci/test-jetson-installer-render.sh` already uses. Render `run_onchange_before_40-flatpaks.sh.tmpl` and `run_onchange_before_80-devtools.sh.tmpl` through the same scratch contract with `--override-data '{"chezmoi":{"os":"linux","osRelease":{"id":"ubuntu"}}}'`, once from this checkout and once from a `main` checkout, and compare the outputs.

| Gate | Command or job | Applies to | Pass signal |
|---|---|---|---|
| Fedora render | the loop above on a Fedora workstation | U1, U2 | devtools output contains `yubikey-manager` once; flatpaks output contains `com.yubico.yubioath` once; homebrew output is empty |
| Ubuntu render | the Ubuntu `--override-data` render above | U1, U2 | rendered flatpaks and devtools scripts contain no `yubioath` or `yubikey-manager`, and each is byte-identical to the same render of `main` |
| macOS render and apply | `.github/workflows/render-dotfiles.yml`, `apply-macos` job | U3 | job green; rendered homebrew script carries both new lines |
| Shellcheck | `.github/workflows/render-dotfiles.yml`, `shellcheck` job | U1, U2, U3 | no new findings on any rendered variant |
| Whitespace and scope | `git diff --check` and a diff limited to the three installer templates and this plan document | U1, U2, U3 | clean check; no file outside the three templates and this plan document changed |
| CI | `.github/workflows/ci.yml` and `.github/workflows/render-dotfiles.yml` | all | every job green on the pull request |
| Install smoke (post-merge, operator) | the per-unit smoke checks after the next apply on one Fedora host and one macOS host | U1, U2, U3 | `ykman list` sees a plugged-in key; the GUI opens; a second `chezmoi apply` runs none of the three installers because their rendered content is unchanged, and `rpm -q yubikey-manager`, `flatpak list --system --app`, and `brew bundle check --verbose` still report every entry present |

## Definition of Done

**Global**

- R1 through R6 hold as written.
- Only the three installer templates and `docs/plans/2026-09-17-2036-feat-yubikey-management-tools-plan.md` changed; no new installer script, no `.ci/skip-declaration-site-matrix.yaml` edit, no `.chezmoiignore` edit.
- Every Verification Contract gate except the post-merge install smoke passed, including green CI on the pull request.
- No experimental or abandoned edit remains in the diff.

**Per unit**

| Unit | Done when |
|---|---|
| U1 | Fedora render shows `yubikey-manager` in the smartcard group, and the Ubuntu override render of the devtools script is unchanged |
| U2 | Fedora render shows `com.yubico.yubioath`, and the Ubuntu override render of the flatpaks script shows no YubiKey entry and is unchanged |
| U3 | macOS CI render and shellcheck are green |

**Post-apply acceptance (operator, after merge)**

- The U1 and U2 install smoke checks pass on one Fedora host.
- The U3 install smoke check passes on one macOS host.
