---
title: Fix NVIDIA Sleep Hook Services and Document Logind Lid Sleep Policy - Plan
type: fix
date: 2026-09-04
artifact_contract: ce-unified-plan/v1
artifact_readiness: implementation-ready
product_contract_source: ce-plan-bootstrap
execution: code
---

# Fix NVIDIA Sleep Hook Services and Document Logind Lid Sleep Policy - Plan

## Goal Capsule

- **Objective:** Enable NVIDIA sleep hook units (`nvidia-suspend.service`, `nvidia-resume.service`, `nvidia-hibernate.service`, `nvidia-suspend-then-hibernate.service`) on hybrid graphics systems so suspend does not abort in the kernel when `NVreg_PreserveVideoMemoryAllocations=1` is set; and document the silent degradation of `HandleLidSwitch=suspend-then-hibernate` to plain suspend on hosts where Secure Boot kernel lockdown disables hibernation.
- **Means:**
  1. In `.chezmoiscripts/30-components/run_onchange_before_10-nvidia.sh.tmpl`, extend `enable_nvidia_services()` to enable `nvidia-suspend.service`, `nvidia-resume.service`, `nvidia-hibernate.service`, and `nvidia-suspend-then-hibernate.service` when `FACT_HYBRID_GRAPHICS=1` and the unit files are present via `systemctl list-unit-files`.
  2. In `system/linux/etc/systemd/logind.conf.d/90-laptop-lid.conf` and `system/linux/etc/systemd/sleep.conf.d/90-laptop-suspend-then-hibernate.conf`, update comments to explain that on Secure Boot hosts with kernel lockdown (`integrity` mode), hibernation is restricted by the kernel so logind automatically falls back to plain suspend.
  3. In `.ci/smoke-fedora-nvidia-repo-policy.sh`, add structural assertions verifying that `enable_nvidia_services` enables the four NVIDIA sleep hook units when `FACT_HYBRID_GRAPHICS=1`.
- **Authority:** GitHub issue #385 (`https://github.com/hyperlapse122/dotfiles/issues/385`).
- **Execution profile:** Shell script template update, system configuration commentary update, and CI smoke test assertion.
- **Stop conditions:** Stop if `.ci/check-skip-declarations.sh` or `.ci/smoke-fedora-nvidia-repo-policy.sh` fails.
- **Tail ownership:** The invoking LFG pipeline owns implementation, simplification, code review, commits, push, PR creation, and CI watch.

---

## Product Contract

### Summary

On hybrid graphics laptops (e.g. ThinkPad P14s Gen 1 with Intel + NVIDIA Quadro P520), this repository configures `options nvidia NVreg_PreserveVideoMemoryAllocations=1` via `system/linux/etc/modprobe.d/nvidia-hybrid-power.conf`. With this option, the NVIDIA kernel driver requires the systemd sleep services to coordinate saving and restoring video memory via `/proc/driver/nvidia/suspend` before kernel suspend. Because `.chezmoiscripts/30-components/run_onchange_before_10-nvidia.sh.tmpl` never enabled these units, any suspend attempt (closing the lid or `systemctl suspend`) aborts with error -5 (`nv_pmops_suspend [nvidia] returns -5: PreserveVideoMemoryAllocations module parameter is set. System Power Management attempted without driver procfs suspend interface`), causing immediate wake-up and battery drain.

Additionally, `90-laptop-lid.conf` sets `HandleLidSwitch=suspend-then-hibernate`, but on Secure Boot hosts running in `integrity` lockdown, kernel lockdown restricts hibernation. Systemd-logind silently falls back to plain suspend. The configuration commentary should accurately record this behavior rather than claiming an unreachable ladder.

### Requirements

- **R1.** Extend `enable_nvidia_services()` in `.chezmoiscripts/30-components/run_onchange_before_10-nvidia.sh.tmpl` so that when `FACT_HYBRID_GRAPHICS` is 1, it checks for and enables `nvidia-suspend.service`, `nvidia-resume.service`, `nvidia-hibernate.service`, and `nvidia-suspend-then-hibernate.service`.
- **R2.** Ensure each sleep service is only enabled if present on the system (`systemctl list-unit-files "$unit"`), matching the existing pattern for `nvidia-persistenced.service` and `akmods.service`.
- **R3.** Maintain `HandleLidSwitch=suspend-then-hibernate` in `system/linux/etc/systemd/logind.conf.d/90-laptop-lid.conf` while documenting in comments that on Secure Boot hosts under kernel lockdown, hibernation is disabled and logind automatically degrades to plain suspend.
- **R4.** Document the lockdown degradation in `system/linux/etc/systemd/sleep.conf.d/90-laptop-suspend-then-hibernate.conf`.
- **R5.** Add verification assertions in `.ci/smoke-fedora-nvidia-repo-policy.sh` verifying that the sleep units are enabled under `FACT_HYBRID_GRAPHICS=1`.

### Key Decisions

