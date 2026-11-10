---
title: "A Type=notify unit's TimeoutStartSec failure still satisfies Before=/After= ordering"
date: 2026-09-23
category: best-practices
module: "NixOS systemd unit ordering (modules/nixos/services/*)"
problem_type: architecture_pattern
component: systemd
severity: medium
applies_when:
  - "A new systemd unit is ordered After= or Before= an existing Type=notify unit that can retry indefinitely without ever calling systemd-notify --ready (e.g. waiting on a network-dependent external auth step)"
  - "The design assumes After=/Wants= means \"runs only once the upstream unit's own job succeeded\", not just \"runs once the upstream unit reached any terminal state\""
tags:
  - systemd
  - nixos
  - unit-ordering
  - tailscale
  - type-notify
  - timeoutstartsec
---

# A `Type=notify` unit's `TimeoutStartSec` failure still satisfies `Before=`/`After=` ordering

## Context

While building `modules/nixos/services/tailscale.nix`'s device-cleanup unit
(`tailscale-dedup-device.service`), the first design ordered it
`After=`/`Wants=tailscaled-autoconnect.service` — nixpkgs' own unit from
`services.tailscale`, `Type=notify`, whose script loops calling `tailscale up`
and polling `BackendState` until it reaches `Running`, with no `set -e` and no
exit path other than `systemd-notify --ready` on success (the
`tailscaled-autoconnect` service definition inside nixpkgs' own
`services.tailscale` module — vendored, not part of this repo's own tree).
The intent was "only run cleanup once tailscaled has actually authenticated."

In an offline NixOS VM test (`tests/tailscale-provisioning.nix`, no network
reachable to the real Tailscale coordination servers), the mock API server
logged a `GET /api/v2/tailnet/-/devices` request and crashed with
`FileNotFoundError` roughly 90 seconds into boot — well before the test script
ever invoked the dedup unit manually. The dedup unit had started **on its
own**, mid-boot, with no real Tailscale authentication in place.

## Guidance

`After=`/`Before=` (and the `Wants=` pull-in paired with it) on a downstream
unit is satisfied once the upstream unit reaches **any terminal state** —
active, failed, or (for `Type=notify`) timed out waiting for
`systemd-notify --ready` past its `TimeoutStartSec` (default 90s, from
`DefaultTimeoutStartSec=`). It is not "wait until the upstream unit's own work
succeeded." A `Type=notify` unit whose script polls or retries forever without
ever notifying ready is marked `failed` once its timeout elapses, and every
unit ordered after it is then free to start — regardless of what state the
thing it was "waiting for" is actually in.

If a downstream unit's correctness depends on the upstream unit's *actual
internal state* (e.g. "tailscaled is authenticated") rather than merely on it
having *started*, ordering alone does not provide that guarantee. Either:

- poll the real state directly in the downstream unit before acting (with its
  own bounded retry/timeout discipline), or
- redesign so the downstream unit's action is safe regardless of the
  upstream unit's actual completion state — idempotent, or gated on a more
  precise, directly observable signal instead of unit ordering.

## Why This Matters

This is easy to miss because `After=`+`Wants=` (the pull-in pairing this repo
already establishes in `modules/nixos/wifi.nix:78-81`) is usually sufficient —
for units that reliably reach a real terminal state quickly, "started" and
"succeeded" are close enough not to matter. The gap only surfaces for a
specific unit shape: `Type=notify` with an internal retry loop and no upper
bound other than `TimeoutStartSec`. Assuming `After=` means "I only run once
the upstream's actual job is done" silently breaks the moment that upstream
unit can time out without completing — offline boot, slow network, or any
other transient failure the retry loop is specifically designed to survive
forever.

## When to Apply

Before ordering a new unit `After=`/`Before=` an existing `Type=notify` (or
any long-retry) unit, read that upstream unit's actual script for its retry
and exit behavior, not just its description — check whether it can time out
or fail without completing its real job. If the downstream unit's correctness
assumes the upstream's *actual state*, add an explicit state check inside the
downstream unit itself rather than trusting ordering alone.

## Examples

`modules/nixos/services/tailscale.nix`'s `tailscale-dedup-device.service` was
redesigned around this finding: instead of trusting
`After=tailscaled-autoconnect.service` to mean "tailscaled is authenticated,"
it now checks a directly observable, precise signal — whether
`/var/lib/tailscale/tailscaled.state` exists — and is ordered
`Before=tailscaled-autoconnect.service` so it runs early, deliberately
independent of that unit's eventual outcome. See KTD3 in
`.compound-engineering/artifacts/plans/2026-09-23-1708-feat-tailscale-firewall-networking-plan.md`
for the full before/after design history, including the separate
hostname-collision defect this same redesign also fixed.

## See also

- [A check that reads an option value passes when the option is disabled or renamed](nix-check-reads-option-value-not-materialized-output.md) — a related but distinct trap: that one is about a *check* reading a declared value instead of the materialized output; this one is about *unit ordering itself* not meaning what it appears to mean.
