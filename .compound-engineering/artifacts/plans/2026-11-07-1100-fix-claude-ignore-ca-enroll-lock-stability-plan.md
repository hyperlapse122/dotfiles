---
title: Ignore .claude, enroll the Netwrix CA, and stabilize mise.lock across OSes - Plan
date: 2026-11-07
type: fix
topic: claude-ignore-ca-enroll-lock-stability
execution: code
artifact_contract: ce-unified-plan/v1
product_contract_source: ce-plan-bootstrap
---

# Ignore .claude, enroll the Netwrix CA, and stabilize mise.lock across OSes - Plan

## Goal Capsule

- **Objective:** Three small repository changes in one PR: ignore the project-local `.claude/` directory, add the user's extra CA certificate to the repository-managed encrypted CA inventory, and stop `mise.lock` from changing when `mise install` runs on macOS versus Windows.
- **Product authority:** The user's LFG request; `AGENTS.md`; `docs/guides/system-ca.md`.
- **Open blockers:** None.
- **Means:** Reuse the existing `scripts/ca-files.py import` enrollment path (KTD2); pin the lockfile platform set with `lockfile_platforms` and regenerate once (KTD3); add a CI drift check (KTD4).
- **Execution profile:** One PR; LFG owns implementation, verification, review, and publication. Applying personal configuration (`mise run apply`) stays with the user.

---

## Product Contract

### Summary

1. `.claude/` is untracked noise in every worktree; ignore it at the repository root.
2. The certificate at `/Users/hyperlapse/Downloads/cacert.pem` (one self-signed CA, `O=Netwrix Corporation, OU=EndPointProtector CA, CN=172.30.60.23`, `CA:TRUE`, valid until 2036-10-14) must be stored encrypted in the repository and become part of the repository-managed CA chain.
3. `mise.lock` must stay byte-identical after `mise install` on macOS and on Windows.

### Problem Frame

- The repository already owns an opt-in CA-file fallback: `scripts/ca-files.py import --id <id> --pem-file <path>` validates CA-only PEM input, encrypts it to the repository GPG recipient into `home/.secrets/ca-certificates.json.asc`, and decrypt-verifies the result. On apply, `run_after_35-ca-files.sh.tmpl` builds `~/.local/share/dotfiles/ca/bundle.pem` from the pinned certifi roots plus enrolled CAs (macOS/Linux only). The inventory file does not exist yet, so this is the first enrollment.
- `mise.toml` sets `lockfile = true` and leaves `lockfile_platforms` unset. Per mise 2026.11.2 docs, with the setting unset, automatic locking during `mise install` keeps the recorded platforms **and adds the current platform**, and `lockfile_mode = "generate"` rebuilds the whole lockfile and locks other platforms during installs. Per-tool platform coverage in the committed lock is uneven (podman lacks `linux-*-musl`; cmake/ninja gained `macos-x64` only after a later run; usage `windows-x64` was dropped then re-added), so each host fills in a different subset. History shows the flips: `0a7f8d7` (cmake/ninja `macos-x64` added, usage `windows-x64` removed, `[[tools.rust]]` blocks reordered), `89e7d86` / `f17b147` (`windows-arm64` added), and the current uncommitted podman `linux-*-musl` additions.
- The `[[tools.rust]]` blocks come from task-scoped tool requests (`macos-build:rust`, `pinentry:*`, `windows-build:rust`). Their order differed between a Windows-generated and a macOS-generated lock (`0a7f8d7`). The macOS order matches alphabetical task-name order; the Windows order put the Windows-filtered request first.

### Key Decisions

- KD1 (user-directed): the CA is stored encrypted, never as plaintext PEM in Git. Rejected alternative: committing the PEM. Reason: the user asked for encryption.

### Requirements

