---
artifact_contract: ce-unified-plan/v1
artifact_readiness: implementation-ready
execution: code
product_contract_source: ce-plan-bootstrap
title: "refactor: remove CLIProxyAPI from dotfiles"
date: 2026-07-21
type: refactor
depth: standard
---

# refactor: Remove CLIProxyAPI from dotfiles

## Summary

Remove CLIProxyAPI completely from the active chezmoi source state. Delete its managed
config, launcher, native service definitions, release and panel externals, resolver
templates, reconciler, tests, fixtures, and dedicated CI job. Remove supporting data,
package annotations, ignore gates, and active documentation that exist only for the
integration. Preserve unrelated tools and direct provider configuration, and retain
historical `docs/plans/` artifacts as an audit trail.

This is a source-state removal only. It does not deploy to `$HOME`, add a teardown
script, stop a currently running service, or delete live provider-auth/state. Future
`chezmoi apply` runs stop managing the deleted targets; any one-time live cleanup is a
manual operator action outside this change.

## Problem Frame

The repository currently owns a workstation-only CLIProxyAPI stack across Linux and
macOS: release resolution, downloaded binary and panel assets, a reviewed config,
launcher, reconciler, systemd/launchd services, Management secret data, package support,
container/Windows exclusion gates, and extensive render/native smoke coverage. The user
no longer wants this component in the dotfiles. A partial deletion would leave expensive
network resolution, dangling template includes, invalid CI dependencies, stale package
rationale, or documentation that promises a service no longer managed.

## Requirements

- **R1** — No active chezmoi target, external, template, script, data key, service, or
  package requirement installs, configures, launches, reconciles, or references
  CLIProxyAPI.
- **R2** — Dedicated CLIProxyAPI tests, fixtures, workflow steps/jobs, artifacts, and
  aggregate-job dependencies are removed while the remaining workflow stays valid.
- **R3** — Active repository instructions and README content accurately describe the
  remaining dotfiles and contain no CLIProxyAPI claims.
- **R4** — Unrelated direct-provider/Pi behavior remains intact; only stale migration or
  comparison comments are rewritten or removed.
- **R5** — Historical implementation plans remain unchanged as archival records.
- **R6** — Verification proves clean rendering, valid workflow syntax, no dangling active
  references, correct mirrors, and a request-scoped clean diff without deploying `$HOME`.

## Key Technical Decisions

- **KTD1 — Delete ownership; do not add teardown behavior.** Repository instructions
  explicitly forbid teardown/revert scripts. Removing managed source is the supported
  lifecycle. Live service/state removal is not automated and provider credentials are
  never read or deleted.
- **KTD2 — Purge active references, preserve historical plans.** The zero-reference sweep
  excludes `docs/plans/**`, whose purpose is to retain prior implementation context.
  Active comments that use CLIProxyAPI only as an analogy or migration narrative are
  rewritten to describe their current local pattern without the removed name.
- **KTD3 — Remove the entire dedicated CI surface.** Delete the resolver/native-smoke job,
  its fixtures and shell tests, container/Windows absence assertions that only protect the
  removed integration, uploaded artifacts, `needs` edges, aggregate matrix entries, env
  values, and summary rows. Preserve every unrelated shared render/apply assertion.
- **KTD4 — Remove support packages only when integration-exclusive.** Remove `lsof` from
  Fedora/Ubuntu package data because its stated and discovered owner is CLIProxyAPI
  listener verification. Keep `jq`: it has independent Pi/Claude JSON consumers and the
  macOS external remains required outside this integration.
- **KTD5 — Keep direct agent providers unchanged.** The empty Pi provider map remains the
  managed baseline; only comments and OS/container gates whose stated purpose was the old
  proxy migration are simplified when they still own a current target.

## Assumptions

- **A1 — “Remove from this dotfiles” means remove all active source ownership, tests, and
  documentation, not erase historical plan records.** Historical plans are non-rendered
  audit artifacts and retaining them prevents rewriting project history.
- **A2 — No live cleanup is authorized.** The repository contract says never deploy live
  `$HOME` unless asked and never add teardown scripts. Verification therefore uses only
  isolated scratch destinations.

## Implementation Units

