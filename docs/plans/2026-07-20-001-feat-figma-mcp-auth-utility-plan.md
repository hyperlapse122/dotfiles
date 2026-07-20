---
title: Figma MCP Auth Utility - Plan
type: feat
date: 2026-07-20
topic: figma-mcp-auth-utility
artifact_contract: ce-unified-plan/v1
artifact_readiness: implementation-ready
product_contract_source: ce-brainstorm
execution: code
---

# Figma MCP Auth Utility - Plan

## Goal Capsule

- **Objective:** A `figma-auth <opencode|pi>` user-scoped CLI that completes the Figma MCP OAuth flow (Authorization Code + PKCE + Dynamic Client Registration) and persists the credentials in each harness's native format, so both opencode and pi authenticate against `https://mcp.figma.com/mcp` from one managed utility.
- **Authority:** the user's spec governs the CLI shape, the two targets, and the exact storage paths; the two upstream storage schemas are dictated by `gberaudo/opencode-mcp-figma` (camelCase `mcp-auth.json`) and `irahardianto/pi-mcp-extension` (snake_case per-server hashed file); the `dot_agents/readonly_AGENTS.md` "MUST use the `figma` MCP" rule establishes the need this utility ultimately serves.
- **Execution profile:** a JS/TS utility built on `chezmoi apply` like mxm4-haptic and invoked on demand for the interactive browser flow.
- **Stop conditions:** stop and surface if Figma's DCR cannot register a fresh client per invocation, or if a non-JS reimplementation of the OAuth flow becomes necessary.
- **Tail ownership:** not a pipeline run — hands off to planning; deploy and the live authorization are a manual step the user runs.

## Product Contract

**Product Contract unchanged.**

### Summary

A standalone `figma-auth <opencode|pi>` CLI that runs the Figma MCP OAuth flow and writes the result in each harness's native schema — merging into opencode's `~/.local/share/opencode/mcp-auth.json` or writing pi's `~/.pi/agent/mcp-auth/<sha256("figma")[0:16]>.json`. Built on apply like mxm4-haptic but invoked on demand, because the flow needs an interactive browser.

### Problem Frame

The shared agent instructions mandate the `figma` MCP for any Figma URL, but Figma's MCP rejects non-whitelisted agents and requires OAuth2 with PKCE and Dynamic Client Registration. The only existing path is `gberaudo/opencode-mcp-figma` — a clone-and-run `npm start` that writes opencode's `mcp-auth.json` and nothing else. pi has `irahardianto/pi-mcp-extension`'s OAuth provider with the per-server hashed storage shape, but no standalone entry point a user can invoke. So neither harness has a single, repeatable, managed `figma-auth`, and the two target files use incompatible schemas: opencode stores camelCase keys with an absolute `expiresAt` timestamp; pi stores snake_case keys with relative `expires_in` plus a `saved_at` stamp. The utility exists to give both harnesses one auth command that writes the right shape per target — and to replace the ad-hoc clone-and-run with a managed binary on PATH.

### Requirements

**CLI interface**

- R1. The CLI is invoked as `figma-auth <opencode|pi>`; the single positional arg selects the target harness and its storage format.
- R2. An unknown or missing arg exits non-zero with a usage message naming the two valid values and writes no file.

**OAuth flow**

- R3. Each invocation runs a complete Figma OAuth2 Authorization Code + PKCE + Dynamic Client Registration flow against `https://mcp.figma.com/mcp`, registering a fresh client for that invocation.
- R4. The flow opens the user's browser for authorization and serves a local callback to receive the authorization code, then completes the token exchange.

**Storage**

- R5. For `opencode`, the result is merged into `~/.local/share/opencode/mcp-auth.json` under the hostname-derived `figma` key, preserving any other servers' entries and the sibling state key already present.
- R6. For `pi`, the result is written to `~/.pi/agent/mcp-auth/<sha256("figma").digest("hex").slice(0,16)>.json` in pi's per-server schema.

**Build & integration**

- R7. The utility is built on `chezmoi apply` like mxm4-haptic and lands a `figma-auth` binary on `~/.local/bin` (already on PATH); it is invoked by the user on demand, not run during apply.
- R8. No client credentials are hardcoded; the registered client and the resulting tokens live only in the per-user target files and never in the repo or chezmoi source.

