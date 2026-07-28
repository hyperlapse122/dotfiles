---
title: "CLIProxyAPI Quadlet Reintroduction - Plan"
type: feat
date: 2026-07-28
topic: cli-proxy-api-quadlet
artifact_contract: ce-unified-plan/v1
artifact_readiness: implementation-ready
product_contract_source: ce-brainstorm
planning_contract_source: ce-plan
deepened: 2026-07-28
execution: code
---

# CLIProxyAPI Quadlet Reintroduction - Plan

## Goal Capsule

- **Objective:** Reintroduce CLIProxyAPI to the dotfiles for round-robin rotation across multiple Claude subscriptions, managed as podman quadlets on Linux with CPA-Manager-Plus, and stopped before disk-persisting sleep so it cannot repeat the battery drain that caused its removal.
- **Product authority:** Repository policy governs chezmoi source ownership, container/Windows gating, and non-deployment verification; the user's power-saving motive governs which sleep states stop the service.
- **Open blockers:** None.

---

## Product Contract

### Summary

Reintroduce CLIProxyAPI with CPA-Manager-Plus: rootless podman quadlet containers on Linux, the previous binary + launchd path revived on macOS, both platforms sharing one data-root convention for CPA auth/config, with CPAMP SQLite persisted only on the Linux container side. A system-sleep hook stops the services before hibernate, hybrid-sleep, and suspend-then-hibernate, and they return automatically on resume.

### Problem Frame

The repository previously owned a CLIProxyAPI stack (native binary, systemd user service, launchd agent, management panel assets) and removed it on 2026-07-21 because the always-on proxy drained laptop battery. Historical plans for that integration and its removal are retained under `docs/plans/`.

The need returned with a sharper shape: the user runs multiple Claude subscriptions and wants a local proxy that rotates across them. Reintroduction without a power story would recreate the removal reason, so sleep-state handling is a core requirement of this plan, not an accessory.

### Key Decisions