### U1. Delete CLIProxyAPI managed runtime and release sources

**Goal:** Remove every file whose sole purpose is to install or run CLIProxyAPI.

**Requirements:** R1, R4; KTD1, KTD4, KTD5.

**Files:** `.chezmoidata/cli-proxy-api.yaml`,
`.chezmoitemplates/cli-proxy-api-ref.tmpl`,
`.chezmoitemplates/cli-proxy-api-panel-ref.tmpl`,
`.chezmoiscripts/90-services/run_after_cli-proxy-api-service.sh.tmpl`,
`dot_config/cli-proxy-api/readonly_config.yaml`,
`dot_local/libexec/private_executable_cli-proxy-api-launch`,
`dot_config/systemd/user/readonly_cli-proxy-api.service`,
`Library/LaunchAgents/readonly_dev.h82.cli-proxy-api.plist.tmpl`,
`.chezmoiexternals/ai-agents.toml`, `.chezmoidata/packages.yaml`,
`.chezmoiignore`, `dot_config/.chezmoiignore`, `.chezmoi.toml.tmpl`,
`.chezmoiexternals/dev-tools.toml`, `.chezmoiexternals/system.toml`,
`.chezmoiscripts/70-agents/run_onchange_after_update-pi-extensions.sh.tmpl`,
`.chezmoidata/agents.yaml`, `dot_pi/agent/readonly_models.json.tmpl`.

**Approach:** Delete dedicated files; remove the binary/panel external blocks and top
summary mention; remove integration-only `lsof` package entries; remove obsolete
platform/container ignore rules; and rewrite remaining comments so they describe current
direct-provider or release-resolution behavior without the removed component.

**Verification:** Render every changed surviving template with the isolated stub-`op`
configuration. Confirm active source has no resolver include, `cliProxyApi` data access,
managed service target, or CLIProxyAPI literal.

### U2. Delete dedicated verification and repair workflow topology

**Goal:** Remove integration-only tests and make `render-dotfiles.yml` internally
consistent without weakening unrelated coverage.

**Requirements:** R2, R6; KTD3.

**Files:** `.ci/fixtures/cli-proxy-api-checksums-v7.2.80.txt`,
`.ci/fixtures/cli-proxy-api-config-v7.2.80.diff`,
`.ci/run-cli-proxy-api-native-smoke.sh`, `.ci/smoke-cli-proxy-api.sh`,
`.ci/test-cli-proxy-api-infrastructure.sh`, `.ci/test-cli-proxy-api-service.sh`,
`.github/workflows/render-dotfiles.yml`.

**Approach:** Delete dedicated fixtures/scripts and remove the full CLIProxyAPI matrix
job. Excise target/internal absence assertions from shared Linux/macOS/Windows jobs,
remove artifact upload and downstream `needs`/matrix/result wiring, then parse the YAML
and inspect the edited job boundaries for orphaned steps, variables, or dependencies.

**Verification:** Parse the workflow as YAML; sweep for deleted job identifiers and
script paths; verify all remaining `needs.*` and aggregate matrix values refer to existing
jobs; run the repository's non-native isolated render checks that do not deploy `$HOME`.

### U3. Update active documentation and instruction mirrors

**Goal:** Make active documentation accurately describe the repository after removal.

**Requirements:** R3, R5, R6; KTD2.

**Files:** `AGENTS.md`, `dot_agents/readonly_AGENTS.md`, `README.md`, and sibling
`CLAUDE.md` mirrors (verification only; mirrors remain one-line includes).

**Approach:** Remove the CLIProxyAPI contract section and service-tree description;
update container/platform, external inventory, prerequisites, directory map, and agent
baseline prose. Do not edit historical `docs/plans/**`. Preserve each `CLAUDE.md` as
exactly `@AGENTS.md`.

**Verification:** Zero active-reference sweep excluding historical plans; mirror checks
for every directory containing `AGENTS.md`; read the resulting README sections for
coherence.

### U4. Run isolated repository verification

**Goal:** Prove the removal is complete without applying to the live home directory.

**Requirements:** R1–R6.

**Dependencies:** U1–U3.