### Key Decisions

- **Per-invocation fresh OAuth per target.** (session-settled: user-directed — over a single shared auth written to both: each harness is authenticated separately, which matches both upstream implementations and avoids cross-client token sharing; the cost is one browser authorization per harness.) Each `figma-auth <target>` run does its own DCR registration and token exchange.
- **Auth-only; MCP server wiring is deferred.** (session-settled: user-directed — over including the figma server entry: the user will add `figma` to `agents.yaml` `mcp.servers` in a separate change; this utility produces only the auth files.)
- **Token refresh is the harness's job, not the utility's.** (session-settled: user-approved — each agent's MCP client refreshes at runtime using the stored refresh_token; `figma-auth` is initial-auth-only and is re-invoked only when a refresh has failed and a fresh authorization is needed.)
- **One OAuth core, two storage adapters.** The PKCE + DCR flow is identical for both targets (both reuse `@modelcontextprotocol/sdk`); the only per-target code is the storage write. The two schemas differ in more than casing, which is why a shared write would corrupt one target:

  | | opencode `mcp-auth.json` | pi per-server file |
  |---|---|---|
  | key casing | camelCase (`accessToken`, `expiresAt`) | snake_case (`access_token`, `expires_in`) |
  | expiry | absolute Unix timestamp (`expiresAt`) | relative seconds + `saved_at` ISO stamp |
  | shape | merged under hostname key `figma`, sibling `Figma` state key | standalone file at `mcp-auth/<sha256[0:16]>.json` |

- **Built on apply, run on demand.** Unlike mxm4-haptic, which apply also starts and enables, this utility cannot run during apply (the OAuth flow needs an interactive browser), so apply only compiles and installs the binary; the user runs it.

### Acceptance Examples

- AE1. **Covers R1, R2.** `figma-auth` with no arg or an unknown arg prints usage naming `opencode` and `pi` and exits non-zero without creating or modifying any file.
- AE2. **Covers R3–R5.** `figma-auth opencode` opens a browser, completes the Figma flow, and the `figma` entry in `~/.local/share/opencode/mcp-auth.json` holds new client info and tokens in opencode's camelCase schema; any pre-existing non-figma entries are byte-identical.
- AE3. **Covers R3, R4, R6.** `figma-auth pi` opens a browser, completes the Figma flow, and writes `~/.pi/agent/mcp-auth/<sha256("figma")[0:16]>.json` in pi's snake_case schema with client info, tokens, and verifier.
- AE4. **Covers R5.** Re-running `figma-auth opencode` overwrites only the `figma` entry (and its sibling state key), leaving other servers' entries intact.

### Scope Boundaries

**In scope:** the `figma-auth` CLI, its two storage adapters, and the chezmoi build integration.

**Out of scope:**

- Adding `figma` to `agents.yaml` `mcp.servers` (deferred — a separate change by the user).
- Token refresh or background re-auth (handled by each harness's MCP client at runtime).
- Running the auth flow during `chezmoi apply` (interactive; apply only builds the binary).
- Pre-registered or static client credentials (Figma supports DCR).

### Dependencies / Assumptions

- `@modelcontextprotocol/sdk` provides the OAuth client primitives both upstream repos already use; the utility reuses rather than reimplements PKCE/DCR.
- Figma's MCP permits a fresh DCR registration per invocation — the manual `opencode-mcp-figma` run that already produced a working `~/.local/share/opencode/mcp-auth.json` is the evidence.
- The build toolchain (mise-managed `bun`) is present, matching the other `60-build/` scripts.
- The two upstream storage schemas are stable as observed; an upstream schema change would require an adapter update.

### Outstanding Questions

**Deferred to planning:**

- Packaging form: a Bun-compiled standalone binary (a new `packages/figma-auth` workspace member) vs a node script resolving deps from a managed location. Planning decides, weighing the mxm4-haptic "single binary on PATH" model against the `packages/` build pattern.
- Callback port: opencode-mcp-figma uses 3000, pi-mcp-extension uses 19876; any free port works because DCR registers the redirect URI, but planning picks one (and whether to make it configurable).
- Callback server dependency: `express` (opencode-mcp-figma) vs dependency-free `node:http` (pi-mcp-extension).

### Sources / Research

- `~/src/github.com/gberaudo/opencode-mcp-figma` — the proven OAuth flow (`src/index.ts`, `src/oauth-provider.ts`) and the opencode camelCase storage adapter (`src/storage.ts`, key derived from hostname → `figma`).
- `irahardianto/pi-mcp-extension` `src/oauth-provider.ts` — pi's per-server storage schema and the `sha256(serverName)[0:16]` path convention.
- `~/.local/share/opencode/mcp-auth.json` — live evidence of the opencode schema (camelCase, absolute `expiresAt`).
- `crates/mxm4-haptic` + `.chezmoiscripts/60-build/run_onchange_after_build-mxm4-haptic.sh.tmpl` — the user-scoped-binary-on-PATH build pattern.
- `packages/` Bun workspace + `.chezmoiscripts/60-build/run_onchange_after_build-opencode-plugins.sh.tmpl` — the JS build-on-apply pattern.
- `dot_agents/readonly_AGENTS.md` "Figma" section — the global mandate this utility ultimately serves.

## Planning Contract

### Key Technical Decisions

- **KTD1 — Workspace/package shape.** Create the auto-discovered `packages/figma-auth` workspace member as a private ESM package that builds a standalone executable with `bun build --compile`; it is a CLI, not an OpenCode plugin. This follows the existing workspace conventions while producing the single binary required by R7.
- **KTD2 — Exact dependencies and hardening.** Pin runtime dependencies exactly to `@modelcontextprotocol/sdk` `1.29.0` and `jsonc-parser` `3.3.1`; reuse the workspace's exact `@types/node` `24.13.2`, TypeScript `7.0.2`, and `vite-plus: "catalog:"` whose catalog pins `0.2.3`. `jsonc-parser` exists only for surgical OpenCode document edits that satisfy AE2's byte-preservation requirement, not for the callback server. Keep `packages/bunfig.toml` unchanged so ignored lifecycle scripts, exact installs, the one-week cooldown, and the hoisted linker remain enforced. Update `packages/bun.lock` only through Vite+/Bun, never by hand.
- **KTD3 — Installed form.** Compile to `packages/figma-auth/dist/figma-auth`, then atomically install a regular executable at `~/.local/bin/figma-auth`. Never create a link under `~/.config/opencode/plugins/` or add this utility to the plugin-link list; it is an on-demand user CLI, not a loadable plugin.
- **KTD4 — Callback implementation and port.** Use only `node:http`, bind IPv4 loopback `127.0.0.1`, and register exactly `http://127.0.0.1:19876/callback`. Fixed port `19876` matches pi-mcp-extension's established OAuth default and avoids commonly occupied development port 3000. Do not scan, fall back, or make the port configurable: an occupied port fails before browser launch or credential writes.
- **KTD5 — One fresh OAuth core.** Fix the resource at `https://mcp.figma.com/mcp` and use the MCP SDK for protected-resource discovery, DCR, Authorization Code + PKCE, token exchange, and authenticated reconnect. Begin every invocation with no client or tokens; keep the fresh client, verifier, state, discovery result, and tokens only in memory so existing target credentials are never loaded and every target run performs fresh DCR.
- **KTD6 — Browser/callback safety.** Start the listener before initiating authorization, generate one cryptographically random state, and require an exact state match. Handle provider errors, missing code, unrelated paths, a five-minute timeout, process signals, and guaranteed server/client cleanup. Use `xdg-open` on Linux and `open` on macOS without an opener dependency; print the authorization URL and fail clearly when the platform opener cannot launch.
- **KTD7 — One adapter boundary and commit point.** Define one normalized completed-session payload with two target adapters. MCP provider save methods update only in-memory session state. Commit exactly once through the selected adapter only after `finishAuth` and a fresh authenticated MCP reconnect succeed; cancellation or any error leaves old credentials unchanged.
- **KTD8 — Atomic/private persistence.** Reject symlink and non-regular destinations and malformed existing JSON. Create sensitive temporary files in the destination directory at mode `0600`, fsync and close them, then rename atomically; final files remain `0600`. Create pi's `mcp-auth` directory as `0700`, but do not chmod unrelated OpenCode parent state directories.
- **KTD9 — OpenCode adapter.** Derive `figma` from the fixed server hostname and `Figma` as its state sibling. Map client information and tokens to the upstream camelCase schema, calculate absolute `expiresAt`, and update only those two top-level members. Apply `jsonc-parser` edits to the original source text so unrelated top-level entries retain their original bytes, ordering, and formatting. Reject invalid, non-object, or ambiguous duplicate-key input rather than resetting it to `{}`.
- **KTD10 — pi adapter.** Write `~/.pi/agent/mcp-auth/<sha256("figma").slice(0,16)>.json` using the observed pi v1.5.0 envelope (`clientInfo`, `tokens`, `codeVerifier`, and optional `discoveryState`) with snake_case nested OAuth fields. Preserve relative `expires_in` and add one injected `saved_at` ISO timestamp. Replacing this one figma-specific file is intentional.
- **KTD11 — Targeted apply integration.** Add a separate Linux/macOS `.chezmoiscripts/60-build/run_onchange_after_build-figma-auth.sh.tmpl` that fingerprints only relevant root/workspace manifests, lock/config, and `packages/figma-auth` inputs; runs frozen dependency installation and the package's `bun build --compile` task through mise; and atomically installs the binary. It may soft-skip consistently with existing build scripts, with the standard onchange caveat that a skipped run retries only after content changes or `chezmoi apply --force`. It must never run OAuth during apply.

### Assumptions and settled-decision check

- **No settled-decision conflict.** Per-target fresh OAuth, auth-only scope, harness-owned token refresh, one shared core with two native adapters, and build-on-apply/run-on-demand remain unchanged.
- The researched pi nuance is that its envelope keys are camelCase while nested OAuth fields are snake_case. This refines implementation of the existing "pi native schema" decision and does not alter that decision.
- The deferred packaging, callback port, and callback dependency questions remain verbatim in the Product Contract and are resolved by KTD1–KTD4: an auto-discovered workspace package, compiled standalone binary, dependency-free `node:http` callback, and fixed port `19876`.
- Figma must continue permitting fresh DCR per invocation, and SDK `1.29.0` must remain compatible with Bun compilation. Direct contrary implementation evidence requires surfacing a planning-contract change rather than silently changing a pin or flow.
- Live browser authorization remains the Product Contract's manual tail, not automated verification.

## Implementation Units

### U1 — Workspace member, CLI, callback, and OAuth core

**Goal:** Deliver the strict CLI entry point and one fresh, in-memory OAuth core through the authenticated reconnect boundary, without writing credentials directly.

**Requirements:** R1–R4 and the OAuth/CLI portions of R7–R8; KTD1–KTD7. The build command must be the literal `bun build --compile ./src/index.ts --outfile ./dist/figma-auth`. Vite+ tasks expose workspace `build`, `typecheck`, and `test` consistently with representative members.

**Dependencies:** KTD1–KTD7; exact dependencies from KTD2; no prior implementation unit.

**Files:**

- `packages/figma-auth/package.json`
- `packages/figma-auth/tsconfig.json`
- `packages/figma-auth/vite.config.ts`
- `packages/figma-auth/src/index.ts`
- `packages/figma-auth/src/cli.ts`
- `packages/figma-auth/src/oauth.ts`
- `packages/figma-auth/src/oauth-provider.ts`
- `packages/figma-auth/src/callback-server.ts`
- `packages/figma-auth/src/browser.ts`
- `packages/figma-auth/src/storage/types.ts`
- `packages/figma-auth/test/cli.test.ts`
- `packages/figma-auth/test/oauth.test.ts`
- `packages/figma-auth/test/callback-server.test.ts`
- `packages/bun.lock`

**Approach:** Parse exactly one positional `opencode|pi` argument before any I/O. Inject the target adapter, clock, browser opener, callback timeout/listener, and MCP client/transport so tests remain local and deterministic. Keep provider client data, tokens, verifier, state, and discovery state in memory to force fresh DCR. Execute unauthorized response → callback → `finishAuth` → new transport/client authenticated reconnect → one adapter commit. Start callback listening before browser launch, and close server/client resources in `finally` and signal handlers.

**Patterns to follow:** The researched `opencode-mcp-figma/src/index.ts` transport retry and `oauth-provider.ts` SDK interface; pi's `node:http` callback and state-validation approach; representative `packages/*/{package.json,tsconfig.json,vite.config.ts,test}` conventions.

**Test scenarios:**

1. Missing, unknown, and extra arguments print usage naming `opencode` and `pi`, exit non-zero, and perform no writes.
2. Production constants expose the fixed Figma resource, redirect URI, callback timeout, and expected client metadata.
3. A fresh provider never loads old credentials and begins without client information or tokens.
4. State mismatch, missing state, provider error, missing code, unrelated callback path (404), timeout, and port-in-use each fail safely.
5. Port-in-use fails before browser launch and before any adapter call.
6. A successful mocked SDK sequence performs discovery/DCR/PKCE, finishes auth, creates a new transport/client, proves authenticated reconnect, and commits exactly once afterward.
7. Every failure leg, including reconnect failure, commits zero times.
8. Linux selects `xdg-open`, macOS selects `open`, and opener failure prints the URL and exits clearly.
9. Success, error, timeout, and signal paths clean up callback server, MCP transport, and client resources.

**Verification:** Run focused U1 tests, package typecheck, and package build; execute the compiled CLI usage smoke under an isolated scratch `HOME` to prove argument rejection starts no OAuth and writes nothing.

### U2 — Atomic writer and OpenCode adapter

**Goal:** Persist a completed session into OpenCode's shared auth document without changing unrelated bytes or weakening private-file safety.

**Requirements:** R5 and R8; AE2 and AE4; KTD7–KTD9. Only `figma` and `Figma` may change at the single post-reconnect commit point.

**Dependencies:** U1 normalized completed-session payload and adapter boundary.

**Files:**

- `packages/figma-auth/src/storage/atomic.ts`
- `packages/figma-auth/src/storage/opencode.ts`
- `packages/figma-auth/test/atomic-write.test.ts`
- `packages/figma-auth/test/opencode-storage.test.ts`

**Approach:** Implement a reusable same-directory atomic private writer, then use `jsonc-parser` against the original OpenCode source text to replace only the hostname-derived auth entry and sibling state entry. Validate file type, JSON object shape, and duplicate target keys before constructing any temporary replacement; derive absolute expiry with an injected clock.

**Patterns to follow:** Upstream `storage.ts` for schema and hostname/state-key derivation, while explicitly rejecting its destructive parse-error-to-empty fallback and direct `writeFileSync` behavior.

**Test scenarios:**

1. A missing auth file is created with the required object and private mode.
2. All upstream client/token fields, including optional client fields, map exactly; relative expiry becomes absolute `expiresAt` using the injected clock.
3. Only `figma` and `Figma` are replaced in an existing document.
4. Raw-byte sentinels around unrelated entries remain identical, including ordering and formatting.
5. Malformed JSON, non-object roots, duplicate target keys, symlinks, and non-regular targets fail with original bytes untouched.
6. A failed write leaves no sensitive temporary file behind.
7. The final file mode is `0600` after both creation and replacement.
8. Re-running auth replaces only the two target entries and preserves all other bytes.

**Verification:** Run the focused atomic/OpenCode tests with injected paths and clock, then include them in workspace typecheck/test/check gates; inspect fixtures to confirm they contain fake data only.

### U3 — pi storage adapter

**Goal:** Persist the normalized session in pi-mcp-extension v1.5.0's per-server native file shape with atomic/private handling.

**Requirements:** R6 and R8; AE3; KTD7, KTD8, and KTD10.

**Dependencies:** U1 normalized payload and U2 atomic helper.

**Files:**

- `packages/figma-auth/src/storage/pi.ts`
- `packages/figma-auth/test/pi-storage.test.ts`

**Approach:** Hash the literal server name `figma` to select only its per-server file. Map the normalized session into the camelCase envelope and snake_case nested OAuth objects, omit undefined values, preserve relative expiry, and inject one stable `saved_at`. Ensure the directory and destination satisfy KTD8 before atomically replacing only this file.

**Patterns to follow:** Locally installed `pi-mcp-extension/src/oauth-provider.ts` v1.5.0 storage contract (`clientInfo`, `tokens`, `codeVerifier`, `discoveryState`) and hash convention, tightened with KTD8 atomic/private handling.

**Test scenarios:**

1. Literal `figma` produces the deterministic SHA-256 first-16-hex filename.
2. Output has the exact camelCase envelope and snake_case nested v1.5.0 shape.
3. Undefined optional fields are omitted.
4. `expires_in` remains relative, `saved_at` is injected exactly once, and `discoveryState` is included when captured.
5. An existing figma-specific file is replaced atomically while every other file remains untouched.
6. The `mcp-auth` directory is `0700` and the credential file is `0600`.
7. Malformed, symlink, and non-regular targets fail without mutation.

**Verification:** Run focused pi adapter tests using only scratch homes, fake OAuth data, and an injected clock; include the package in workspace typecheck/test/check gates.

### U4 — Targeted chezmoi build/install integration and documentation sync

**Goal:** Build on apply, install the regular CLI atomically, and document the new workspace output without ever running interactive auth during apply.

**Requirements:** R7–R8; KTD2, KTD3, KTD8, and KTD11. Preserve package-manager hardening and the last known good installed executable on transient build failure.

**Dependencies:** U1–U3 green.

**Files:**

- `.chezmoiscripts/60-build/run_onchange_after_build-figma-auth.sh.tmpl`
- `packages/README.md`
- `README.md`
- `AGENTS.md`

**Approach:** Gate the template to Linux/darwin and establish `$sourceDir`. Feed `fingerprint.tmpl` only `mise.toml`, `packages/package.json`, `packages/bun.lock`, `packages/bunfig.toml`, `packages/vite.config.ts`, and `packages/figma-auth/{package.json,tsconfig.json,vite.config.ts,src/**}`. Run `mise -C "$SRC/packages" exec -- vp install --frozen-lockfile`, then the targeted Bun compile task. Install through a same-directory temporary file created `0600`, promote it to `0755`, and rename it into `~/.local/bin/figma-auth`. Missing mise or install/build failure soft-skips without replacing a last known good binary, matching mxm4-haptic behavior and carrying the standard onchange retry caveat. Never invoke OAuth and never touch the OpenCode plugin directory. Document manual rebuild and `chezmoi apply --force` retry semantics.

**Patterns to follow:** `.chezmoiscripts/60-build/run_onchange_after_build-mxm4-haptic.sh.tmpl` for user-bin installation and soft failure; `.chezmoiscripts/60-build/run_onchange_after_build-opencode-plugins.sh.tmpl` for mise, frozen workspace installation, targeted fingerprints, and container-compatible CLI build behavior. Update both documentation summaries because `packages/` will no longer produce only OpenCode plugins/libraries.

**Test scenarios:**

1. Linux and darwin render a non-empty build script; unsupported operating systems render it empty.
2. The fingerprint changes for source, manifest, or lock edits but excludes `dist` and `node_modules`.
3. Missing mise, frozen-install failure, and build failure soft-skip without replacing a good installed binary.
4. A successful build installs a regular executable at `~/.local/bin/figma-auth`, never a symlink.
5. Rendered script contains no auth invocation and no OpenCode plugin link operation.
6. Documentation identifies build-on-apply/run-on-demand behavior, both targets, private native storage, and manual retry semantics.

**Verification:** Render the script with the repository's stub-`op` and throwaway-destination recipe, run `bash -n` and ShellCheck on the rendered output, compare the rendered script against merge-base, and run the source hygiene and archive gates below.

## Verification Contract

| Gate | Command/check | Proves |
|---|---|---|
| Workspace dependency integrity | From `packages/`, run `vp install --frozen-lockfile`. | The generated `packages/bun.lock` agrees with exact manifests without weakening package-manager policy. |
| Workspace gates | From `packages/`, run `vp run -r build`, `vp run -r typecheck`, `vp run -r test`, and `vp check`, matching `.github/workflows/ci.yml`. | All workspace members build, typecheck, test, and satisfy repository checks. |
| Focused no-credential tests | Run `vp test` for `packages/figma-auth` fixtures only, with injected home paths, clock, browser, callback, and fake OAuth data under `$XDG_RUNTIME_DIR` or `~/.cache`. Use no Figma network, browser, or real tokens. | CLI/core/adapters cover success and failure deterministically without credentials or live services. |
| Compiled CLI usage smoke | Under an isolated scratch `HOME`, run `packages/figma-auth/dist/figma-auth` with no argument and with an invalid argument. Both must exit non-zero, print usage naming `opencode` and `pi`, and create no auth target. | The compiled artifact starts and validates input before OAuth or file I/O. |
| Rendered build script | Use the repository's exact dummy-`op`, empty config, explicit `--source "$PWD"`, and throwaway `--destination` recipe to `execute-template` `.chezmoiscripts/60-build/run_onchange_after_build-figma-auth.sh.tmpl`. Save output only in the per-user scratch tree, then run `bash -n` and ShellCheck on it; never use `/tmp`, `/var/tmp`, or `/dev/shm`. | The template renders in isolation and the actual rendered shell is syntactically and statically valid without touching the live home. |
| Archive/no-target-drift gate | Archive merge-base and branch with `--exclude=encrypted,externals,scripts`, extract both under per-user scratch, and run `LC_ALL=C diff -r`; expect no deployed target change because `packages/` and docs are source-only and the integration is a script. The archive cannot see `.chezmoiscripts/**`; rendered-script comparison covers that blind spot. | No unintended deployed file targets change, while the separately rendered script validates the archive's known blind spot. |
| Source hygiene | Run `git diff --check`; scan the new manifest for dependency ranges; scan the diff for secrets/tokens; run `git status --short` and confirm generated `dist`, `node_modules`, scratch files, and real auth JSON are not staged. | The change is clean, exact-pinned, secret-free, and contains no generated or local credential state. |

No real `chezmoi apply` is an automated verification step. No live Figma login is required for automated acceptance. Any later user-run authorization is the already-settled manual tail.

## Definition of Done

- All R1–R8 and AE1–AE4 are covered by passing unit/integration tests, including zero-write failure behavior and authenticated reconnect before commit.
- Runtime dependencies are pinned exactly to `@modelcontextprotocol/sdk` `1.29.0` and `jsonc-parser` `3.3.1`; workspace tooling remains exact at `@types/node` `24.13.2`, TypeScript `7.0.2`, and catalog-pinned Vite+ `0.2.3`. `packages/bunfig.toml` remains unchanged, preserving ignored lifecycle scripts, exact installs, one-week cooldown, and the hoisted linker; `packages/bun.lock` is tool-generated only.
- Scope remains auth-only: no `agents.yaml` MCP server wiring, refresh implementation, background auth, static client, or shared cross-target credential is added.
- Source, fixtures, logs, build artifacts, and git contain no token, client secret, registered-client credential, real auth JSON, or other live secret.
- Credential writes are private and atomic: files are regular, non-symlink targets at `0600`; pi's auth directory is `0700`; cancellation and failures preserve existing credentials.
- Apply builds but does not authorize. The installed `~/.local/bin/figma-auth` is a regular compiled executable, not a symlink, and no OpenCode plugin link is created.
- `packages/README.md`, `README.md`, and `AGENTS.md` describe the utility, workspace output, build-on-apply/run-on-demand behavior, native target storage, and manual retry semantics.
- Automated verification uses neither a real `chezmoi apply` nor live Figma authorization; the user-run browser login remains the manual tail.
- Before the first implementation commit, run `git branch --show-current`; the branch must use a Git Flow `feature/` prefix and a 3–6 word slug, recommended `feature/add-figma-mcp-auth-utility`.
- Deliver one Conventional Commit/PR for this task, with a lowercase subject such as `feat(figma): add mcp auth utility`; do not split it into another MR.
- `.github/workflows/ci.yml` and `.github/workflows/render-dotfiles.yml` both reach terminal green on the PR. If the automated Codex reviewer shows an eyes reaction, wait for its terminal result: address requested changes or require the replacing thumbs-up before completion.
