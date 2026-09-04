---
title: Fix Operator-Blocking Skips, Akmods Key Probe, and Flatpak Autostart - Plan
type: fix
date: 2026-09-04
artifact_contract: ce-unified-plan/v1
artifact_readiness: implementation-ready
product_contract_source: ce-plan-bootstrap
execution: code
---

# Fix Operator-Blocking Skips, Akmods Key Probe, and Flatpak Autostart - Plan

## Goal Capsule

- **Objective:** Fix three related skip and autostart defects: retire `operator-blocking` skip records once the host converges, enable the `akmods-signing-key-present` probe to read its privileged path via a new `privileged-file` probe kind, and ensure Discord and Telegram Flatpaks recover from login-time GL extension race conditions through bounded systemd restart drop-ins.
- **Means:**
  1. Add record clearance (`rm -f`) on the converged execution paths in `.chezmoiscripts/30-components/run_onchange_before_10-nvidia.sh.tmpl` for all four `operator-blocking` sites (KTD1).
  2. Implement the `privileged-file` capability probe kind in `.install-prerequisites.sh` using non-refreshing `timeout 5 sudo -nN test -f "$path"`, and reclassify `akmods-signing-key-present` in `.chezmoidata/.capability-registry.tsv` (KTD2).
  3. Harden sudo detection in `.chezmoiscripts/30-linux/run_after_setup-podman-cluster.sh.tmpl` against missing binaries on PATH, and pass `</dev/null` in `.ci/test-capability-cache.sh` (KTD3).
  4. Add systemd user drop-ins `Restart=on-failure` with `RestartSec=2s` for `app-discord@autostart.service` and `app-telegram@autostart.service` with gating in `dot_config/systemd/user/.chezmoiignore` (KTD4).
- **Authority:** GitHub issues #382, #381, and #379; skip contract in `AGENTS.md` and `.chezmoitemplates/skip.sh.tmpl`.
- **Execution profile:** Source-state script and configuration updates plus CI test gates.
- **Stop conditions:** Stop if `.ci/check-skip-declarations.sh` or `.ci/test-capability-cache.sh` fails to reconcile after two passes.
- **Tail ownership:** The invoking LFG pipeline owns commits, push, PR creation, and CI monitoring.

---

## Product Contract

### Summary

