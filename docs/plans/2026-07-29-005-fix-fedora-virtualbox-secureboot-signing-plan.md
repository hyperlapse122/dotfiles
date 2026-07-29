---
title: "fix: sign Fedora VirtualBox modules under Secure Boot"
date: 2026-07-29
type: fix
artifact_contract: ce-unified-plan/v1
artifact_readiness: implementation-ready
product_contract_source: ce-plan-bootstrap
execution: code
---

# fix: sign Fedora VirtualBox modules under Secure Boot

## Goal Capsule

- Make Oracle VirtualBox usable on a Secure Boot Fedora host: the `vbox*` kernel modules must be signed by the already-enrolled MOK and loaded.
- Move signing to the one place that already does it correctly for every trigger — Oracle's own `vboxdrv.sh` — instead of duplicating it in chezmoi.
- Replace every silent skip with an actionable message.
- Verify against the rendered installer and the live host state; never through a live `chezmoi apply` in CI and never with a real kernel build in CI.

---

## Product Contract

### Summary

Fedora provisioning must hand Oracle's `vboxdrv.sh` the signing key material it looks for, so the script signs the modules it just built. Chezmoi's own duplicate signing loop and the `/etc/kernel/install.d/50-vbox-sign.install` hook are then redundant and retired.

### Problem Frame

VirtualBox fails on the Secure Boot Fedora host with `VERR_VM_DRIVER_NOT_INSTALLED (-1908)`; `vboxdrv` is built but unsigned and never loads. Five independent defects produce that state, and every one of them fails quietly:

1. **Oracle's signing step hard-fails on Fedora.** `vboxdrv.sh:122-123` reads its key material only from the Debian paths `/var/lib/shim-signed/mok/MOK.der` and `MOK.priv`. Fedora provisioning never creates them, so the key-presence test at `vboxdrv.sh:777` calls `failure` and `vboxdrv.sh setup` exits 1. `vboxdrv.service` has therefore failed at every boot (`Active: failed`, journal shows the "your distribution does not provide tools for automatic generation of keys" message), leaving the built modules unsigned and unloaded.
2. **The kernel-install hook signs the wrong directory.** `system/linux/etc/kernel/install.d/50-vbox-sign.install:60` scans `/lib/modules/<ver>/updates`, but Oracle installs to `/lib/modules/<ver>/misc` (`vboxdrv.sh:491`). Every module file misses the `[[ -f ]]` guard, so the loop signs nothing and exits 0.
3. **The hook cannot build for the kernel it is invoked for.** It calls `KERN_VER=<ver> /sbin/vboxconfig`, but `vboxdrv.sh:101` unconditionally overwrites `KERN_VER` from `uname -r`, and `/sbin/vboxconfig` (`postinst-common.sh:123`) invokes `vboxdrv.sh setup` with no version argument. The only version-accepting entry point is `rcvboxdrv setup <ver>`, whose `cleanup` (`vboxdrv.sh:680`) deletes vbox modules from *every* `/lib/modules/*/misc`, so building for a non-running kernel destroys the running kernel's modules.
4. **Every failure is swallowed.** Both the hook and `sign_virtualbox_modules()` route `sign-file` stderr to `/dev/null` behind `|| true`, never verify that a signature landed, and never load the driver — so a total failure to sign is indistinguishable from success.
5. **The MOK check destroys the trust anchor when `sudo` fails.** `/var/lib/dkms` is root-only, so `ensure_dkms_mok_generated` probes the keypair with `"${SUDO[@]}" test -f mok.pub && "${SUDO[@]}" test -f mok.key`. That chain returns non-zero both when the key is absent *and* when `sudo` itself fails to authenticate, and the function reads the second case as the first: it mints a fresh keypair over the enrolled one. The enrolled certificate stays in MOK while its private key is gone, so every module signed afterwards is rejected — breaking VirtualBox *and* the NVIDIA DKMS driver until a new enrollment and reboot. Observed live during this work: a mistyped sudo password replaced an enrolled MOK (`55:A8:82:…`) with an unenrolled one (`A2:FD:6A:…`).

