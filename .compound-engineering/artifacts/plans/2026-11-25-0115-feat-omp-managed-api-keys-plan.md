---
title: "Provision managed API keys for omp - Plan"
type: feat
date: 2026-11-25
topic: omp-managed-api-keys
artifact_contract: ce-unified-plan/v1
product_contract_source: ce-brainstorm
execution: code
---

# Provision managed API keys for omp - Plan

## Goal Capsule

- **Objective:** After a rebuild, omp on both production hosts can use every model provider whose API key the repository already distributes, plus Exa web search, with no `/login` and no per-host key entry.
- **Means:** Import the published key files into omp's own credential store as login-sourced API keys during activation (KTD1, KTD2).
- **Product authority:** The repository owner decides scope. This plan covers credential provisioning only; model roles, provider visibility, and model catalogs are not active scope.
- **Execution profile:** One feature branch, one pull request. The executor verifies with repository checks; the owner runs host switches (`nr switch`).
- **Stop conditions:** Stop if `omp auth import` no longer replaces a provider's stored API key or no longer keeps OAuth logins, or if keys could only reach omp through arguments, the environment of a logged command, or the Nix store.
- **Open blockers:** None.

---

## Product Contract

### Summary

Provision the six API keys already published to the shared `cli-auth` key directory into omp's credentials, so omp gets the same managed keys as Pi and OpenCode: Synthetic, OpenRouter, OpenAI, Anthropic, OpenCode Go, and Exa.

### Problem Frame

omp is installed and configured through the flake (`home/h82/agents/omp.nix`), but its credentials are not. Today `~/.omp/agent/agent.db` holds `synthetic` and `openrouter` API keys entered by hand through `/login`. A restored or new host starts with no keys. Rotating a key means repeating the manual login on every machine. omp's default model role (`synthetic/hf:zai-org/GLM-5.3-Flash`) fails until someone logs in. Pi and OpenCode already receive these keys from SOPS during activation, so omp is the only managed harness outside that flow.

### Requirements

**Coverage**

- R1. omp receives the Synthetic, OpenRouter, OpenAI, Anthropic, OpenCode Go, and Exa keys from the shared encrypted keys on both production hosts.
- R2. Each key reaches the omp provider or tool that consumes it: `synthetic`, `openrouter`, `openai`, `anthropic`, `opencode-go`, and the Exa web-search tool.
- R3. Bootstrap outputs provision none of these keys, matching the existing bootstrap rule that decrypts no SOPS secret.

**Lifecycle**

- R4. Rotating a key in SOPS reaches omp on the next host switch, with no manual omp step.
- R5. The managed keys replace the hand-entered `synthetic` and `openrouter` credentials. omp credentials for providers outside R2 stay as they are.
- R6. An OAuth login the owner later performs in omp for a provider in R2 (for example `anthropic`) takes precedence over that provider's managed API key. OpenAI subscription logins use the separate `openai-codex` provider, so they do not replace the managed `openai` key; retiring that key requires disabling `enableOpenaiApiKey`.

**Secret handling**

- R7. No plaintext key appears in the checkout, the Nix store, command arguments, logs, or CI, consistent with the existing Pi and OpenCode provisioning.

### Key Decisions

- **Provision every distributed key, not only Synthetic.** (session-settled: user-directed — chosen over Synthetic-only and Pi parity (Synthetic, OpenAI, Anthropic): omp supports all six and the keys are already distributed.) Governs R1, R2.
- **Managed keys replace the hand-entered ones.** (session-settled: user-approved — chosen over leaving the manual `synthetic` and `openrouter` logins in place: one source of truth for rotation.) Governs R5.
- **OAuth outranks managed API keys.** (session-settled: user-approved — chosen over a managed key that always wins: lets the owner switch a provider to a subscription login without editing the repository.) Governs R6.
- **Follow the existing per-host lifecycle.** Keys follow the same host coverage, bootstrap exclusion, and rotation timing as the Pi and OpenCode credentials. Governs R3, R4.

### Acceptance Examples