**Approach:** Use a task-scoped `$HOME/.cache/agent-scratch` directory, empty chezmoi
config, newline-free stub `op`, explicit `--source "$PWD"`, and throwaway destination.
Render every changed template/script that remains. Run targeted repository checks and
workflow parsing; use full CI as the cross-platform authority after push.

**Verification:** `git diff --check`; `git status --short`; request-scoped `git diff`;
active-reference sweep excluding `docs/plans/**`; mirror assertions; isolated chezmoi
render/archive or repository test commands; and both `render-dotfiles.yml` and `ci.yml`
green on the PR.

## Scope Boundaries

**In scope:** all active source, tests, CI, package-only dependencies, and documentation
owned solely by CLIProxyAPI; removal of stale mentions from surviving configuration.

**Out of scope:** applying changes to live `$HOME`; stopping/unloading a live service;
deleting `~/.local/share/cli-proxy-api`, provider auth, logs, or historical binaries;
deleting or rewriting historical plans; changing direct OpenCode/Pi/provider routing;
replacing CLIProxyAPI with another proxy.

### Manual post-merge decommission checklist

This checklist is operator guidance only and requires separate authorization; the
implementation MUST NOT execute it. On each previously provisioned host, stop and disable
the `cli-proxy-api` systemd user service or `dev.h82.cli-proxy-api` LaunchAgent, verify no
process listens on TCP port 8317, then remove the deployed service definition, launcher,
source/runtime config, and versioned binary/panel state. Treat provider-auth deletion as a
separate explicit opt-in action: never read or print credential contents, and retain the
auth directory unless the operator specifically authorizes its deletion after confirming
the provider sessions are no longer needed.

## Risks and Mitigations

- **Workflow YAML damage from deleting a large job:** remove its full keyed block and all
  downstream references, then parse YAML and rely on both repository workflows in CI.
- **Dangling Go-template include/data reference:** run a zero-reference sweep and render
  every changed surviving template using the repository's isolated recipe.
- **Accidental removal of shared dependencies:** retain `jq` and any other package/tool
  with independent consumers; remove only `lsof`, whose repository ownership is confined
  to CLIProxyAPI readiness.
- **Misleading live-state expectations:** PR documentation states source removal does not
  uninstall or delete live state, consistent with repository policy.

## Verification Matrix

| Requirement | Proof |
|---|---|
| R1 | Active-source sweep plus isolated render contains no CLIProxyAPI ownership/reference |
| R2 | Deleted CI scripts/fixtures, valid YAML, no dangling job/needs/result references |
| R3 | README and both instruction sources read coherently with zero active mentions |
| R4 | Pi/provider rendered targets remain present and direct; unrelated render assertions pass |
| R5 | `git diff -- docs/plans` contains only this new removal plan |
| R6 | Mirror checks, `git diff --check`, scoped diff/status, isolated checks, PR CI green |

## Acceptance Criteria

- All dedicated runtime, service, release, panel, reconciler, test, and fixture files are
  deleted from active source.
- No active file outside `docs/plans/**` contains `cli-proxy-api`, `CLIProxyAPI`,
  `cliProxyApi`, or the dedicated `127.0.0.1:8317` endpoint.
- `render-dotfiles.yml` contains no CLIProxyAPI job, steps, artifacts, dependencies, or
  result summary entries and remains valid YAML.
- Surviving templates render in an isolated destination and unrelated direct-provider
  configuration remains valid.
- Root and deployed instruction mirrors remain exact one-line `@AGENTS.md` includes.
- No live `$HOME` deployment or provider-auth deletion occurs.
- The branch is committed, pushed, reviewed through a PR, and both required workflows
  reach terminal success.

## Sources and Research

- User request: remove `cli-proxy-api` from this dotfiles (2026-07-21).
- Repository ownership contracts: `AGENTS.md` and `dot_agents/readonly_AGENTS.md`.
- Current active reference/path sweep with `rg` and `rg --files` (2026-07-21).
- Prior implementation records retained for history:
  `docs/plans/2026-07-16-002-feat-cli-proxy-api-infrastructure-plan.md` and
  `docs/plans/2026-07-16-003-feat-cli-proxy-api-management-api-plan.md`.
- External research skipped: deletion scope and constraints are fully defined by current
  repository ownership and no external API choice remains.