The trust anchor design is sound and must not change: one keypair at `/var/lib/dkms/mok.{pub,key}` covers NVIDIA and VirtualBox, so one `mokutil` enrollment serves both. Defect 5 is a robustness bug in how that keypair is *checked*, not a reason to change the design.

### Requirements

- R1. On a Secure Boot Fedora host with VirtualBox installed, provisioning must leave the running kernel's `vbox*` modules signed by the enrolled MOK.
- R2. A newly installed kernel must receive signed modules without a `chezmoi apply`.
- R3. No signing path may fail silently: a missing key, a failed build, or an unsigned module must emit an actionable message naming the remedy.
- R4. When the MOK is already enrolled, provisioning must leave the driver loaded in the same run, with no reboot.
- R5. Signing must reuse the single enrolled DKMS MOK. No second keypair and no second `mokutil` enrollment.
- R6. Fedora hosts without Secure Boot or without VirtualBox, containers, and Ubuntu must be unaffected.
- R7. Retiring the kernel-install hook must also prune the copy already deployed to `/etc`.
- R8. Verification must not require a live `chezmoi apply`, a real kernel module build, or a real MOK enrollment.
- R9. A privileged probe that cannot run must never be read as "key absent". Provisioning must refuse rather than mint a keypair over an existing one, and must distinguish a complete keypair from a half-present one.

### Scope Boundaries

- Keep `/var/lib/dkms/mok.{pub,key}` as the host's one out-of-tree module trust anchor, and keep `ensure_dkms_mok_generated` / `enroll_dkms_mok` as its owners.
- Do not change Ubuntu VirtualBox provisioning; `virtualbox-dkms` already signs through shim-signed's DKMS integration.
- Do not change the NVIDIA driver stack, the RPM Fusion exclusion policy, or the Oracle repo definitions.
- Do not migrate Fedora to a DKMS or akmods build of VirtualBox.
- Do not add a systemd unit: `vboxdrv.service` already covers the boot-time build.

### Success Criteria

- `modinfo` reports `signer: DKMS module signing key…` for every built vbox module on the live host, `lsmod` lists them, and VirtualBox starts a VM.
- `systemctl is-active vboxdrv.service` is `active`.
- A rendered-installer smoke test fails if the signing contract regresses.

---

## Planning Contract

### Key Technical Decisions

- KTD1. **Delegate signing to Oracle's `vboxdrv.sh` by provisioning its key material at the Debian paths.** Everything past the key-presence test at `vboxdrv.sh:777` is distro-neutral: `SIGN_TOOL` resolves to `/lib/modules/$KERN_VER/build/scripts/sign-file` (present on Fedora via `kernel-devel-matched`), the hash algorithm comes from the running kernel's config, and the sign loop at `vboxdrv.sh:810` targets the correct `misc/` path. Rejected: keeping chezmoi's own `sign-file` loop, which re-derives the module path and hash algorithm Oracle already resolves correctly and must be re-invoked from every trigger (apply, boot, kernel install, manual `vboxconfig`) — four call sites instead of one fixed precondition.
- KTD2. **Symlink the shim-signed paths at `/var/lib/dkms/mok.{pub,key}`; do not copy.** Oracle's tests are `test -f`, which follows symlinks, and `mokutil --test-key` on the link reports the enrolled key, which also sets `DEB_KEY_ENROLLED` and suppresses `vboxdrv.sh:545`'s spurious "you must sign these modules" boot warning. Rejected: copying, which duplicates a private key and silently goes stale whenever the MOK is regenerated.
- KTD3. **Delete `50-vbox-sign.install` rather than repair its path.** Repair is impossible: no `vboxconfig` entry point builds for a non-running kernel, and the one that accepts a version wipes the running kernel's modules (Problem Frame 3). Once KTD1 holds, the hook is also unnecessary — at boot `vboxdrv.service` runs `start`, which calls `setup_complete || setup` (`vboxdrv.sh:545`) and so builds *and now signs* for the newly booted kernel. Rejected: changing `updates` to `misc`, which would fix the silent no-op but leave the hook signing the wrong (running, not new) kernel's modules.
- KTD4. **Build only when needed, then verify, then activate.** Check whether the running kernel's modules are missing or unsigned before invoking `/sbin/vboxconfig`, so a converged host does not pay a 30-second rebuild on every fingerprint change; afterwards assert that each built module reports a signer and restart `vboxdrv.service`. Rejected: today's unconditional `vboxconfig` plus `|| true`, which is both slower and unable to distinguish success from failure.
- KTD5. **Assert the contract against the rendered installer in CI, not against a real build.** A GitHub runner has no matching `kernel-devel`, no Secure Boot, and no MOK. Rejected: building modules in CI. This mirrors `.ci/smoke-fedora-nvidia-repo-policy.sh`, which already asserts Fedora installer structure and call ordering against rendered text.
- KTD6. **Read the MOK state through one privileged probe that must succeed on its own terms.** A `dkms_mok_state` helper echoes `present`, `partial`, or `absent` and returns non-zero when the probe itself could not run, so `ensure_dkms_mok_generated` can refuse instead of minting. Callers act on its return code rather than re-testing the files. Rejected: adding a `sudo -v` pre-check before the existing chain — it narrows the race but keeps the conflation, so any later `sudo` failure still reads as "absent". Also rejected: making the mint unconditionally safe with `openssl ... -noclobber` (no such option) or a pre-move backup, which leaves a stale private key on disk and still loses the enrolled association.