This change resolves three defects deferred from or uncovered after recent NVIDIA and autostart changes:
1. `operator-blocking` records in `run_onchange_before_10-nvidia.sh.tmpl` stay recorded forever even after an operator clears the blocker and the host converges (#382).
2. The `akmods-signing-key-present` probe executes unprivileged `[[ -f "$path" ]]` against `/etc/pki/akmods/certs/public_key.der`, but that directory is mode 0750 `root:akmods`, causing the unprivileged test to always fail with Permission Denied (#381).
3. `app-discord@autostart.service` fails at login due to Flatpak 1.18.1's GL extension merge-dirs race condition, and because the unit generator emits `Restart=no`, Discord never recovers (#379). Telegram shares the same GL extension and risk.

### Problem Frame

- **Issue #382:** `prune_stale_skip_records` explicitly ignores `operator-blocking` records because no render-time probe monitors them. A converged host that resolves the conflict or mints the key and re-runs `chezmoi apply` never clears the old skip file in `~/.local/state/chezmoi/skips/`. `dotfiles-skips` continues reporting the host as unconverged.
- **Issue #381:** `.install-prerequisites.sh` resolves `absolute-file` as unprivileged `[[ -f "$path" ]]`. Because `/etc/pki/akmods/certs` is `drwxr-x---. root akmods` and the applying user is not in the `akmods` group, the probe always evaluates to `unavailable`. The two `transient-blocking` sites waiting on it (`mok-generate-awaiting-builder` and `mok-enroll-awaiting-builder-key`) never self-heal.
- **Issue #379:** Flatpak 1.18.1 introduced a regression where minor transient errors accessing extension directories during early login trigger `Extension org.freedesktop.Platform.GL.default has invalid merge-dirs`. Systemd generator units default to `Restart=no`, leaving Discord and Telegram failed instead of restarting once session services settle.

### Requirements

- R1. When NVIDIA package installation converges (either all packages already present or newly installed without conflicts), any previously recorded `nvidia-branch-conflict`, `nvidia-package-availability-unknown`, and `nvidia-branch-packages-unavailable` skip records are deleted.
- R2. When MOK enrollment converges (`mok_state == present`), the `mok-enroll-no-keypair` record is deleted.
- R3. `.install-prerequisites.sh` provides a `privileged-file` capability probe kind using non-refreshing `timeout 5 sudo -nN test -f "$path"`.
- R4. `akmods-signing-key-present` in `.chezmoidata/.capability-registry.tsv` uses kind `privileged-file` and side-effect `sudo-credential-probe`.
- R5. Sudo presence in `run_after_setup-podman-cluster.sh.tmpl` is checked via `command -v sudo` before invoking `sudo -n true`, preventing command-not-found failures in restricted environments.
- R6. Discord and Telegram autostart units receive a drop-in override setting `Restart=on-failure` and `RestartSec=2s`.
- R7. The systemd user drop-in files deploy only on Linux hosts where Flatpaks are enabled.

### Key Decisions

- KD1. **Clear operator-blocking records at converged path call sites in `run_onchange_before_10-nvidia.sh.tmpl`.** Governs R1, R2. Skip declarations remain for early exits; non-exiting converged execution directly deletes the stale skip file via `rm -f`.
- KD2. **Adopt `privileged-file` probe kind rather than modifying user group memberships.** Governs R3, R4. Group membership changes do not affect running processes without re-login, whereas `sudo -nN test -f` works immediately and safely without refreshing credentials.
- KD3. **Deploy systemd user service drop-in overrides.** Governs R6, R7. Systemd drop-ins at `~/.config/systemd/user/app-<name>@autostart.service.d/restart.conf` override generator-created `Restart=no` cleanly without modifying desktop files.

### Scope Boundaries

- No new skip forms or directions are added to `skip.sh.tmpl`; the existing four forms and four directions are preserved.
- No changes to DKMS module compilation or enrollment logic itself.
- Native autostart desktop entries remain untouched; only Flatpak autostart units receive restart drop-ins.

### Sources

- Issue #382: `https://github.com/hyperlapse122/dotfiles/issues/382`
- Issue #381: `https://github.com/hyperlapse122/dotfiles/issues/381`
- Issue #379: `https://github.com/hyperlapse122/dotfiles/issues/379`
- Incident doc: `docs/solutions/integration-issues/fedora-akmods-builder-missing-nvidia-mok-deadlock.md`

---

## Planning Contract

### Key Technical Decisions

- KTD1. **Explicit `rm -f` on converged code paths for operator-blocking sites.**
  In `run_onchange_before_10-nvidia.sh.tmpl`:
  - In `install_nvidia_packages`: when `[[ "${#missing[@]}" -eq 0 ]]`, remove all three package-related skip records (`nvidia-branch-conflict`, `nvidia-package-availability-unknown`, `nvidia-branch-packages-unavailable`).
  - Also remove each respective record after each individual check passes.
  - In `enroll_dkms_mok`: when `[[ "${mok_state}" == present ]]`, remove `install-nvidia-fedora__mok-enroll-no-keypair`.
- KTD2. **Add `privileged-file` kind to `.install-prerequisites.sh` and registry.**
  - In `.install-prerequisites.sh`: resolve `privileged-file` using `timeout 5 sudo -nN test -f "$path"` when not root.
  - In `.chezmoidata/.capability-registry.tsv`: update `akmods-signing-key-present` to use `privileged-file` and `sudo-credential-probe`.
- KTD3. **Defensive sudo probe in `setup-podman-cluster` and hermetic stdin in test.**
  - In `run_after_setup-podman-cluster.sh.tmpl`: gate `sudo -n true` behind `command -v sudo`.
  - In `.ci/test-capability-cache.sh`: update `podman_run` to redirect stdin from `/dev/null`, and update the sudo call count assertion for the new probe.
- KTD4. **Systemd drop-ins with `.chezmoiignore` gating.**
  - Files:
    - `dot_config/systemd/user/app-discord@autostart.service.d/restart.conf`
    - `dot_config/systemd/user/app-telegram@autostart.service.d/restart.conf`
  - Gated in `dot_config/systemd/user/.chezmoiignore` on Linux and `features.flatpaks`.

### Sequencing

1. U1 (`privileged-file` in `.install-prerequisites.sh` and registry) + U2 (`setup-podman-cluster` sudo check and test-capability-cache updates).
2. U3 (operator-blocking skip record removal in `run_onchange_before_10-nvidia.sh.tmpl`).
3. U4 (systemd restart drop-ins and `.chezmoiignore` in `dot_config/systemd/user`).
4. U5 (verification suite execution).

---

## Implementation Units

### U1. Implement `privileged-file` probe kind for `akmods-signing-key-present`

- **Requirements:** R3, R4
- **Files:**
  - `.install-prerequisites.sh`
  - `.chezmoidata/.capability-registry.tsv`
- **Approach:**
  - In `.install-prerequisites.sh`, add `privileged-file)` resolver branch:
    ```bash
    privileged-file)
      case "$key" in
        akmods-signing-key-present) path=/etc/pki/akmods/certs/public_key.der ;;
        *) capability_cache_fail "privileged-file key ${key@Q} has no reviewed path" ;;
      esac
      if [[ "$(id -u)" == 0 ]]; then
        [[ -f "$path" ]]
      else
        timeout 5 sudo -nN test -f "$path" >/dev/null 2>&1
      fi
      ;;
    ```
  - In `.chezmoidata/.capability-registry.tsv`, change kind of `akmods-signing-key-present` from `absolute-file` to `privileged-file`, and side-effect to `sudo-credential-probe`.
- **Verification:** `.ci/test-capability-cache.sh`

### U2. Robust sudo handling and test-capability-cache fixture assertions

- **Requirements:** R5
- **Files:**
  - `.chezmoiscripts/30-linux/run_after_setup-podman-cluster.sh.tmpl`
  - `.ci/test-capability-cache.sh`
- **Approach:**
  - In `run_after_setup-podman-cluster.sh.tmpl`, guard `sudo` execution with `command -v sudo`:
    ```bash
    have_sudo=false
    if [[ "$(id -u)" == 0 ]]; then
      SUDO=()
      have_sudo=true
    elif command -v sudo >/dev/null 2>&1; then
      SUDO=(sudo)
      if [[ -t 0 ]] || sudo -n true 2>/dev/null; then
        have_sudo=true
      fi
    fi
    ```
  - In `.ci/test-capability-cache.sh`:
    - In `podman_run`, pass `</dev/null`.
    - In the capability cache fixture checks, account for both `sudo-usable` and `privileged-file` probes.
- **Verification:** Run `.ci/test-capability-cache.sh`.

### U3. Retire operator-blocking records on converged paths

- **Requirements:** R1, R2
- **Files:**
  - `.chezmoiscripts/30-components/run_onchange_before_10-nvidia.sh.tmpl`
- **Approach:**
  - Add helper function `clear_nvidia_skip_record`:
    ```bash
    clear_nvidia_skip_record() {
      local site="$1"
      rm -f "${XDG_STATE_HOME:-$HOME/.local/state}/chezmoi/skips/install-nvidia-fedora__${site}" 2>/dev/null || true
    }
    ```
  - In `install_nvidia_packages`:
    - When `[[ "${#missing[@]}" -eq 0 ]]`: call `clear_nvidia_skip_record` for `nvidia-branch-conflict`, `nvidia-package-availability-unknown`, and `nvidia-branch-packages-unavailable`.
    - After `conflicting_nvidia_branch` passes: clear `nvidia-branch-conflict`.
    - After `available` check passes: clear `nvidia-package-availability-unknown`.
    - After `unavailable` check passes: clear `nvidia-branch-packages-unavailable`.
  - In `enroll_dkms_mok`:
    - Immediately after `mok_state` checks pass (when `mok_state == present`): clear `mok-enroll-no-keypair`.
- **Verification:** `.ci/check-skip-declarations.sh`

### U4. Flatpak autostart systemd service restart drop-ins

- **Requirements:** R6, R7
- **Files:**
  - `dot_config/systemd/user/app-discord@autostart.service.d/restart.conf` (new)
  - `dot_config/systemd/user/app-telegram@autostart.service.d/restart.conf` (new)
  - `dot_config/systemd/user/.chezmoiignore` (new)
- **Approach:**
  - Create `dot_config/systemd/user/app-discord@autostart.service.d/restart.conf`:
    ```ini
    [Service]
    Restart=on-failure
    RestartSec=2s
    ```
  - Create `dot_config/systemd/user/app-telegram@autostart.service.d/restart.conf`:
    ```ini
    [Service]
    Restart=on-failure
    RestartSec=2s
    ```
  - Create `dot_config/systemd/user/.chezmoiignore`:
    ```gotemplate
    {{ if or (ne .chezmoi.os "linux") (not (default dict .features).flatpaks) -}}
    app-discord@autostart.service.d/**
    app-telegram@autostart.service.d/**
    {{ end }}
    ```
- **Verification:** Test render with scratch destination and check systemd override syntax.

---

## Verification Contract

| Check | Proves | Units |
|---|---|---|
| `.ci/check-skip-declarations.sh` | Declaration syntax, sentinels, and matrix reconciliation | U3 |
| `.ci/test-capability-cache.sh` | Capability registry, probe resolution, cache stability, and tests | U1, U2 |
| `systemd-analyze verify` or `systemctl --user cat` | Systemd drop-in override syntax and resolution | U4 |
| Scratch destination `chezmoi managed` | Ignore gating on Linux / flatpaks feature flag | U4 |
| `git diff --check` | Clean diff without trailing whitespace or formatting errors | all |

---

## Definition of Done

- All requirements R1 through R7 are implemented and verified.
- All verification contract tests pass cleanly.
- Commits use lowercase conventional commit format.
- PR description closes issues #382, #381, and #379 (`Closes #382, Closes #381, Closes #379`).