- **KD1.** Enable sleep services conditionally on `FACT_HYBRID_GRAPHICS=1`. `nvidia-hybrid-power.conf` (which sets `NVreg_PreserveVideoMemoryAllocations=1`) is gated on `hybridGraphics`. The module option and its hooks form a single configuration unit and must be provisioned together.
- **KD2.** Keep `HandleLidSwitch=suspend-then-hibernate` rather than introducing a Secure Boot gate. Logind natively and safely degrades to plain suspend when hibernation is restricted by kernel lockdown or unavailable swap, while allowing hosts without lockdown to hibernate. Documenting the reality prevents documentation drift without complicating fact gating.

### Scope Boundaries

- Non-hybrid desktops with discrete NVIDIA GPUs do not install `nvidia-hybrid-power.conf` and do not have `FACT_HYBRID_GRAPHICS=1`, so their power management behavior is unchanged.
- No changes to kernel lockdown settings or Secure Boot enforcement.

---

## Planning Contract

### Key Technical Decisions

- **KTD1.** In `.chezmoiscripts/30-components/run_onchange_before_10-nvidia.sh.tmpl`:
  Inside `enable_nvidia_services()`, add:
  ```bash
  if [[ "${FACT_HYBRID_GRAPHICS:-0}" -eq 1 ]]; then
    local unit
    for unit in nvidia-suspend.service nvidia-resume.service nvidia-hibernate.service nvidia-suspend-then-hibernate.service; do
      if systemctl list-unit-files "$unit" 2>/dev/null | grep -q "$unit"; then
        "${SUDO[@]}" systemctl enable "$unit" 2>/dev/null || true
      fi
    done
  fi
  ```
- **KTD2.** In `system/linux/etc/systemd/logind.conf.d/90-laptop-lid.conf` and `system/linux/etc/systemd/sleep.conf.d/90-laptop-suspend-then-hibernate.conf`:
  Update file header comments to describe kernel lockdown / Secure Boot degradation behavior.
- **KTD3.** In `.ci/smoke-fedora-nvidia-repo-policy.sh`:
  Add smoke assertions checking that the rendered script contains the sleep units loop under `FACT_HYBRID_GRAPHICS`.

### Sequencing

1. **U1:** Update `enable_nvidia_services()` in `.chezmoiscripts/30-components/run_onchange_before_10-nvidia.sh.tmpl`.
2. **U2:** Update documentation comments in `system/linux/etc/systemd/logind.conf.d/90-laptop-lid.conf` and `system/linux/etc/systemd/sleep.conf.d/90-laptop-suspend-then-hibernate.conf`.
3. **U3:** Add smoke assertions in `.ci/smoke-fedora-nvidia-repo-policy.sh`.
4. **U4:** Run local validation (`.ci/check-skip-declarations.sh`, render checks, smoke test).

---

## Implementation Units

### U1. Enable NVIDIA Sleep Hook Units in `run_onchange_before_10-nvidia.sh.tmpl`

- **Files:** `.chezmoiscripts/30-components/run_onchange_before_10-nvidia.sh.tmpl`
- **Action:** In `enable_nvidia_services()`, check `[[ "${FACT_HYBRID_GRAPHICS:-0}" -eq 1 ]]` and iterate through `nvidia-suspend.service nvidia-resume.service nvidia-hibernate.service nvidia-suspend-then-hibernate.service`, enabling each unit if found by `systemctl list-unit-files`.

### U2. Update Sleep Policy Documentation Comments

- **Files:**
  - `system/linux/etc/systemd/logind.conf.d/90-laptop-lid.conf`
  - `system/linux/etc/systemd/sleep.conf.d/90-laptop-suspend-then-hibernate.conf`
- **Action:** Update commentary noting that on Secure Boot hosts with kernel lockdown (`integrity`), hibernation is restricted by the kernel (`/sys/power/disk` disabled) and logind degrades automatically to plain suspend.

### U3. Add Smoke Assertions in `.ci/smoke-fedora-nvidia-repo-policy.sh`

- **Files:** `.ci/smoke-fedora-nvidia-repo-policy.sh`
- **Action:** Verify that the rendered installer contains `enable_nvidia_services` with the four sleep units under `FACT_HYBRID_GRAPHICS`.

---

## Verification Contract

1. Render script validation:
   ```sh
   chezmoi execute-template < .chezmoiscripts/30-components/run_onchange_before_10-nvidia.sh.tmpl > /tmp/rendered-nvidia.sh
   bash -n /tmp/rendered-nvidia.sh
   ```
2. Run skip declarations check:
   ```sh
   .ci/check-skip-declarations.sh
   ```
3. Run smoke test:
   ```sh
   .ci/smoke-fedora-nvidia-repo-policy.sh /tmp/rendered-nvidia.sh
   ```
4. Run fact block baseline check:
   ```sh
   .ci/test-fedora-fact-block-baseline.sh
   ```

---

## Definition of Done

- `enable_nvidia_services()` enables `nvidia-suspend.service`, `nvidia-resume.service`, `nvidia-hibernate.service`, and `nvidia-suspend-then-hibernate.service` when `FACT_HYBRID_GRAPHICS=1` and units exist.
- Documentation comments in sleep/lid drop-in configurations accurately describe kernel lockdown degradation.
- CI tests (`check-skip-declarations.sh`, `smoke-fedora-nvidia-repo-policy.sh`, `test-fedora-fact-block-baseline.sh`) pass cleanly.