### Assumptions

- The kernel accepts the existing MOK for module signatures without a `codeSigning` extended key usage. Evidenced on the live host: the NVIDIA modules signed with that same key load under Secure Boot.
- `kernel-devel-matched` keeps `/lib/modules/<running>/build/scripts/sign-file` present for the running kernel, including immediately after a kernel upgrade and reboot.
- `vboxpci` is no longer built by VirtualBox 7.2 (only `vboxdrv`, `vboxnetflt`, `vboxnetadp` exist on the host); module lists must tolerate its absence rather than enumerate it as required.

### Sequencing

U1 is independent. U2 depends on U1 (the hook may only be retired once Oracle self-signs). U4 is independent of both and could ship alone, but is required for U1 to be safe on a host where `sudo` can fail mid-run. U3 asserts all three.

---

## Implementation Units

### U1. Provision Oracle's signing key material, then verify and activate

- **Goal:** Replace the duplicate signing loop with a key-material precondition, a conditional build, a real verification, and driver activation.
- **Requirements:** R1, R3, R4, R5, R6; KTD1, KTD2, KTD4.
- **Dependencies:** None.
- **Files:** `.chezmoiscripts/20-linux-fedora/run_onchange_before_fedora.sh.tmpl`
- **Approach:** Replace `sign_virtualbox_modules()` with a function that provisions the signing key and lets Oracle sign. Keep the `rpm -q VirtualBox-7.2` and Secure Boot guards, and act on `ensure_dkms_mok_generated`'s return code (U4) rather than re-testing the key files. After the MOK is confirmed, create `/var/lib/shim-signed/mok/` at mode 0700 and idempotently link `MOK.der` to `/var/lib/dkms/mok.pub` and `MOK.priv` to `/var/lib/dkms/mok.key`; replace only a wrong link, and leave a pre-existing regular file alone with a warning rather than clobbering host state. Then check whether the modules in `/lib/modules/$(uname -r)/misc` — Oracle's fixed convention, resolved directly rather than via a depmod index that is briefly absent mid-rebuild — are missing or unsigned, and invoke `/sbin/vboxconfig` only in that case. Afterwards assert that every built module reports a signer and restart `vboxdrv.service` so the driver is usable without a reboot. Every failure branch prints one actionable line to stderr naming cause and remedy — never `|| true` with output discarded. Update the header comments so they describe delegation to Oracle instead of a local sign-file loop, and keep the call site's position relative to `enroll_dkms_mok` unchanged.
- **Patterns to follow:** The existing `SUDO[@]` invocation style, the `ensure_dkms_mok_generated` idempotence guards, and the actionable-stderr message style already used by `enroll_dkms_mok`.
- **Test Scenarios:** Covered by U3 — behaviorally: the key link is created, left alone when correct, repaired when stale, and refused (with a warning, contents intact) when a regular file is already there; a module set reports signed only when every module carries a signature. Structurally: the build is gated and then verified, activation happens on both exits, the VirtualBox-absent and Secure-Boot-off guards return early, and no `sign-file` loop or discarded output remains.
- **Verification:** Render the installer with `chezmoi execute-template` and confirm it is valid `bash -n`. On the live host, confirm `modinfo vboxdrv` reports a signer, the modules are listed by `lsmod`, and `vboxdrv.service` is active.

