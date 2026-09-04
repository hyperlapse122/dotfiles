---
title: A Missing akmods Builder Deadlocks the Fedora NVIDIA MOK Wait
date: 2026-09-04
last_updated: 2026-09-04
category: integration-issues
module: nvidia
problem_type: integration_issue
component: package_provisioning
symptoms:
  - "install-nvidia-fedora.sh reports that /etc/pki/akmods/certs/public_key.der has not been generated yet, on every apply"
  - "install-nvidia-fedora records mok-generate-awaiting-builder as transient-blocking and never clears it"
  - "install-nvidia-fedora reports no enrollable DKMS MOK keypair is present, not applicable on this host, immediately after kmodgenca printed SUCCESS"
  - "mokutil --list-new is empty; no certificate was ever queued for enrollment"
  - "after the key is enrolled, every apply fails: mokutil exited before asking for the enrollment password, then chezmoi: .chezmoiscripts/30-components/10-nvidia.sh: exit status 1"
  - "SKIP: /etc/pki/akmods/certs/public_key.der is already enrolled appears in the apply output, from mokutil --import rather than the guard that should have prevented it"
  - "the first boot after the builder is installed takes minutes: systemd-analyze blame shows akmods.service at nearly two minutes, on the critical chain to graphical.target"
  - "akmod-nvidia-580xx is installed but rpm -q akmods reports the package is not installed"
  - "/etc/pki/akmods does not exist, no nvidia module is loaded, and /lib/modules/$(uname -r)/extra is absent"
  - "dnf5.log records: failed to exec scriptlet interpreter /bin/sh: Permission denied, then %sysusers(akmods) failed, exit status 127"
root_cause: missing_dependency
resolution_type: config_change
severity: high
tags:
  - nvidia
  - akmods
  - secure-boot
  - mok
  - selinux
  - rpm-scriptlet
  - fedora
  - chezmoi
---

# A Missing akmods Builder Deadlocks the Fedora NVIDIA MOK Wait

## Problem

On a Secure Boot host that resolves to the `pascal` NVIDIA branch, every apply
printed the same three lines and converged on none of them:

```
install-nvidia-fedora.sh: /etc/pki/akmods/certs/public_key.der has not been generated yet
install-nvidia-fedora: the out-of-tree module builder has not generated its signing keypair yet
install-nvidia-fedora: no enrollable DKMS MOK keypair is present; not applicable on this host
```

The driver packages were installed, but no NVIDIA module was ever built, and no
certificate was ever queued for enrollment.

## Root cause

Two independent facts combined into a deadlock.

1. `akmods` — the package that owns `/etc/pki/akmods`, ships the `kmodgenca`
   key generator, and provides `akmods-keygen@.service` and `akmods.service` —
   failed to install. Its rpm `%sysusers` scriptlet could not execute its
   interpreter, an SELinux rpm-script transition denial fixed separately:

   ```
   ERROR [rpm] failed to exec scriptlet interpreter /bin/sh: Permission denied
   ERROR [rpm] %sysusers(akmods-0.6.2-14.fc44.noarch) failed, exit status 127
   ERROR [rpm] akmods-0.6.2-14.fc44.noarch: install failed
   ```

   rpm dropped that one package and installed `akmod-nvidia-580xx` anyway, so
   the rpm database held a driver whose builder was absent.

2. `akmods` was a transitive dependency, not a declared package. The installer
   decides what to install from an `rpm -q` loop over the branch's declared
   package set, so a dependency that failed to install was invisible: nothing
   was missing from the declared set, and nothing re-ran `dnf install`.

The MOK step then waited for a key "minted on the first module build". No
builder was installed, so no build could happen, so the key could never appear —
and the wait is `transient-blocking`, which re-runs only when its probe
(`akmods-signing-key-present`) changes. Nothing could change it. The enrollment
step that followed saw no keypair and recorded `not_applicable`, on a host that
is entirely eligible.

### The second defect, uncovered once the key existed

With the builder installed, `kmodgenca -a` minted the keypair — and enrollment
STILL recorded `not_applicable`. `enroll_dkms_mok` decided on

```sh
if [[ "${mok_state}" != present || ! -f "$cert" ]]; then
```

`mok_state` comes from `dkms_mok_state`, which reads both halves under `sudo`.
The `! -f "$cert"` beside it is an UNPRIVILEGED test, and `kmodgenca` creates

```
drwxr-x---. root akmods /etc/pki/akmods/certs
```

so that test is false for a certificate that is present and readable to root. It
is the same conflation of "cannot look" with "not there" that `dkms_mok_state`
exists to refuse. The DKMS branch never showed it: `/var/lib/dkms/mok.pub` is
world-readable, so the extra test was always true there and only the akmod
branch, with its group-restricted directory, ever hit it.

### The third defect: mokutil's exit status is not its answer

Once the certificate WAS enrolled, every apply failed. `enroll_dkms_mok` guarded
the import with