- AE1. **Covers R1, R2.** **Given** a production host after a switch and no prior omp login, **when** the owner starts omp, **then** the default `synthetic` model role answers, models from all five model providers in R2 are selectable, and a web search that selects Exa (for example `web_search` with model `web/exa`) authenticates with the managed key instead of Exa's keyless public MCP.
- AE2. **Covers R4.** **Given** a rotated Synthetic key in SOPS, **when** the host switches, **then** omp uses the new key without `/login`.
- AE3. **Covers R5.** **Given** an omp auth store holding hand-entered `synthetic` and `openrouter` keys plus a credential for another provider, **when** the host switches, **then** `synthetic` and `openrouter` resolve to the managed keys and the other credential is unchanged.
- AE4. **Covers R6.** **Given** the owner logs in to `anthropic` with OAuth in omp, **when** omp resolves Anthropic credentials, **then** it uses the OAuth session, not the managed API key.
- AE5. **Covers R3.** **Given** a bootstrap output, **when** it is evaluated, **then** it provisions no omp API key.

### Scope Boundaries

- Changing omp model roles, `disabledProviders`, or `models.yml` model catalogs.
- Adding new keys to SOPS; only keys already published to `cli-auth` are in scope.
- Changing how Pi or OpenCode receive their keys.
- omp auth-broker or shared credential-vault mode.
- Reading the store back after import: `omp auth import` replaces a provider's API key deterministically and exits non-zero on refusal, unlike OpenCode's skip-if-stored import.

### Dependencies / Assumptions

- The six key files are already published to the shared `cli-auth` directory (`/run/secrets/cli-auth` on NixOS, `my.secrets.stateDir` on macOS; `home/h82/security/cli-auth-directory.nix`) on both production hosts.
- omp's credential precedence at the pinned input is: runtime `--api-key`, `models.yml` `apiKey`, stored OAuth, login-stored API key, extension fallback, environment variable or `.env`, other stored API key (upstream `docs/providers.md`, "When a provider needs an API key").

### Outstanding Questions

**Deferred to Planning** (resolved by KTD1 and KTD4)

- Credential surface for R4–R6: resolved in KTD1.
- Exa coverage: resolved in KTD4.

### Sources / Research

- `home/h82/agents/omp.nix` — current omp module (settings only, no credentials).
- `home/h82/agents/opencode.nix` (`opencodeAuth`) and `home/h82/agents/pi.nix` (`piAuth`) — existing activation-time key import patterns, including the NixOS ordering after SOPS publication.
- `.compound-engineering/artifacts/plans/2026-11-19-2319-feat-opencode-api-keys-plan.md` — prior credential provisioning plan with the rotation and selected-account rules.
- `tests/agent-api-key-secrets.nix` — production and bootstrap key-provisioning checks.
- Upstream oh-my-pi at the pinned rev `6b96042`: `docs/providers.md` (credential precedence, env names), `docs/models.md` (`apiKey` value syntax and `!command`), `docs/environment-variables.md` (`SYNTHETIC_API_KEY`, `OPENROUTER_API_KEY`, `OPENAI_API_KEY`, `ANTHROPIC_API_KEY`, `OPENCODE_API_KEY`, `EXA_API_KEY`).
- Local auth store inspection (schema and provider names only): `auth_credentials` currently holds `synthetic` and `openrouter` `api_key` rows.

Product Contract preservation: unchanged (R-IDs, Key Decisions, AE-IDs carried forward; the two deferred questions now point at the KTDs that answer them).

---

## Planning Contract

### Key Technical Decisions

