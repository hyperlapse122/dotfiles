---
title: "feat: provision tokscale login from 1password"
date: 2026-08-05
type: feat
artifact_contract: ce-unified-plan/v1
artifact_readiness: implementation-ready
execution: code
product_contract_source: ce-plan-bootstrap
---

# feat: provision tokscale login from 1password

## Goal Capsule

- **Objective:** Provision the Tokscale API token from 1Password into `~/.config/tokscale/credentials.json` via `tokscale login --token`, mirroring the established `auth-gitlab` / `auth-github` onchange pattern.
- **Authority:** The user request names the exact command shape (`tokscale login --token <token>`), the 1Password reference (`op://Private/Tokscale/API Token`), and the pattern to mirror (the `glab` CLI). Repository chezmoi conventions govern placement, fingerprinting, and verification.
- **Execution profile:** A bounded managed auth script and isolated render-parity test; do not apply the source state to the live home directory.
- **Stop conditions:** Stop if `tokscale login --token` writes persistent state changes beyond `~/.config/tokscale/credentials.json` (a read-only API validation call is expected and excluded), or if the script cannot soft-skip cleanly when tokscale is absent.
- **Tail ownership:** Commit, push, PR creation, CI, and review handling are owned by the invoking LFG pipeline.

---

## Product Contract

### Summary

A chezmoi-managed onchange script reads the Tokscale API token from 1Password and runs `tokscale login --token` so the token persists to `~/.config/tokscale/credentials.json` on every apply, with automatic re-login on rotation.

### Problem Frame

Tokscale persists its account token to `~/.config/tokscale/credentials.json` only through `tokscale login --token <token>` — the default browser flow is interactive and unsuited for provisioning. The `TOKSCALE_API_TOKEN` environment variable is per-invocation only: it does not write the credentials file, so it cannot provision the account for the interactive TUI, the autosubmit scheduler, or local report commands. An onchange auth script that renders the token from 1Password and calls `tokscale login --token` mirrors how `auth-gitlab` provisions the GitLab PAT: the rendered token is the fingerprint trigger, so a rotation re-runs login on the next apply. Unlike `glab auth login --use-keyring` (which stores encrypted in the OS keyring), tokscale persists the token to a plaintext JSON file at mode 0600 — a strictly weaker at-rest posture that is an inherent tool limitation, not a choice this plan can change.

### Requirements

- R1. A `run_onchange_after_auth-tokscale.sh.tmpl` script in `.chezmoiscripts/10-auth/` reads the Tokscale API token from `op://Private/Tokscale/API Token` via `secret-read.tmpl`.
- R2. The script runs `tokscale login --token <token>` to persist the token to `~/.config/tokscale/credentials.json`.
- R3. The rendered token content IS the onchange fingerprint trigger; a token rotation changes the rendered hash and re-runs login on the next apply. Verified write set: `tokscale login --token` writes `~/.config/tokscale/credentials.json` (token + profile, mode 0600) and expands `settings.json` with UI defaults on first login (mode 0644, no secrets); `device.json` and `star-cache.json` are untouched. Re-runs are idempotent upserts — both writes overwrite rather than accumulate.
- R4. The script soft-skips (exit 0) when `tokscale` is not on PATH, matching `auth-github`'s behavior when `gh` is absent. The managed wrapper at `~/.local/bin/tokscale` is always deployed on POSIX hosts (no `.chezmoiignore` entry), so the only host where this soft-skip fires is one where the wrapper was manually removed.
- R5. The script runs in the `after` phase because the `tokscale` wrapper (`dot_local/bin/private_executable_tokscale.tmpl`) deploys during chezmoi's FILE phase; a `before_` script would soft-skip on first apply and, per AGENTS.md, never retry.
- R6. Verification is isolated from the deployed home directory and does not run a real Tokscale session.

### Scope Boundaries

- **In scope:** A POSIX auth script mirroring `auth-gitlab` / `auth-github`, and an isolated render-parity test wired into CI.
- **Out of scope:** A Windows `.ps1` counterpart (the existing `tokscale` wrapper is POSIX-only and has no `.chezmoiignore` entry, so it already deploys a non-functional bash file on Windows — out of parity with this task), changing the `tokscale` runtime wrapper, changing Tokscale installation (`dot_config/mise/config.toml`), and applying the source state to the live home directory.
- **Pre-merge verification:** Confirm `op://Private/Tokscale/API Token` resolves live (or via the GPG cache) on the target host — the CI op stub returns a fixed dummy value regardless of the ref string, so a misspelled vault/item/field passes CI green and fails only on live apply.

### Key Decision

- **Use `tokscale login --token` rather than alternatives** (session-settled: user-directed — chosen over both `TOKSCALE_API_TOKEN` and a direct `credentials.json` render). The `TOKSCALE_API_TOKEN` env var is per-invocation only and does not persist to `credentials.json`, so it cannot provision the account. A chezmoi-rendered `credentials.json.tmpl` would avoid argv exposure and be declarative, but tokscale populates `username`, `avatarUrl`, and `createdAt` from its validation API call — fields not available in 1Password — and `login --token` catches revoked tokens at provision time, which a static render cannot. Governs R1, R2, R3.