- R1. `.gitignore` ignores `.claude/` at the repository root.
- R2. The CA is enrolled in `home/.secrets/ca-certificates.json.asc` via the existing importer; no plaintext copy of the PEM enters the repository or the scratch area inside it.
- R3. After enrollment, rendering/apply on macOS and Linux includes the CA in the managed bundle (existing behavior keyed on the inventory's presence).
- R4. `mise.toml` declares a fixed `lockfile_platforms` set covering every platform the repository supports.
- R5. The committed `mise.lock` is regenerated against that set, so every URL-locked tool carries an entry for each platform it supports.
- R6. CI fails when `mise install` on any matrix OS leaves `mise.lock` (or `.mise/locks/`) modified.

### Scope Boundaries

- No change to Windows trust behavior: the CA-file fallback is macOS/Linux only by design (`docs/guides/system-ca.md`); Windows relies on the OS root store. Installing the CA into OS trust stores is out of scope.
- No `SSL_CERT_FILE` or similar global export (see `.compound-engineering/artifacts/solutions/integration-issues/github-cli-windows-ca-override.md`).
- Do not run `mise run apply` from the run; the user applies personal configuration explicitly.

### Dependencies and Assumptions

- The importer needs the repository GPG recipient key and a working decryption path (pinentry/card) for its decrypt-verify step. If decryption is unavailable in the session, the run must stop at U2 rather than commit an unverified ciphertext.
- Windows verification of lock stability comes from the CI matrix (U4) unless a Windows host is directly reachable.

### Outstanding Questions

- None blocking. Whether the `[[tools.rust]]` order still flips under mise 2026.11.2 is answered by U4's Windows CI run; see KTD5.

### Sources / Research

- `scripts/ca-files.py`, `tests/test_ca_files.py`, `docs/guides/system-ca.md`, `home/.chezmoiignore:22`, `home/.chezmoiscripts/run_after_35-ca-files.sh.tmpl`.
- mise settings reference (`lockfile_platforms`, `lockfile_mode`, `lockfile_auto_prune`), <https://mise.jdx.dev/configuration/settings.html>; <https://mise.jdx.dev/dev-tools/mise-lock.html>.
- `.compound-engineering/artifacts/solutions/integration-issues/mise-lock-conflict-command-context.md` (commands can activate mise and rewrite the lock incidentally; inspect unstaged lock changes after each command).
- `.github/workflows/test.yml` (multi-OS matrix that already runs `mise install` per tool).

---

## Planning Contract

### Key Technical Decisions

- KTD1. Ignore with a root-anchored `/.claude/` entry, matching the existing anchored style (`/target/`). `home/.chezmoiignore` already ignores `.claude` in the source state, so no chezmoi change is needed.
- KTD2. Enroll with the existing importer and a descriptive ID, `netwrix-endpoint-protector`: `mise exec -- python scripts/ca-files.py import --id netwrix-endpoint-protector --pem-file /Users/hyperlapse/Downloads/cacert.pem`. The importer owns validation, encryption, and decrypt-verify; do not hand-roll GPG calls. The input file stays where it is.
- KTD3. Set `[settings] lockfile_platforms` to the eight platforms mise uses by default plus `windows-arm64` already present in the lock: `linux-x64`, `linux-x64-musl`, `linux-arm64`, `linux-arm64-musl`, `macos-x64`, `macos-arm64`, `windows-x64`, `windows-arm64`. Every host then resolves the same set, and the "current platform is always added" rule never introduces a new one. Then run `mise lock` once so every tool is filled for that set. Tools whose upstream has no asset for a platform (podman `macos-x64`, cmake/ninja outside macOS because of their `os` filter) simply stay absent on every host.
- KTD4. Add a CI step after the existing `mise install` steps on each OS that runs `git diff --exit-code -- mise.lock .mise/locks` and fails with a message pointing at `mise lock`. This is the regression guard for R6 and the Windows proof for this PR.
- KTD5. Rust block order: if the Windows CI drift check shows only a reordering of `[[tools.rust]]`, the fallback is to make the task-scoped requests resolve in a host-independent order. Candidates, in preference order: (a) confirm whether mise 2026.11.2 already sorts these deterministically (no change); (b) declare the three rust requests in one consistent place so request order no longer depends on OS filtering; (c) report upstream and pin `min_version` once fixed. Choose based on the CI evidence; do not speculate in code before it.
- KTD6. Accept the current uncommitted podman `linux-*-musl` diff as part of the regenerated lock; it is exactly the coverage KTD3 asks for.

### Boundaries and Risks

- Risk: the GPG decrypt-verify step needs the user's card/pinentry. Mitigation: if it fails, stop and report; never commit an inventory the importer did not verify.
- Risk: commands in this repo can activate mise and rewrite the lock incidentally (documented learning). Mitigation: run `git status --short` after each mise command and commit only intended lock changes.
- Risk: `mise lock` may bump `latest` tools. It does not without `--bump`; confirm versions in the diff are unchanged.

### Implementation Discovery

- `lockfile_platforms` is a `string[]` in `[settings]`; `MISE_LOCKFILE_PLATFORMS` overrides it.
- `lockfile_auto_prune = true` only removes tools absent from config; it does not explain platform churn.

## Implementation Units

### U1. Ignore `.claude/`

- **Files:** `.gitignore`.
- **Change:** Add `/.claude/`.
- **Verify:** `git status --short` no longer lists `.claude/`; `git check-ignore -v .claude` reports the new rule.

### U2. Enroll the Netwrix CA

- **Files:** `home/.secrets/ca-certificates.json.asc` (new, produced by the importer).
- **Change:** Run the KTD2 command.
- **Verify:** the importer prints `Encrypted CA enrollment verified; input retained.`; the new file is ASCII-armored PGP and contains no `BEGIN CERTIFICATE`; `python -m unittest tests.test_ca_files` passes; `chezmoi --source . managed` (with the repo's bootstrap config, scripts excluded) now lists the CA-file targets on macOS because `home/.chezmoiignore` keys on the inventory's presence.

### U3. Pin lockfile platforms and regenerate

- **Files:** `mise.toml`, `mise.lock` (and `.mise/locks/` only if mise changes it intentionally).
- **Change:** Add `lockfile_platforms` (KTD3), run `mise lock`, review the diff: only new platform entries, no version changes.
- **Verify:** a second `mise lock` and a `mise install` on macOS leave `mise.lock` unchanged (`git diff --exit-code`).

### U4. CI drift guard

- **Files:** `.github/workflows/test.yml`.
- **Change:** After the mise install steps in each OS job, add the KTD4 check.
- **Verify:** the PR's macOS, Linux, and Windows jobs pass the check. If Windows fails only on rust ordering, apply KTD5 and re-run.

## Verification Contract

- U1–U3 local checks above on macOS.
- `python -m unittest discover -s tests -p 'test_ca_files.py'` and `tests/test_bootstrap.py` pass.
- PR CI green on every OS, including the new drift check (Windows proof for R6).

## Definition of Done

- `.claude/` ignored; CA enrolled encrypted and verified by the importer; `mise.toml` pins `lockfile_platforms`; regenerated `mise.lock` committed; CI drift check passes on all OSes; no plaintext certificate and no personal apply performed.