- KTD1. **Import into omp's auth store with `omp auth import -`, each key as `{type: api_key, source: login}`.** omp ranks a login-sourced stored key below stored OAuth and above environment variables (`packages/ai/src/auth/cascade.ts`), which satisfies R6 and keeps a stray shell `*_API_KEY` from overriding the managed key. `importAuthCredentials` (`packages/coding-agent/src/commands/auth.ts`) replaces every stored `api_key` of the imported provider and keeps OAuth rows, which satisfies R5 and R4. Probed this session against a scratch `HOME`: a second import replaced `synthetic`'s stored key and added `exa`. Rejected: `models.yml` `apiKey` (outranks OAuth, breaks R6) and wrapper-exported env vars (rank below the hand-entered login keys, so R5 would need a separate delete, and they leak into every child process). Governs R2, R4, R5, R6.
- KTD2. **A small `omp-auth-sync` Python helper owns the import.** It takes repeatable `--credential PROVIDER=KEYFILE`, reads each file, and pipes one export document to `omp auth import -` on stdin. Keys never reach argv, the environment, a temp file, or output. A missing, unreadable, or empty key file stops before omp is touched, as `scripts/opencode-auth-sync` does. It fails when `omp auth import` exits non-zero. Package it with `pythonHelper` in `packages/agent-tools.nix` beside `opencodeAuthSync`. Governs R4, R7.
- KTD3. **Run it at the same lifecycle points as `opencode-auth-sync`.** On NixOS, append it to `sops-install-secrets`' `ExecStartPost` as the user (`runuser -u <user> -- env HOME=<home> …`), gated per key by the `my.cliAuth.enable*ApiKey` options, so a rotation reaches omp even when the Home Manager generation is unchanged. `secrets.nix` reads the omp binary from a new `my.cliAuth.ompPackage` option (`nullOr package`, default `null`, no command when `null`); `lib/nixos-host.nix` sets it from `config.home-manager.users.<user>.programs.omp.package`. This keeps `secrets.nix` evaluable without Home Manager, as `tests/auth-provisioning.nix` imports it. On macOS, add `home.activation.ompAuth` after `nixConfigSecretsPublish` and `ompConfig`, only when `my.kind == "darwin" && !my.bootstrap`. Governs R1, R3, R4.
- KTD4. **Exa goes into the store as provider `exa`.** omp's Exa web-search provider reads `authStorage.keys.get("exa")` before `EXA_API_KEY` (`packages/coding-agent/src/web/search/providers/exa.ts`). The Exa MCP Websets tools read only `EXA_API_KEY` (`packages/coding-agent/src/exa/mcp-client.ts`); they stay keyless and out of scope. Governs R2.
- KTD5. **Provider ids:** `synthetic`, `openrouter`, `openai`, `anthropic`, `opencode-go`, `exa`. Each matches an `auth "<id>"` rule under upstream `packages/catalog/src/compat/rules/auth/` or the provider env table. Governs R2.

### Assumptions

- omp's auth broker stays unconfigured on both hosts; `omp auth import` refuses to run under a broker, and the helper then fails the activation loudly.
- The pinned omp keeps the `omp auth export|import` JSON format version 1.

### Sequencing

U1 (helper) first; U2 (wiring) consumes it; U3 (checks and docs) closes both.

---

## Implementation Units

### U1. Add the omp-auth-sync helper

- **Goal:** One command imports managed keys into omp's store without exposing them.
- **Requirements:** R4, R5, R6, R7. Decisions: KTD1, KTD2.
- **Dependencies:** None.
- **Files:** `scripts/omp-auth-sync` (new), `packages/agent-tools.nix`, `tests/test_omp_auth_sync.py` (new), `tests/python-script-checks.nix`.
- **Approach:** Mirror `scripts/opencode-auth-sync`'s structure (argparse, `Failure`, `read_key`). Build `{"version": 1, "credentials": [...]}` and pass it on stdin to `<omp> auth import -`. Never print a key.
- **Patterns to follow:** `scripts/opencode-auth-sync`, `tests/test_opencode_auth_sync.py` (stub binary with file-backed store and a call log).
- **Test scenarios:**
  - First import into an empty store writes all six providers as login-sourced API keys.
  - Existing hand-entered `synthetic` key is replaced; an unrelated provider's API key and an `anthropic` OAuth row survive (AE3, AE4).
  - Rotation: a changed key file replaces the stored key on the next run (AE2).
  - Missing or empty key file fails before the stub is invoked.
  - Stub import exits non-zero: the helper fails with a message that contains no key text.
  - No key appears in the stub's recorded argv or environment.
