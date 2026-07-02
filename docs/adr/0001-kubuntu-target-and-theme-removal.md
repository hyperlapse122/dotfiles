# 1. Kubuntu as a dual target and system-level de-brand to upstream Breeze

- Status: Proposed
- Date: 2026-07-02
- Deciders: repo owner

## Context
These chezmoi dotfiles provisioned Fedora (KDE/Wayland) only. We want Kubuntu
26.04 / Plasma 6.6 as a first-class Linux target without regressing Fedora, and
the machine reproducibly stripped of Canonical's Kubuntu branding back to
upstream KDE Breeze. Kubuntu and Ubuntu Server both report `ID=ubuntu` in
`/etc/os-release`; no field says "kubuntu".

## Decision 1 - Target detection is implicit (no new prompt)
Render-gate on `.chezmoi.osRelease.id == "ubuntu"` and separate desktop from
server with the repo's existing RUNTIME guards (`command -v plasmashell` for KDE
scripts; default-target=graphical + display-manager symlink for system config).
Rationale: the repo sets zero chezmoi prompts/data vars and already does host
detection at runtime; an `edition` prompt would break that convention.

## Decision 2 - Per-user Plasma config stays CLI-managed
Continue driving Plasma config with `kwriteconfig6` / `plasma-apply-*`; no static
`kdeglobals`/appletsrc dotfiles. Per-user de-brand additionally guards on a live
KDE session (DBus + display + running plasmashell) so a headless/SSH apply is a
clean no-op. Rationale: matches the 14 existing KDE scripts; avoids DBus failures.

## Decision 3 - The de-brand ships as idempotent run_after enforcement scripts
System changes ship as focused `linux-ubuntu` `run_after` scripts (package purge;
plymouth; SDDM; per-user theme; ufw) that re-check on every apply and act only on
actual state divergence via their own idempotency guards (no-op exit when already
clean). Rationale: `run_after` (not `run_onchange`) makes the de-brand reproducible
on every apply, repairs drift if Canonical branding is reinstalled by an upgrade,
and lets a first apply that guard-skips (no sudo / no live KDE session / package
not yet present) self-heal on a later apply — a `run_onchange` script latches its
content hash after one skipped run and never retries. The provisioning installer
(T7) and the shared `install-system-config` (T4) stay `run_onchange` to match the
existing Fedora installer convention.

## Decision 4 - Purge safety: apt-mark manual + simulate + fail-closed allowlist
`apt-mark manual` pins the desktop closure; `apt-get -s purge` runs under
`LC_ALL=C`; the run ABORTS on any simulation failure and ABORTS unless the
simulated `Remv|Purg` set (a purge prints named targets as `Purg`, collateral as either — Oracle-verified) is a subset of an explicit allowlist (the branding packages
+ the `kubuntu-desktop` meta). Purge runs with `AutomaticRemove=false`; never
`apt autoremove`. Rationale: a denylist can miss packages; an allowlist fails
closed.

## Decision 5 - Plymouth revert via the default.plymouth update-alternatives link
Ubuntu has no `plymouth-set-default-theme` (that is Fedora's `plymouth-scripts`
binary — verified absent in `ubuntu:26.04`). Select the boot splash the Debian/
Ubuntu way: point the `default.plymouth` alternative at
`/usr/share/plymouth/themes/breeze/breeze.plymouth` (registering it first — REQUIRED,
since the breeze package's postinst does NOT self-register the alternative, it only
removes stale entries — when it is not already a candidate) and run `update-initramfs -u` — skipping both when it
already resolves to breeze. The shared `install-system-config` also skips shipping
the Fedora `plymouthd.conf Theme=` key on Ubuntu so it cannot override the
alternative. Rationale: `update-alternatives` + `update-initramfs` is the canonical
Ubuntu splash-selection mechanism.

## Decision 6 - Kubuntu-only config never rides the shared system/ tree
The SDDM `Current=breeze` drop-in and other Kubuntu-only changes are written by
`linux-ubuntu`-gated scripts, NOT added to `system/linux/etc` (which deploys to
every Linux host, Fedora included). Fedora-only files already in that tree
(`plymouthd.conf`) are runtime-skipped on Ubuntu. Rationale: preserve the
"Fedora byte-for-byte unchanged" guarantee.

## Consequences
+ Fedora untouched; Kubuntu fully provisioned + de-branded reproducibly.
+ No new interactive surface.
+ Parity for Tailscale egress-NAT (ufw) and zram-disable is delivered, not deferred.
- ufw NAT via a managed `before.rules` block is the fiddliest parity item and must
  be VM/container-tested.
- `apt` package-name drift must be maintained in packages.yaml by hand.
- Fedora-only mechanisms (KR mirrors, RPMFusion/COPR, akmods MOK) have no Ubuntu
  equivalent — intentionally, not as a gap.