---

## Planning Contract

### Key Technical Decisions

- KTD1. **Token is passed via `--token`; at-rest is plaintext, not keyring.** Two divergences from `glab auth login --stdin --use-keyring` are accepted as inherent tool limitations: (a) tokscale offers no `--stdin` path for `login`, so the token appears in the tokscale process's argv during the brief login window (the rendered script also contains the token, as `auth-gitlab`'s rendered script contains the PAT); (b) tokscale persists to plaintext `~/.config/tokscale/credentials.json` at mode 0600 (tokscale-enforced), not the OS keyring — a strictly weaker at-rest posture that rotation, revocation, and incident-response planning must account for. Both are bounded to a single-user workstation and documented in the script header. Governs R2.
- KTD2. **Run in the `after` phase, not `before`.** The `tokscale` wrapper deploys during chezmoi's FILE phase; a `run_onchange_before_` script would not find it on first apply, soft-skip, and — per AGENTS.md — be recorded as successful and never retried until the fingerprint changes or `chezmoi apply --force`. Mirrors `auth-gitlab`'s explicit after-phase reasoning. Governs R5.
- KTD3. **Prefer `tokscale` on PATH, else soft-skip — no `mise exec` fallback.** Unlike `glab` (an external binary fetched by `.chezmoiexternals/vcs.toml` that may be absent), the `tokscale` command is a chezmoi-managed wrapper at `~/.local/bin/tokscale` that is always deployed on POSIX hosts. A `mise exec` middle rung would be effectively dead code: `command -v tokscale` always succeeds wherever the `{{ if ne .chezmoi.os "windows" }}` guard passes. The script extends `~/.local/bin` onto PATH (matching `auth-github` / `auth-gitlab`), resolves `tokscale`, and soft-skips only if the wrapper was manually removed. Governs R4.

### Assumptions