- **Verification:** `nix build .#checks.x86_64-linux.omp-auth-sync` passes (CI-verified; `tests/python-script-checks.nix` is Linux-only).

### U2. Wire the import into both hosts

- **Goal:** Production switches on NixOS and macOS run the helper after keys are published (R1, R3).
- **Requirements:** R1, R3, R4. Decisions: KTD3, KTD5.
- **Dependencies:** U1.
- **Files:** `modules/nixos/system/secrets.nix`, `lib/nixos-host.nix`, `home/h82/agents/omp.nix`.
- **Approach:** In `secrets.nix`, add the `ompPackage` option, build `ompCredentials` from the six `enable*ApiKey` options like `opencodeCredentials`, and append an `ompCommand` to `ExecStartPost` when the package is set and the list is non-empty. In `lib/nixos-host.nix`, set `my.cliAuth.ompPackage` from the Home Manager user's `programs.omp.package`. In `omp.nix`, add `home.activation.ompAuth` under the darwin-production guard, after `nixConfigSecretsPublish` and `ompConfig`, skipping on `DRY_RUN`, with paths from `home/h82/security/cli-auth-directory.nix`.
- **Patterns to follow:** `opencodeCommand` in `modules/nixos/system/secrets.nix`; `home.activation.opencodeAuth` in `home/h82/agents/opencode.nix`.
- **Test scenarios:** Covered by U3's activation and service checks.
- **Verification:** `nix eval` of a darwin production output shows `ompAuth` after `nixConfigSecretsPublish`; a darwin bootstrap output has no `ompAuth`.

### U3. Extend checks and docs

- **Goal:** Repository checks catch a missing, misordered, or key-leaking omp import, and docs list the new consumer.
- **Requirements:** R1, R3, R7; AE1, AE5.
- **Dependencies:** U2.
- **Files:** `tests/omp.nix`, `tests/darwin-checks.nix` (if its `entries` need `bootstrap`), `tests/agent-api-key-secrets.nix` or a NixOS-side assertion beside it, `docs/macos.md`, `secrets/README.md`.
- **Approach:** In `tests/omp.nix`, for each darwin entry: production has `ompAuth` running after `nixConfigSecretsPublish`, executes it against a recording stub (as `tests/opencode.nix` does) and checks it passes the six `PROVIDER=<keyDirectory>/<file>` pairs; bootstrap has no `ompAuth`. On NixOS, assert `sops-install-secrets`' `ExecStartPost` runs `omp-auth-sync` with the enabled providers and drops a provider whose option is forced off. Update the published-credentials lists in `docs/macos.md` and the consumer column in `secrets/README.md`.
- **Test scenarios:**
  - Darwin production: `ompAuth` present, ordered, passes all six pairs, does nothing on `DRY_RUN`, fails when the helper fails.
  - Darwin bootstrap: no `ompAuth` (AE5).
  - NixOS production: `ExecStartPost` includes the omp command; with `enableExaApiKey` forced off, `exa` is absent from it. `auth-provisioning` (no Home Manager, `ompPackage` unset) still evaluates with no omp command.
  - No key text appears in any activation block or unit command.
- **Verification:** `./scripts/agent-check` passes.

---

## Verification Contract

| Command | Proves | Units |
| --- | --- | --- |
| `nix build .#checks.x86_64-linux.omp-auth-sync` (CI-verified) | helper behavior and secret hygiene | U1 |
| `nix build .#checks.aarch64-darwin.omp` | darwin activation wiring and bootstrap exclusion | U2, U3 |
| `./scripts/agent-check` (via `nix develop .#agent-check -c`) | repository checks, formatting, and the NixOS evaluation it covers | U1–U3 |

Linux-only checks that the macOS host cannot build are recorded as CI-verified, not claimed locally. Host switches stay with the owner.

## Definition of Done

- U1–U3 verification passes.
- No key text in the repository, the Nix store, argv, or logs (R7).
- Docs list omp as a consumer of the six keys.
- No abandoned helper variants or dead wiring remain in the diff.
