---
title: Declared Fedora Packages Are RPM Capabilities That Bare rpm -q Classifies as Missing
date: 2026-09-20
category: integration-issues
module: chezmoi
problem_type: integration_issue
component: package_provisioning
symptoms:
  - "chezmoi apply reports declared packages uninstalled although dnf considers them already satisfied"
  - "base and podman installers leave operator-blocking skip records on every apply that cannot be cleared"
  - "install-base-fedora.sh reports: dnf left these declared base packages uninstalled: pkg-config wget"
  - "install-podman-fedora reports: dnf left these declared packages uninstalled: kubernetes-client"
root_cause: incorrect_assumption
resolution_type: code_fix
severity: high
tags:
  - fedora
  - rpm
  - dnf
  - chezmoi
  - package-management
  - skip-framework
  - capability-resolution
---

# Declared Fedora Packages Are RPM Capabilities That Bare rpm -q Classifies as Missing

## Problem

On Fedora 44, `chezmoi apply` reported declared packages as uninstalled even though they were installed. Installers exited with `operator-blocking` skip records:

```text
install-base-fedora.sh: dnf left these declared base packages uninstalled: pkg-config wget
install-podman-fedora: dnf left these declared packages uninstalled: kubernetes-client
```

`dnf install` reported that packages were already installed and took no action. The resulting skip records prevented host convergence.

## Symptoms

- `install-base-fedora.sh` reports declared packages `pkg-config` and `wget` as uninstalled after `dnf install` succeeds.
- `install-podman-fedora` reports declared package `kubernetes-client` as uninstalled.
- An `operator-blocking` skip record is written to `${XDG_STATE_HOME:-$HOME/.local/state}/chezmoi/skips/`.
- `dotfiles-skips` reports an unconverged host on every apply.
- Running manual `sudo dnf install` commands installs nothing and does not clear the skip record.

## What Didn't Work

- **Using bare `rpm -q "$pkg"` to re-inspect installation state.** A declared package name is often an RPM capability rather than a package name. On Fedora, `pkgconf-pkg-config` provides `pkg-config`, `wget2-wget` provides `wget`, and `kubernetes1.36-client` provides `kubernetes-client`. `dnf install` resolves capabilities. Bare `rpm -q` queries only exact package names and exits non-zero for capability names.
- **Relying solely on `dnf install` return status.** The `dnf` command exit status does not guarantee that every package installed. Packages can be missing or skipped. Re-inspecting with bare `rpm -q` created false missing sets.
- **Clearing skip records after an early return in `install_base_packages`.** In `home/.chezmoiscripts/20-base/fedora/run_onchange_before_base.sh.tmpl` and `home/.chezmoiscripts/20-base/ubuntu/run_onchange_before_base.sh.tmpl`, converging hosts returned early via `done_here` before reaching `clear_base_skip_record`. `done_here` removes only its own site record. A host previously marked unconverged kept its `base-packages-not-installed` record after converging. Placing `clear_base_skip_record` inside an `if` block moved the skip sentinel off the line opening the branch, which `.ci/check-skip-declarations.sh` rejected against `.ci/skip-declaration-site-matrix.yaml`.
- **Testing the fix with mock stubs that install under requested names.** The initial CI guard stubbed `dnf` by marking the requested name as installed. This caused the converged scenario to pass with the fix reverted, because it tested only exact-name matches instead of capability provider mapping.

## Solution

1. **Inspect declared packages using `rpm -q --whatprovides`.**
In every Fedora installer computing a missing set from a declared list, query capabilities with an `rpm_installed` helper or direct `rpm -q --whatprovides`:

```bash
rpm_installed() {
  rpm -q --whatprovides "$1" >/dev/null 2>&1
}
```

`rpm -q --whatprovides` exits 0 when any installed package provides the capability, including a package providing its own name. The `rpm -q --whatprovides` command itself accepts multiple names simultaneously and fails if any name is missing. Bulk call sites in `.install-prerequisites.sh` (`preflight_fedora`) and `home/.chezmoiscripts/80-keys/run_after_install-gpg-packages.sh.tmpl` pass an entire array to the command directly. The `rpm_installed` helper wraps single-package queries.

2. **Retire stranded skip records before early exit.**
In `home/.chezmoiscripts/20-base/fedora/run_onchange_before_base.sh.tmpl` and `home/.chezmoiscripts/20-base/ubuntu/run_onchange_before_base.sh.tmpl`, call `clear_base_skip_record` ahead of `done_here` using the guard pattern from `home/.chezmoiscripts/30-components/run_onchange_before_10-nvidia.sh.tmpl`:

```bash
[[ "${#missing[@]}" -gt 0 ]] || clear_base_skip_record
```

The retirement runs as its own statement before the `if [[ "${#missing[@]}" -eq 0 ]]` check. This preserves the skip sentinel on the line that opens the `done_here` branch, satisfying `.ci/check-skip-declarations.sh` against the frozen `.ci/skip-declaration-site-matrix.yaml`.