```sh
if "${SUDO[@]}" mokutil --test-key "${cert}" 2>/dev/null | grep -q 'is already enrolled'; then
```

`mokutil --test-key` asks whether a key still NEEDS enrolling, so it exits
non-zero for one that is already enrolled:

```
$ sudo mokutil --test-key /etc/pki/akmods/certs/public_key.der; echo $?
/etc/pki/akmods/certs/public_key.der is already enrolled
255
```

The script runs under `set -o pipefail`, so the pipeline took mokutil's status,
not grep's — and evaluated FALSE in exactly the case the guard exists to catch.
The apply fell through to `mokutil --import`, which prints
`SKIP: <cert> is already enrolled` and exits WITHOUT prompting; the expect script
met eof where it wanted a password, returned 91, `enroll_dkms_mok` returned 1,
and the whole apply aborted on a host that had already converged. The same
pipeline shape in `report_stale_mok` made that report unreachable too.

## Resolution

- `.chezmoidata/nvidia.yaml` declares `akmods` in the `pascal` branch package
  set. The builder is the branch's build system, so its absence is now a missing
  declared package the next apply installs, not an invisible dependency.
- `ensure_dkms_mok_generated` runs `kmodgenca -a` when that generator exists,
  instead of only waiting. That is the same command `akmods-keygen@.service`
  runs, so it mints the builder's own key — not a second keypair the module
  would never be signed with — and it mints it while this apply can still queue
  the certificate for enrollment, saving a reboot.
- The outcome is decided by re-probing the keypair, never by `kmodgenca`'s exit
  status, so a generator that fails while reporting success still takes the
  wait.
- `main` calls `build_akmod_modules` after enrollment. `akmods.service` is
  ordered `Before=display-manager.service`, so a kmod it compiles at boot holds
  the login screen for the whole build — measured at 1m50s of a 2m21s boot on
  this laptop. Bare `akmods` (never `--force`) builds only the kmods missing for
  the running kernel, so it is a no-op on every apply after the first, and the
  service stays enabled for the kernel updates no apply precedes.
- `mok_key_is_enrolled` and `mok_key_is_queued` capture mokutil's output into a
  variable and match on that, so its exit status never reaches the decision.
  Never pipe mokutil into grep under `pipefail`.
- `enroll_dkms_mok` decides on `dkms_mok_state` alone. The unprivileged
  `! -f "$cert"` is gone; the probe already reports `present` only when both
  halves are readable as root, and reports failure — not `absent` — when it could
  not look at all.
- `enable_nvidia_services` enables `akmods.service` explicitly. Its enablement
  otherwise comes from the akmods rpm `%post` preset call — the same scriptlet
  class a host can refuse.

## How to check a host

```sh
rpm -q akmods akmod-nvidia-580xx
sudo ls -l /etc/pki/akmods/certs/public_key.der
grep -h 'akmods' /var/log/dnf5.log*
mokutil --list-new
systemd-analyze critical-chain | head
```

A driver package present with no builder package is the shape of the first
defect. A minted certificate with an empty `mokutil --list-new` is the shape of
the second. `akmods.service` on the critical chain to `graphical.target` is the
boot cost, and it is expected on the first boot after installation and after
every kernel update the apply did not precede.

A converged host reads:

```
$ sudo mokutil --test-key /etc/pki/akmods/certs/public_key.der
... is already enrolled
$ modinfo -F signer nvidia
ThinkPad-P14s-Gen-1_<timestamp>_<uuid>
$ lsmod | grep nvidia
nvidia ...
```

`modinfo -F signer` naming the certificate's own symlink target is the proof the
enrolled key and the signing key are the same one.

## Known gap

A `transient-blocking` record is written by its own site and cleared only by a
later declaration carrying the same `script`/`site` pair. A wait-only site has no
such success-path twin, so `~/.local/state/chezmoi/skips/install-nvidia-fedora__mok-generate-awaiting-builder`
survives after the key appears and `dotfiles-skips` goes on reporting a converged
host as outstanding. This is a property of the skip contract, not of this
installer; removing the stale record by hand is the current remedy.

## Wider lesson

A package installation that fails inside an rpm scriptlet does not necessarily
fail the transaction, and a package the installer never names is a package the
installer cannot notice is missing. Declare the tool a step depends on, and
verify the step's real precondition rather than waiting for another actor to
supply it.

A tool's exit status answers the tool's own question, which is not always yours.
`mokutil --test-key` reports "does this still need enrolling", `dkms_mok_state`
reports "can I read both halves" — and piping either into `grep` under `pipefail`
silently hands the decision back to the tool.

And once a probe is written to distinguish "cannot look" from "not there", every
extra test beside it must hold the same distinction. A single unprivileged
`-f` next to a privileged probe reintroduces the whole defect, and it stays
invisible until a path shows up whose directory the apply's own user cannot
read.