### U2. Retire the kernel-install hook

- **Goal:** Remove the hook that can never sign correctly, and prune the copy already deployed to `/etc`.
- **Requirements:** R2, R7; KTD3.
- **Dependencies:** U1.
- **Files:** `system/linux/etc/kernel/install.d/50-vbox-sign.install` (delete), `.chezmoidata/system.yaml`, `.chezmoidata/packages.yaml`
- **Approach:** Delete the hook source. Remove its `files:` entry from `.chezmoidata/system.yaml` and add `/etc/kernel/install.d/50-vbox-sign.install` to that file's `removed:` list with `distro: fedora`, per the manifest's stated same-commit rule. Rewrite the Fedora VirtualBox comment block in `.chezmoidata/packages.yaml` (and the two hook references in the installer template) so they describe the new mechanism: Oracle signs during its own build, seeded by the linked DKMS MOK, and `vboxdrv.service` covers new kernels at boot.
- **Patterns to follow:** The existing `removed:` entries in `.chezmoidata/system.yaml`, including the `distro:` restriction used for the Ubuntu Studio drop-in.
- **Test Scenarios:** Covered by U3 — the rendered `/etc` manifest no longer ships the hook and does list it for removal.
- **Verification:** Render `install-system-10-files` and confirm the hook is absent from the deploy list and present in the removal list.

### U3. Smoke-test the Fedora VirtualBox signing contract

- **Goal:** Make a regression of U1 or U2 fail CI.
- **Requirements:** R8; KTD5.
- **Dependencies:** U1, U2, U4.
- **Files:** `.ci/smoke-fedora-virtualbox-signing.sh` (new), `.github/workflows/render-dotfiles.yml`
- **Approach:** Add a smoke script taking the rendered Fedora installer and the rendered `/etc` file installer as arguments. Extract the helper functions from the rendered installer and drive them for real against a scratch tree with a stubbed `modinfo` and a `SUDO` array that models both success and authentication failure — behavioral coverage, not only text assertions. Assert structurally what cannot be relocated: the VirtualBox and Secure Boot guards, the `misc/` module directory, the guard-build-verify ordering, activation on both exits, and the absence of `sign-file`, `KERN_VER=`, and the `updates/` path. Assert on the `/etc` installer that the hook is not deployed and is listed for removal under Fedora. Wire it into the existing `render internals` job in `.github/workflows/render-dotfiles.yml` next to the NVIDIA policy smoke step, reusing that step's rendered-file paths and `matrix.os == 'fedora'` gate.
- **Patterns to follow:** `.ci/smoke-fedora-nvidia-repo-policy.sh` — `set -euo pipefail`, argument validation, a `RUNNER_TEMP`/`XDG_RUNTIME_DIR` scratch directory with a cleanup trap, function extraction by `sed` range, stub binaries on `PATH`, `grep -n` line-number extraction for ordering assertions, and one clear stderr message per failed assertion.
- **Test Scenarios:** Passes against the rendered post-change installers. Fails when: the key link becomes a copy; the `vboxconfig` guard or post-build verification is dropped; `vboxconfig` output is silenced; activation is dropped from either exit; the module directory reverts to `updates/`; the glob stops covering compressed modules; an empty module set reports vacuously signed; `sign-file` returns; the hook is re-added without a removal entry; the MOK probe conflates sudo failure with absence; a half-present keypair is overwritten; or the caller ignores the MOK return code.
- **Verification:** Run the script locally against locally rendered installers; confirm it exits 0, and confirm every assertion fails when its target line is mutated.

