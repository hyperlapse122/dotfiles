---
title: Make keyd Ignore the Logi Bolt Receiver - Plan
type: feat
date: 2026-08-24
topic: keyd-ignore-bolt-receiver
artifact_contract: ce-unified-plan/v1
artifact_readiness: implementation-ready
product_contract_source: ce-plan-bootstrap
execution: code
---

# Make keyd Ignore the Logi Bolt Receiver - Plan

## Goal Capsule

- **Objective:** keyd no longer grabs the Logi Bolt receiver (USB id `046d:c548`), so MX Master 3S/4 mice connected through it are handled natively by libinput/Solaar while every keyboard keeps the existing remapping (CapsLock to Hangeul, meta layer).
- **Means:** exclude the receiver id in `[ids]` and activate the change with a change-gated `keyd reload` in the /etc installer (KTD1, KTD2).
- **Authority:** this plan, the session-settled exclusion decision in KTD1, and the repository's installer conventions (change-gated service reloads, manifest-driven /etc install, render-time CI baselines).
- **Execution profile:** edit chezmoi source state only. Render changed templates with a scratch destination, stub `op`, and `--source "$PWD"`; never apply to the live home directory.
- **Stop conditions:** stop if the exclusion would cover a paired keyboard that needs remapping, or if the reload hook cannot be made change-gated like the bluetooth precedent.
- **Tail ownership:** the implementation executor owns edits and verification; commit, push, and PR work belong to the LFG shipping stages.

## Product Contract

### Summary

Add a keyd device exclusion so the Logi Bolt receiver is left to native input handling, and make the /etc installer activate the new config on apply through a change-gated `keyd reload` instead of requiring a reboot.

### Problem Frame

`system/linux/etc/keyd/default.conf` matches `[ids] *`, and the Bolt receiver exposes keyboard-capable evdev interfaces (`Logitech USB Receiver`, `Consumer Control`, `System Control`) alongside the mouse, so keyd grabs the whole receiver. That interferes with the MX Master 3S/4's native button handling. The receiver and every interface behind it share the single USB id `046d:c548` (confirmed on the live host via `/sys/class/input/event*/device`), and keyd matches devices by vendor:product only, so exclusion operates at receiver granularity.

### Requirements

- R1. `system/linux/etc/keyd/default.conf` excludes id `046d:c548` from `[ids]` while retaining `*` for every other device.
- R2. Applying the change activates it on the running keyd daemon without a reboot: the /etc installer reloads keyd only when an `etc/keyd/` file actually changed on that run.
- R3. The reload hook is inert on hosts without a usable keyd: it is guarded on the keyd binary and the keyd unit, mirroring the installer's bluetooth guard shape.

### Key Decisions

- **Exclude the entire Bolt receiver id.** (session-settled: user-approved — chosen over per-interface exclusion: keyd matches vendor:product only and all receiver interfaces share `046d:c548`; the user confirmed only mice are paired through the receiver). Governs R1.

### Scope Boundaries

- A keyboard later paired through the same Bolt receiver would also be ignored by keyd. This is an accepted consequence of the settled decision and is documented in the config comment, not worked around.
- No changes to Solaar, the libinput keyd quirks, udev rules, or mouse button behavior; those stay on their native paths.

## Planning Contract

### Key Technical Decisions

- KTD1. **Exclude the whole receiver id with `-046d:c548` under `[ids]`.** (session-settled: user-approved — chosen over per-interface exclusion: keyd matches vendor:product only and all four receiver evdev interfaces share the id; only mice are paired). Syntax confirmed against the installed keyd 2.6.0 man page: `[ids]` accepts `*` plus `-<vendor>:<product>` negations.
- KTD2. **Activate with a change-gated `keyd reload` in `run_onchange_after_install-system-10-files.sh.tmpl`.** Chosen over `systemctl restart keyd` (heavier: drops and recreates the virtual keyboard and pointer; `keyd reload` is keyd's documented config-only path) and over deferring activation to reboot (an apply that installs the file but leaves the daemon on the old config does not deliver R1's behavior). Mirrors the `bluetooth_changed` flag precedent: a cheap, change-gated reload fired only when an `etc/keyd/` file genuinely differed.
- KTD3. **Pin the new installer behavior in `.ci/test-fedora-fact-block-baseline.sh`.** The baseline pins a sha256 of this template's normalized render, so the edit must update that hash; add a `grep -Fq` assertion for the reload line alongside the existing notice assertions so the intentional behavior is named, not just hashed.