3. **Convert all package installer loops.**
Updated scripts include:
- `.install-prerequisites.sh` (`preflight_fedora`)
- `home/.chezmoiscripts/20-base/fedora/run_onchange_before_base.sh.tmpl`
- `home/.chezmoiscripts/30-components/run_onchange_before_20-podman.sh.tmpl`
- `home/.chezmoiscripts/30-components/run_onchange_before_30-tailscale.sh.tmpl`
- `home/.chezmoiscripts/30-components/run_onchange_before_60-desktop-ime.sh.tmpl`
- `home/.chezmoiscripts/30-components/run_onchange_before_70-apps.sh.tmpl`
- `home/.chezmoiscripts/30-components/run_onchange_before_80-devtools.sh.tmpl`
- `home/.chezmoiscripts/30-components/run_after_72-camera-ipu6.sh.tmpl`
- `home/.chezmoiscripts/30-linux/run_onchange_after_install-system-34-face-auth.sh.tmpl`
- `home/.chezmoiscripts/80-keys/run_after_install-gpg-packages.sh.tmpl`

4. **Harden CI test coverage with provider mapping.**
In `.ci/test-package-installer-verdict.sh`:
- Render and verify every converted Fedora installer script.
- Gate on argument shape: `rpm -q` calls receiving a shell variable must include `--whatprovides`. Literal package queries remain exempt (e.g. bootstrap check `rpm -q terra-release`). Two calls that receive a variable are exempt by explicit text matching in `.ci/test-package-installer-verdict.sh`: `conflicting_nvidia_branch()` in `home/.chezmoiscripts/30-components/run_onchange_before_10-nvidia.sh.tmpl:205` (`rpm -q "$installed"`), which loops over `nvidia_conflicting_packages` branch marker packages where package presence itself is the verdict, and the direct-RPM version reconciler in `home/.chezmoiscripts/30-components/run_onchange_before_75-direct-rpms.sh.tmpl` (`--queryformat`), which inspects a pinned version rather than checking if a package is installed.
- Define `PROVIDES` and `DNF_PROVIDER_NAMES` stubs using `<capability>:<provider>` pairs. Test scenarios construct synthetic provider names (e.g. `other-$pkg`) from declared packages extracted from rendered installer arrays. The test harness hardcodes no real Fedora package names.
- Verify mutations reverting `--whatprovides` to bare `rpm -q` fail the test suite.

## Why This Works

- **RPM capabilities versus package names:** `dnf install <spec>` resolves package names first, then provides. When `pkg-config` is requested on Fedora, `dnf` selects and installs `pkgconf-pkg-config`. Running `rpm -q pkg-config` returns non-zero because no package has that literal name. Running `rpm -q --whatprovides pkg-config` inspects the RPM provides index, locates `pkgconf-pkg-config`, and returns exit status 0.
- **Performance parity:** Benchmark testing on Fedora 44 across 72 packages measured `rpm -q --whatprovides` at 932.7ms versus 922.2ms for bare `rpm -q` (+1.1%, within measurement jitter). Process startup and rpmdb initialization dominate runtime; index lookup overhead is negligible.
- **Deliberate widening beyond dnf install:** `dnf install <name>` prefers an exact package name and replaces a compat build if present (such as swapping `curl-minimal` for `curl`, `coreutils-single` for `coreutils`, or `ffmpeg-free` for `ffmpeg`). In contrast, `rpm -q --whatprovides` considers the capability satisfied if a compatible provider exists. This widening is intentional: declared packages specify required system capabilities. Exact package pinning is reserved for direct-RPM declarations.
- **Skip record convergence:** Clearing the skip record before `done_here` ensures that moving from a failed state to a satisfied state removes the skip file. Keeping the check on the `[[ "${#missing[@]}" -gt 0 ]] || clear_...` guard keeps the declaration matrix parser aligned.

## Prevention

- Always inspect package presence via capability queries (`rpm -q --whatprovides`) when validating declared package lists in Fedora scripts.
- Reserve exact-name `rpm -q` queries for cases where package identity itself is the assertion (such as conflicting driver detection).
- In functions using `done_here`, place record clearing logic before early returns to prevent stranded state records.
- When writing CI mocks for package managers, stub provider-to-capability relationships (`DNF_PROVIDER_NAMES`) rather than assuming packages install under their query names. Verify tests fail under intentional bug mutations.

## Related Issues

- `docs/solutions/integration-issues/skip-partial-form-without-sentinel-escapes-the-checker.md`
- `docs/solutions/integration-issues/helper-return-0-with-no-other-return-reads-as-abandoned-skip-step.md`
- Branch `bugfix/rpm-provides-aware-package-checks` commits `03cf8d59` (`fix(fedora): resolve declared packages via provides`) and `7a0b6b22` (`fix(review): apply review findings`)
- Repository rules in `AGENTS.md` (Package installation policy paragraph)