- **Containers over downloaded binaries on Linux** (session-settled: user-directed — chosen over reviving the binary + native-service path on Linux: the user asked for podman quadlet management instead of download-and-run). Quadlets are rootless user units, matching the previous integration's user-service philosophy.
- **Stop over pause on disk-persisting sleep** (session-settled: user-directed — chosen over `podman pause`: hibernate powers the machine off, so preserving RAM state buys nothing; stopping also matches the Open Design sleep-hook precedent in `docs/plans/2026-07-25-001-feat-open-design-hibernate-stop-plan.md`).
- **CPA-Manager-Plus as a separate container** (session-settled: user-directed — chosen over CPAMP-as-single-entrypoint: the side-by-side layout mirrors the upstream project's published Compose, where CPAMP proxies the CPA management API and persists request stats in its own SQLite).
- **One bind-mounted data root** (session-settled: user-directed — chosen over per-service volumes: CPA auth/config and CPAMP SQLite live under a single host directory so credentials and stats are managed in one place, on both platforms). Subdirectories are exclusive per service — CPA alone writes `config/` and `auth/`, CPAMP alone writes `cpamp/` — so no two writers ever share a file.
- **Linux + macOS, split delivery** (session-settled: user-directed — chosen over Linux-only: macOS keeps the previous binary + launchd approach because quadlets have no launchd integration; Windows and containers stay excluded).
- **Suspend-then-hibernate included in stop states** (session-settled: user-approved — agent proposed including it over excluding it as the Open Design hook did: it is Fedora's default sleep path and systemd calls the hook only once, at `pre`; excluding it would miss the most common disk-sleep on the target laptop).
- **Automatic restart on resume, only for services the hook stopped** — chosen over unconditional restart: an operator who deliberately stopped the proxy before hibernating must not find it revived on resume. The hook records which units it actually stopped and restarts only those.
- **Image versions pinned through release-lock OCI entries** — chosen over digest literals in quadlet files and over `AutoUpdate=registry`: repository policy forbids render-time release resolution, and the release-lock registry is the single sanctioned version source. The lock gains an OCI-image kind so the hourly refresh re-resolves image digests the same way it re-resolves binary releases. Because quadlets do not pull or restart on unit-file change, the provisioner pulls the new ref and restarts the services when a rendered quadlet changes — rollouts do not silently ride the sleep cycle.
- **A dedicated `.network` quadlet for inter-container DNS** — container-name resolution requires a user-defined network (the default podman network has no inter-container DNS), and netns sharing (`Network=container:...`) is incompatible with publishing CPAMP's own port and would fuse the two services' lifecycles, contradicting the separate-container decision. This is a forced choice, not a taste call.
- **macOS panel served by CPA in CPAMP lightweight mode** (session-settled: user-approved at synthesis — chosen over a second macOS process for CPAMP: CPA can serve the CPAMP panel itself via `panel-github-repository`, so macOS gains the same panel UI with no extra service; CPAMP's SQLite statistics exist only on the Linux container side).
- **Panel and management credentials from 1Password op refs, injected at runtime only** — chosen over upstream auto-generated credentials and over rendering the credential into any chezmoi target: the previous integration's contract was that a reconciler reads the op ref at apply time and never renders the credential into a target, fingerprint, or service definition. The dual-OS provisioner revives that contract; the managed config keeps `secret-key: ""` and the provisioner seeds a writable runtime copy. The seed is one-shot — credential rotation follows a documented re-seed procedure.
- **Stop ordering: CPAMP before CPA** — CPAMP continuously talks to CPA's management API, so stops run CPAMP-first via an `After=` declaration; otherwise CPAMP error-writes through its own shutdown window on every hibernate.

### Requirements

**Proxy service**

- R1. On Linux, CLIProxyAPI runs as a rootless podman quadlet user service listening on localhost, provisioned and lifecycle-managed entirely through chezmoi source.
- R2. The proxy routes requests across the user's enrolled Claude subscription accounts with rotation, so no single subscription absorbs all usage.
- R3. On macOS, the previous binary + launchd delivery is revived for the same proxy purpose; macOS carries no quadlet path.

**Management panel**

- R4. CPA-Manager-Plus runs as its own container alongside the proxy, proxies the CPA management API, and persists request/usage statistics in its own SQLite store.
- R5. Both services are reachable only from the local machine; no LAN exposure is provisioned.
- R13. On macOS, the panel is served by CPA itself in CPAMP's lightweight mode (no separate panel process, no SQLite statistics on macOS).

**Data**

- R6. All persistent state — CPA auth and config, CPAMP SQLite — lives under one bind-mounted host directory shared by both containers, and the macOS delivery uses the same data root convention.

**Power**

- R7. On Linux, the services are stopped before the system enters hibernate, hybrid-sleep, or suspend-then-hibernate.
- R8. Plain suspend does not stop the services; a RAM-suspended session keeps its running proxy.
- R9. Sleep handling is best-effort and never blocks or aborts the sleep transition.
- R10. The services start again automatically after resume, with no operator action.

**Platform scope and verification**

- R11. Windows and container environments provision nothing for this integration, enforced through the existing ignore-gate mechanism.
- R12. Verification follows repository policy: isolated renders, stubbed commands, no live `chezmoi apply`, no real service starts.

### Key Flows

- F1. Provision
  - **Trigger:** `chezmoi apply` on a Linux non-container host.
  - **Steps:** Quadlet units and the sleep hook are installed; the data root exists; podman pulls the pinned images; the user services start.
  - **Outcome:** Proxy on its localhost port and panel on its own, both backed by the shared data root.
- F2. Account onboarding
  - **Trigger:** Operator adds a Claude subscription.
  - **Steps:** The operator completes the provider's OAuth flow inside the container (`podman exec` login command, browser on the host); credentials land in the shared data root; rotation covers the new account.
  - **Outcome:** Subsequent requests rotate across all enrolled subscriptions.
- F3. Sleep and resume
  - **Trigger:** System enters hibernate, hybrid-sleep, or suspend-then-hibernate.
  - **Steps:** The sleep hook stops the proxy and panel services for the logged-in user and records which it stopped; failures are ignored.
  - **Outcome:** Nothing from this integration draws power while the machine is off; after resume the recorded services run again.

### Acceptance Examples

- AE1. **Covers R7.** Given the proxy and panel are running, when the system begins hibernate, hybrid-sleep, or suspend-then-hibernate, then both services are stopped before the transition completes.
- AE2. **Covers R8.** Given the services are running, when the system begins plain suspend, then both services remain running.
- AE3. **Covers R9.** Given the services are absent or the user manager is unreachable, when the sleep hook fires, then the sleep transition proceeds normally.
- AE4. **Covers R10.** Given the services were stopped by the sleep hook, when the machine resumes, then the proxy answers requests and the panel loads without operator action.
- AE5. **Covers R2.** Given two or more Claude subscriptions are enrolled, when requests arrive, then usage distributes across accounts rather than pinning to one.
- AE6. **Covers R6.** Given both containers are recreated from scratch, when they start against the existing data root, then enrolled accounts and historical stats survive intact.

### Scope Boundaries

**In scope:** Linux quadlet delivery of CLIProxyAPI and CPA-Manager-Plus; the macOS binary + launchd revival; the shared data root; sleep-stop and resume-restart on Linux; ignore gates for Windows and containers; the release-lock OCI-image kind; `.chezmoiremove` entries for the old user unit and launcher so the removed integration's boot persistence cannot collide with the new stack; isolated verification.

**Out of scope:** plain-suspend stopping; LAN or remote exposure of either service; Windows and container hosts; broader manual cleanup of leftover state from the removed integration (versioned binaries, stale auth credentials — the provisioner warns and documents a manual purge instead); changes to direct provider routing in agent configs (agents adopt the proxy separately, if at all); CPAMP SQLite statistics on macOS.

### Assumptions

- CLIProxyAPI's official container image is Docker Hub `eceasy/cli-proxy-api` (multi-arch; the brainstorm's assumed `ghcr.io/router-for-me/cliproxyapi` does not exist — corrected here) and CPA-Manager-Plus publishes `ghcr.io/seakee/cpa-manager-plus`, per both projects' current documentation.
- Target Linux hosts already run podman with systemd user session support and lingering, consistent with the repository's existing podman provisioning.
- Target Linux hosts run SELinux enforcing (the repository's own container config encodes this); rootless bind mounts therefore carry `:Z` labels and an explicit uid-mapping decision.
- Upstream write behavior — CPA token-file atomicity, CPAMP SQLite journal mode — is unverified; SIGKILL mid-write degrades to WAL recovery or re-login, never to plan-level data loss. Checked at implementation time.
- CPAMP's lightweight panel mode is served from a released panel asset; its exact asset name is verified at implementation time (unverified detail, low risk).

### Sources / Research

- Prior integration and removal records: `docs/plans/2026-07-16-002-feat-cli-proxy-api-infrastructure-plan.md`, `docs/plans/2026-07-16-003-feat-cli-proxy-api-management-api-plan.md`, `docs/plans/2026-07-21-004-refactor-remove-cli-proxy-api-plan.md`.
- Sleep-hook precedent: `docs/plans/2026-07-25-001-feat-open-design-hibernate-stop-plan.md`.
- Upstream projects: `github.com/router-for-me/CLIProxyAPI` (official image `docker.io/eceasy/cli-proxy-api`), `github.com/seakee/CPA-Manager-Plus` (image `ghcr.io/seakee/cpa-manager-plus`; Compose with CPA and CPAMP side by side; lightweight panel mode).
- Rootless Quadlet practice (per-container unit files under `~/.config/containers/systemd/`, `WantedBy=default.target`, `%h` volume specifier, `AutoUpdate=registry` + `podman auto-update`): [Quadlet — Podman containers under systemd](https://mo8it.com/blog/quadlet/).
- Prior macOS integration files, recoverable from git history at `5d8cbc5^`.
- Removal motive and rotation purpose: user dialogue, 2026-07-28.

---

## Planning Contract

### Architecture Summary

Two delivery paths share one data-root convention:

- **Linux:** three rootless quadlets under `dot_config/containers/systemd/` (the repository's first quadlet convention) — `cli-proxy-api.network`, `cli-proxy-api.container`, and `cpa-manager-plus.container` — both containers on the dedicated network (container-name DNS, localhost-only published ports), mounting exclusive subdirectories of one data root (`~/.local/share/cli-proxy-api/{config,auth,cpamp}`) with `:Z` labels. Image references come from the release-lock through `release-lock-ref.tmpl`.
- **macOS:** the pre-removal binary + launchd stack recovered from git history, rewritten to resolve the CPA binary and panel asset through release-lock instead of the old render-time `gitHubLatestRelease`/`curl` templates (which violate current repository policy). CPA serves the CPAMP panel itself in lightweight mode.
- **Shared provisioner:** a revived `.chezmoiscripts/90-services/` phase holds one dual-OS provisioner — on Linux it creates the data root, seeds the runtime config, reloads the user manager, and pulls/restarts services when quadlets change; on macOS it seeds the runtime config and bootstraps the launchd agent in the current login session. The managed config never carries the secret; the provisioner injects it into the runtime copy via the secret-read shim.
- **Power:** a `system-sleep` hook shipped through `system/linux/etc/` + the `system.yaml` manifest stops both user services at `pre` for hibernate, hybrid-sleep, and suspend-then-hibernate (recording which it stopped) and restarts exactly those at `post`; always exit 0.
- **Version source:** `packages/release-lock` gains an OCI-image kind; image tags resolve to registry digests through the registry HTTP API at lock-refresh time, never at render time.

### Risks & Dependencies

- **Leftover state from the removed integration.** The 2026-07-21 removal was source-only and deliberately left the deployed user unit, launcher, and `auth/` credentials in place. Invariant: the new quadlet is the only service binding `127.0.0.1:8317`, and only intended credentials go live. Failure path: the old lingering-enabled unit starts at login, binds the port first, and silently re-adopts stale OAuth credentials into rotation. Mitigation: `.chezmoiremove` entries for the old unit and launcher (U5); the provisioner warns when `auth/` is non-empty at first seed and documents a manual purge.
- **One-shot config seed drifts from the template and from 1Password.** Invariant: the live management secret equals the current `op://` value. Failure path: CPA bcrypt-rewrites the seeded secret on first start, so rotating the 1Password item or editing the config template never reaches the live config. Mitigation: seed written `0600` into a `0700` dir; documented re-seed procedure (delete the runtime config, re-apply); the provisioner warns when non-secret fields diverge from the template, since chezmoi cannot own this file.
- **SELinux and uid mapping on the bind mounts.** Invariant: both containers can write their subdirs and the host user keeps ownership of credential files. Failure path: unlabeled `~/.local/share` mounts get permission-denied under enforcing SELinux; container-internal uids can leave files unreadable by the host user. Mitigation: `:Z` labels per container (never `:z` — subdirs are exclusive) and an explicit uid decision (container root mapping to host user, or `UserNS=keep-id`) settled at implementation; render tests assert the flags.
- **Repository garbage collection.** The repo enables a weekly `podman-prune.timer`. All state must live in the named bind mounts — no anonymous volumes carrying state — or the repo's own GC destroys it.
- **Stop-cycle durability.** Daily suspend-then-hibernate cycles the stop path many times per week. A timed-out stop degrades to SIGKILL; exposure is token files and in-flight stats writes, not committed SQLite state. Mitigation: CPAMP-first ordering (Key Decisions), a deliberately chosen `TimeoutStopSec`, and the upstream write-behavior assumption recorded above.
- **`eceasy/cli-proxy-api` is a third-party Docker Hub republisher, not a router-for-me-owned namespace.** Digest pinning mitigates tag mutation, not provenance; the registry entry carries a provenance comment recording this trust boundary.

### Implementation Units

#### U1. Release-lock OCI-image kind and registry entries

- **Files:** `packages/release-lock/src/types.ts` (`ResolverKind` gains the kind; `LockedTool` gains a platform-free digest field), `packages/release-lock/src/resolve-all.ts` (resolver dispatch entry), new `packages/release-lock/src/oci-image.ts` + `packages/release-lock/test/oci-image.test.ts` (one test file per resolver, matching repo convention), `packages/release-lock/src/registry.ts` (entries for `docker.io/eceasy/cli-proxy-api` — with a provenance comment — and `ghcr.io/seakee/cpa-manager-plus`); `.chezmoitemplates/release-lock-ref.tmpl` (new platform-free `imageRef` field branch composed from version + digest — the current field whitelist requires a platform for every non-version field); `.chezmoidata/releases.json` (regenerated, never hand-edited).
- **What:** For each declared image, resolve the tracked tag to a manifest-list digest via the registry HTTP API (token + `Accept` manifest headers) and store tag + digest. Multi-arch manifest lists are expected; a tag the registry does not publish is a hard error, matching existing strictness — a failed resolution keeps the last committed entry and the refresh run fails. No artifact downloads: digests come from the registry API.
- **Exit criterion:** `.chezmoidata/releases.json` regenerated in-tree so U2/U4 renders can resolve the new keys.
- **Tests:** resolver unit tests with mocked registry responses — digest extraction from a manifest list, hard error on missing tag, Docker Hub vs GHCR token flow.
- **Covers:** enabler for R1/R4 (no direct AE).

#### U2. Linux quadlets, data root, and dual-OS provisioner

- **Files:** `dot_config/containers/systemd/cli-proxy-api.network`, `dot_config/containers/systemd/cli-proxy-api.container.tmpl`, `dot_config/containers/systemd/cpa-manager-plus.container.tmpl`; `.chezmoidata/cli-proxy-api.yaml` (ports, data-root subpaths, management toggle — op refs only, revived from `5d8cbc5^`); `.chezmoiscripts/90-services/run_onchange_after_provision-cli-proxy-api.sh.tmpl`.
- **What:** CPA publishes `127.0.0.1:8317` plus the provider OAuth callback ports needed for the login flow (exact set confirmed at implementation against upstream docs); CPAMP publishes `127.0.0.1:18317`, reaches CPA by container name over `cli-proxy-api.network`, and declares `After=cli-proxy-api.service` so stops run CPAMP-first. Volumes map `config/`, `auth/`, `cpamp/` with per-container `:Z` labels; `TimeoutStopSec` chosen deliberately; `WantedBy=default.target` so lingering starts the services at login. The provisioner (dual-OS, reviving the old reconciler's role): on Linux creates the data-root dirs, seeds the runtime config when absent (`0600` file in a `0700` dir, management secret injected through the secret-read shim, never rendered into a target or fingerprint), warns on non-empty `auth/` and on non-secret drift from the template, runs `systemctl --user daemon-reload`, and when a rendered quadlet changed, pulls the new ref and restarts the services; on macOS seeds the same runtime config and runs `launchctl bootstrap`/`kickstart` so the agent loads in the current login session. Its onchange fingerprint covers the quadlets, the config template, the data file, and `.chezmoidata/releases.json` (raw source, never rendered secrets) so digest bumps retrigger it.
- **Tests:** render both quadlets and the script through `chezmoi execute-template` with the stub-op scratch setup; assert image refs resolve from the lock, `:Z` flags are present, each service mounts only its own subdirs, all state paths are under the bind-mounted root (no anonymous volumes), and no secret appears in fingerprints.
- **Covers AE6** (layout invariant asserted by the render tests; runtime survival verified by contract only).

#### U3. System-sleep hook

- **Files:** `system/linux/etc/systemd/system-sleep/cli-proxy-api.sh`; `.chezmoidata/system.yaml` (manifest entry, mode `755` — no gate, matching the Open Design entry; Linux-only/container-skip is inherited from the installer); `.ci/test-cli-proxy-api-sleep-hook.sh`.
- **What:** At `pre` for `hibernate`, `hybrid-sleep`, or `suspend-then-hibernate`, stop both user services for each logged-in user (reusing the Open Design hook's loginctl/getent/systemctl mechanics) and record which units were actually stopped; at `post`, start exactly those units again. Plain `suspend` is untouched. Always exit 0; missing units or an unreachable user manager are silent no-ops.
- **Tests:** the new `.ci` script stubs `loginctl`/`getent`/`systemctl` and asserts: stop on each disk-sleep state, no-op on suspend, restart on `post` of only the recorded units, exit 0 when units are absent. The Open Design hook and its test are not modified.
- **Covers AE1, AE2, AE3; AE4** (restart-at-post mechanism; real resume behavior verified by the stub contract).

#### U4. macOS binary + launchd revival

- **Files:** recovered from `5d8cbc5^` and rewritten: `dot_config/cli-proxy-api/readonly_config.yaml` (plain file, not a template, as before — localhost:8317, auth-dir under the shared data-root convention, `panel-github-repository` pointing at CPA-Manager-Plus, `secret-key: ""` because the U2 provisioner seeds the writable runtime copy), `dot_local/libexec/private_executable_cli-proxy-api-launch`, `Library/LaunchAgents/readonly_dev.h82.cli-proxy-api.plist.tmpl`; `packages/release-lock/src/registry.ts` gains a `githubRelease` entry for the CPA binary (existing kind — per-platform assets); the consuming externals block reads versions through `release-lock-ref.tmpl`.
- **What:** Same proxy purpose and data-root convention as Linux, no quadlet path, no separate panel process, no SQLite on macOS. The old `cli-proxy-api-ref.tmpl`/`panel-ref.tmpl` render-time resolution templates are **not** restored — release-lock consumption replaces them. In-session loading comes from the U2 provisioner's `launchctl bootstrap`, not from `RunAtLoad` alone. The exact lightweight-panel asset name is confirmed at implementation time.
- **Tests:** render the macOS targets through `execute-template`; assert no render-time network builtins remain in the revived templates.
- **Covers R3, R13.**

#### U5. Ignore gates and removal entries

- **Files:** root `.chezmoiignore` (container-fact block additions; the historical Windows block restored); `.chezmoiremove` (old user unit `/.config/systemd/user/cli-proxy-api.service` and old launcher `/.local/libexec/cli-proxy-api-launch`).
- **What:** Quadlets and the 90-services provisioner deploy only on Linux non-container; the launchd plist, launcher, and macOS config deploy only on darwin; Windows and containers receive nothing (R11). The container-fact gate targets the `containers/systemd` **subpath** — `dot_config/containers/` also holds `auth.json` and `registries.conf`, which deploy everywhere. `dot_config/.chezmoiignore` already Linux-gates the whole `containers/` dir (verified). Container skips change only in the single gated `.chezmoiignore` block, per repository policy.
- **Tests:** execute-template render matrix across linux / darwin / windows / container fact combinations asserting presence and absence.
- **Covers R11.**

#### U6. CI wiring and documentation

- **Files:** `.github/workflows/ci.yml` (job for the U3 sleep-hook test plus the U5 render matrix, structured like the existing open-design-integration job); `AGENTS.md` (script-tree table gains the `90-services` row; release-lock section notes the OCI-image kind; container section documents the first quadlet convention, including the `.network` idiom).
- **What:** Make the new tests run in CI and bring repository documentation in line with the new conventions.
- **Tests:** CI green on the branch; after push, `render-dotfiles.yml` and `ci.yml` watched to terminal success per repository delivery rules.
- **Covers R12.**

### Unit Sequencing

U1 → U2 → U4 (macOS consumes the lock, and the U2 provisioner seeds the runtime config and bootstraps the launchd agent); U3 and U5 are independent of U1; U6 last.

---

## Verification Contract

- Every changed template and script rendered through `chezmoi execute-template` with the repo's stub-op scratch setup; scripts compared as rendered text on both sides.
- `.ci/test-cli-proxy-api-sleep-hook.sh` green locally and in CI; render-matrix assertions for the ignore gates green.
- `packages/release-lock` test suite green; `.chezmoidata/releases.json` regenerated by the lock tooling only.
- `git diff --check` clean; diff limited to the requested scope; no live `chezmoi apply`, no real service starts, no live network release resolution in templates.

## Definition of Done

- All six units landed; each AE traceable to at least one unit's tests or to the stub/render contract that stands in for runtime behavior (AE4, AE5, AE6 verified by contract only — recorded as such).
- `AGENTS.md` updated for the `90-services` phase, the quadlet convention (including the `.network` idiom), and the OCI lock kind.
- Both CI workflows terminal-successful after push.
- Product Contract requirements R1–R13 unchanged in meaning; this Planning Contract added no new product behavior beyond the decisions recorded in Key Decisions.