- `tokscale login --token <token>` validates the token via the Tokscale API and writes `~/.config/tokscale/credentials.json` (`{token, username, avatarUrl, createdAt}`, mode 0600). The full write set is verified during implementation (R3); if `device.json` or other config files are also written, the script must account for it.
- The `TOKSCALE_API_TOKEN` environment variable does not trigger a credential-file write — it overrides saved credentials for a single invocation only (confirmed via Tokscale README and issue #203).
- The `tokscale` wrapper at `dot_local/bin/private_executable_tokscale.tmpl` is POSIX-only and deploys on all platforms (no `.chezmoiignore` entry); the auth script is POSIX-only to match.
- `secret-read.tmpl` resolves `op://Private/Tokscale/API Token` through the GPG cache or live `op`, identical to how it resolves the GitLab and GitHub PATs.
- `~/.config/tokscale/credentials.json` is already mode 0600 (tokscale-enforced); the script does not need to `chmod` it, but a defensive `chmod 600` after a successful login is harmless.

### Sources and Research

- Tokscale `login --token` persists credentials to `~/.config/tokscale/credentials.json`; `TOKSCALE_API_TOKEN` is per-invocation only: https://github.com/junhoyeo/tokscale (README), https://github.com/junhoyeo/tokscale/issues/203, commit `3a9045b` (PR #512).
- Existing `credentials.json` on this host: `{token, username, avatarUrl, createdAt}`, mode 0600 (token redacted during inspection). Existing `device.json`: `{id, createdAt}` — device identity is part of tokscale's model and must be checked against the login write set.
- `.chezmoiscripts/10-auth/run_onchange_after_auth-gitlab.sh.tmpl` owns the PAT → keyring provisioning pattern, the after-phase reasoning, the `command -v` / `mise exec` / soft-skip ladder, and the rendered-token-as-fingerprint-trigger contract.
- `.chezmoiscripts/10-auth/run_onchange_before_auth-github.sh.tmpl` owns the simpler `gh auth login --with-token` heredoc shape.
- `dot_local/bin/private_executable_tokscale.tmpl` owns Tokscale runtime invocation (`mise … exec -y node -- env ZAI_API_KEY=… TOKSCALE_DEVICE_NAME=… npx -y tokscale "$@"`); the auth script delegates to this wrapper rather than replicating its internal mise/env chain.
- `dot_config/mise/config.toml` provisions `npm:tokscale = "latest"`.
- No matching open GitHub issue or repository learning in `docs/solutions/` was found.

---

## Implementation Units

### U1. Add tokscale login auth script

- **Goal:** Persist the Tokscale API token from 1Password into `~/.config/tokscale/credentials.json` on every apply.
- **Requirements:** R1, R2, R3, R4, R5; KTD1, KTD2, KTD3.
- **Dependencies:** None.
- **Files:** `.chezmoiscripts/10-auth/run_onchange_after_auth-tokscale.sh.tmpl`.
- **Approach:**
  1. Add a POSIX `run_onchange_after_auth-tokscale.sh.tmpl` guarded by `{{ if ne .chezmoi.os "windows" -}}`.
  2. Extend `~/.local/bin` onto PATH when absent (matching `auth-github` / `auth-gitlab`).
  3. Resolve the tokscale command: `command -v tokscale` → use it, else warn and soft-skip (exit 0). No `mise exec` fallback (KTD3 — the wrapper is always deployed).
  4. Read the token via `{{ includeTemplate "secret-read.tmpl" (dict "ctx" . "ref" "op://Private/Tokscale/API Token") }}` into a shell variable.
  5. Run `tokscale login --token "$TOKEN"`; exit non-zero on failure so chezmoi retries on the next apply.
  6. After a successful login, defensively `chmod 600 ~/.config/tokscale/credentials.json` (tokscale already sets 0600; this is belt-and-suspenders).
  7. Header comments document the onchange trigger, the after-phase reasoning, the argv-exposure tradeoff, and the plaintext at-rest posture (KTD1).
- **Execution note:** Before finalizing, verify the write set: snapshot `~/.config/tokscale/` (file list + mtimes), run `tokscale login --token` once, and confirm only `credentials.json` changes. If `device.json` or other files are also written, document the additional writes in the script header and decide whether to snapshot/restore them.
- **Patterns to follow:** `.chezmoiscripts/10-auth/run_onchange_after_auth-gitlab.sh.tmpl` (after phase, PATH/soft-skip ladder, rendered-token fingerprint), `.chezmoiscripts/10-auth/run_onchange_before_auth-github.sh.tmpl` (simpler token-login shape).
- **Test scenarios:**
  - The rendered script (via op stub) contains `tokscale login --token` with the stub secret value in the token position.
  - A stub `tokscale` binary recording its args receives exactly `login --token <stub-value>`.
  - With no `tokscale` on PATH, the rendered script prints a skip warning and exits 0.
  - A nonzero exit from the `tokscale login` stub propagates as a nonzero script exit.
- **Verification:** The script renders through `chezmoi execute-template` with the op stub and isolated destination, and the stub-executable assertions pass without touching the live home directory or a real Tokscale session.

### U2. Add isolated render-parity test and wire into CI

- **Goal:** Prove the auth script renders correctly and dispatches the login command in an isolated environment.
- **Requirements:** R6.
- **Dependencies:** U1.
- **Files:** `.ci/test-tokscale-auth.sh`, `.github/workflows/ci.yml`.
- **Approach:**
  1. Add `.ci/test-tokscale-auth.sh` using strict shell mode and task-scoped scratch storage: set up an op stub, render the template via `chezmoi execute-template --source "$PWD"`, create a stub `tokscale` that records args, run the rendered script, and assert the stub received `login --token <stub-value>`.
  2. Assert the soft-skip path exits 0 when `tokscale` is not resolvable.
  3. Wire the test into the `native-fedora-x64` job's test list in `.github/workflows/ci.yml` (the POSIX job that runs the existing op-auth and `.ci/test-*.sh` scripts, around the test-list block near line 468).
- **Execution note:** Follow the `.ci/test-*.sh` strict-shell and task-scoped-scratch conventions.
- **Patterns to follow:** `.ci/test-compound-engineering-overlays.sh` (stub op + empty config + `chezmoi execute-template < real .tmpl` + run rendered script + assert — the near-exact render-parity/dispatch precedent), `.ci/` strict-shell and scratch-storage conventions.
- **Test scenarios:**
  - Test expectation: none — this unit IS the test; it performs render-parity and dispatch verification rather than adding behavior.
- **Verification:** The test passes in CI's `native-fedora-x64` job without accessing the user's live 1Password, Tokscale state, or home-directory destination.

---

## Verification Contract

| Gate | Applies to | Done signal |
|---|---|---|
| Chezmoi render with op stub and `--source "$PWD"` | U1, U2 | The auth template renders without template errors and the stub secret appears in the `--token` position |
| Stub-executable dispatch | U1 | A stub `tokscale` receives exactly `login --token <stub-value>` |
| Soft-skip path | U1 | No `tokscale` on PATH → skip warning and exit 0 |
| Failure propagation | U1 | A nonzero `tokscale login` exit propagates as a nonzero script exit |
| Write-set verification | U1 | `tokscale login --token` touches only `credentials.json` (or additional writes are documented) |
| `git diff --check` | U1, U2 | No whitespace errors |
| Scoped diff and status review | U1, U2 | Only the auth script, test, CI workflow, and plan are changed |

---

## Definition of Done

- `tokscale login --token` runs from the managed onchange script on every apply, persisting the 1Password token to `~/.config/tokscale/credentials.json`.
- A token rotation in 1Password changes the rendered fingerprint and re-runs login on the next apply.
- The script soft-skips when tokscale is absent, and propagates login failures as nonzero exits.
- The `login --token` write set is verified to touch only `credentials.json` (or additional writes are documented).
- An isolated render-parity and dispatch test passes in CI without a live apply or real Tokscale session.
- The requested changes are committed, pushed, reviewed, and carried by a green pull request.