## Implementation Units

### U1. Exclude the Bolt receiver in the keyd config

- **Goal:** keyd's `[ids]` no longer matches `046d:c548`.
- **Requirements:** R1
- **Dependencies:** none
- **Files:** `system/linux/etc/keyd/default.conf`, `system/README.md`
- **Approach:**
  1. Add `-046d:c548` under the `*` line in `[ids]`, with a comment naming the Logi Bolt receiver, the MX Master 3S/4, and the accepted trade-off (a keyboard paired through this receiver would also be ignored).
  2. Update the `etc/keyd/default.conf` row in `system/README.md` to mention the Bolt receiver exclusion.
- **Test expectation:** none — declarative daemon config with no repo test harness; the `[ids]` negation syntax was verified against keyd(1) at plan time.
- **Verification:** the source file carries the negated id and comment; after the user applies on the live host, `sudo keyd monitor` shows no grab of the receiver and the MX Master's buttons behave natively.

### U2. Change-gated keyd reload in the /etc installer

- **Goal:** an apply that changes `/etc/keyd/` config reloads the daemon; every other apply leaves it alone.
- **Requirements:** R2, R3
- **Dependencies:** none (independent file; lands in the same apply cycle as U1)
- **Files:** `.chezmoiscripts/30-linux/run_onchange_after_install-system-10-files.sh.tmpl`, `.ci/test-fedora-fact-block-baseline.sh`
- **Approach:**
  1. Add a `keyd_changed=false` flag beside `bluetooth_changed`; set it true in the install loop when an `etc/keyd/` file differs from the deployed copy, using the same `cmp -s` pre-install test as bluetooth.
  2. After the existing reload sections, add a change-gated block guarded on `command -v keyd` and `systemctl is-active keyd.service`, running `"${SUDO[@]}" keyd reload`, with a comment explaining the gating like the bluetooth block.
  3. In `.ci/test-fedora-fact-block-baseline.sh`, update the pinned render hash for this template (run the test once to obtain the actual hash) and add a `grep -Fq` assertion for the reload line.
- **Patterns to follow:** the `bluetooth_changed` flag and its change-gated restart block in the same template; the Fedora notice assertions in the baseline test.
- **Test scenarios:**
  - Render the installer through the repo's scratch recipe (`--source "$PWD"`, stub `op`): the render contains the flag, the guarded reload block, passes `bash -n`, and is shellcheck-clean.
  - `.ci/test-fedora-fact-block-baseline.sh` passes with the updated hash and the new assertion; `.ci/test-fingerprint-gates.sh` and `.ci/check-skip-declarations.sh` stay green (no fingerprint template or skip declaration is touched).
  - The reload block is guarded such that a host without keyd installed or with the unit inactive takes no action (asserted by the grep assertion covering the guard lines).
- **Verification:** the three CI checks above pass and `git diff --check` is clean with the diff limited to the named files.

## Verification Contract

- Render the changed installer template with the repository's scratch recipe (stub `op`, empty config, throwaway destination, `--source "$PWD"`) and run `bash -n` plus shellcheck on the output.
- Run `.ci/test-fedora-fact-block-baseline.sh`, `.ci/test-fingerprint-gates.sh`, and `.ci/check-skip-declarations.sh`; all must pass.
- `git diff --check` and `git status` must show a diff limited to `system/linux/etc/keyd/default.conf`, `system/README.md`, `.chezmoiscripts/30-linux/run_onchange_after_install-system-10-files.sh.tmpl`, `.ci/test-fedora-fact-block-baseline.sh`, and this plan file.
- Onchange disclosure: the first apply reruns `install-system-10-files` (its fingerprint covers `system/linux/etc/**`), installs the new `default.conf`, and runs `keyd reload` — a sub-second virtual-keyboard re-initialization, not a service restart.
- Live smoke after the user's apply (manual, not CI): `sudo keyd monitor` no longer reports grabbing `046d:c548`, and MX Master buttons work without keyd interference.

## Definition of Done

- R1-R3 implemented as specified; the settled exclusion decision is intact.
- Every Verification Contract check passes.
- The diff contains only the named files; no abandoned-attempt or experimental changes remain.