### U4. Make the MOK check fail safe instead of destroying the keypair

- **Goal:** Stop provisioning from minting a keypair over an enrolled one when the privileged probe cannot run.
- **Requirements:** R3, R5, R9; KTD6.
- **Dependencies:** None.
- **Files:** `.chezmoiscripts/20-linux-fedora/run_onchange_before_fedora.sh.tmpl`
- **Approach:** Add a `dkms_mok_state` helper that runs one privileged probe and prints `present`, `partial`, or `absent`, returning non-zero when the probe could not run at all. Rewrite `ensure_dkms_mok_generated` to branch on it: return 0 on `present`, refuse with an actionable message on `partial` or an unreadable probe, and mint only on `absent`. Make the function's return code the contract so `provision_vbox_module_signing` acts on it instead of repeating the file tests, and reuse the same probe in `enroll_dkms_mok`'s certificate discovery so there is one convention for reading this keypair.
- **Patterns to follow:** The existing `SUDO[@]` style and `enroll_dkms_mok`'s actionable-stderr messages.
- **Test Scenarios:** Covered by U3 behaviorally — `absent`/`partial`/`present` are each reported correctly; a failing privileged probe returns non-zero and never prints `absent`; with the probe failing, `ensure_dkms_mok_generated` reports failure and leaves an existing keypair byte-for-byte intact; and the caller does not proceed past a failed check.
- **Verification:** Run the U3 smoke test, including the mutation that restores the original conflating `sudo test -f` chain.

---

## Verification Contract

- Render every changed template through `chezmoi execute-template` with the AGENTS.md isolated harness — per-user scratch, stub `op`, empty config, throwaway destination, and `--source "$PWD"`. Scripts are not targets; compare them as rendered text.
- `bash -n` the rendered Fedora installer and the rendered `/etc` file installer.
- `.ci/smoke-fedora-virtualbox-signing.sh <rendered-fedora-installer> <rendered-etc-installer>` exits 0.
- `.ci/smoke-fedora-nvidia-repo-policy.sh` still passes — the same installer is being edited.
- Live-host proof of the reported bug being fixed: run the new signing path on this Secure Boot Fedora host and confirm `modinfo` reports a signer for every built vbox module. Where the host's MOK is not yet enrolled, confirm the enrollment request is queued (`MokNew` and `MokAuth` present in `/sys/firmware/efi/efivars/`) and state that module loading completes after the reboot-time MOK Manager step.
- `git diff --check` and a diff limited to the requested scope.
- No live `chezmoi apply` against `$HOME`, no real MOK enrollment, and no kernel build in CI.

## Definition of Done

- The Secure Boot Fedora host has signed vbox modules and loads them once its MOK is enrolled; where enrollment was queued this run, the pending request is verified and the reboot-time MOK Manager step is stated (R1, R4).
- New kernels are covered by `vboxdrv.service` at boot, with no chezmoi apply and no kernel-install hook (R2).
- Every signing failure path emits an actionable message; no path discards its output (R3).
- One MOK, one enrollment; `/var/lib/dkms/mok.{pub,key}` remains the only keypair, and no path overwrites it when the privileged probe fails (R5, R9).
- Non-Secure-Boot Fedora, non-VirtualBox Fedora, containers, and Ubuntu are untouched (R6).
- The deployed hook is pruned via `removed:` in the same commit that deletes its source (R7).
- The new smoke test is wired into `render-dotfiles.yml` and passes; the NVIDIA smoke test still passes (R8).
- Comments in `.chezmoidata/packages.yaml`, `.chezmoidata/system.yaml`, and the Fedora installer describe the delegated mechanism, with no stale references to a local sign-file loop or the retired hook.
- No abandoned experimental code remains in the diff.
- The change is delivered through a reviewed, green pull request.
