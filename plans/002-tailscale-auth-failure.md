# Plan 002: Stop the tailscale bootstrap script from swallowing `tailscale up` failures

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row for this plan
> in `plans/README.md` — unless a reviewer dispatched you and told you they
> maintain the index.
>
> **Drift check (run first)**:
> `git diff --stat 7a12e58..HEAD -- .chezmoiscripts/auth/run_once_after_auth-tailscale.sh.tmpl`
> If the file changed since this plan was written, compare the "Current state"
> excerpt against the live code before proceeding; on a mismatch, treat it as a
> STOP condition.

## Status

- **Priority**: P1
- **Effort**: S
- **Risk**: LOW
- **Depends on**: none
- **Category**: bug
- **Planned at**: commit `7a12e58`, 2026-07-01

## Why this matters

`.chezmoiscripts/auth/run_once_after_auth-tailscale.sh.tmpl` is a **`run_once`**
provisioning script: chezmoi runs it exactly once per machine and records it as
done only when it exits `0`. Its last line runs `tailscale up …` but appends
`|| echo "Auth Failed"`, which converts any failure (expired/consumed auth key,
no network, daemon not ready) into a printed string and a **success** exit code.
The consequence: on a failed authentication chezmoi still marks the one-shot
step complete, so the machine never joins the tailnet **and never retries** —
the failure is invisible unless someone reads the apply log and notices the
words "Auth Failed". The fix makes the failure propagate (nonzero exit), so
chezmoi does not record the step as done and re-runs it on the next
`chezmoi apply`, which is exactly the retry behavior a one-shot bootstrap wants.

## Current state

- **File**: `.chezmoiscripts/auth/run_once_after_auth-tailscale.sh.tmpl` — a
  Go-templated bash script, 45 lines, run once during `chezmoi apply` on
  non-Windows hosts. It sets `set -euo pipefail` (line 4), resolves `sudo`
  vs root, enables `tailscaled` on Linux, then guards re-auth with a
  `tailscale status --json` check before calling `tailscale up`.

- **The bug is the final `else` branch (lines 41–43)**:

  ```bash
  else
    "${SUDO[@]}" "${TAILSCALE[@]}" up --operator "$USER" --accept-routes --accept-dns --accept-risk=all --auth-key={{- onepasswordRead "op://Private/Tailscale/Auth Key" | quote -}} || echo "Auth Failed"
  fi
  ```

  The `|| echo "Auth Failed"` makes the whole statement succeed (exit 0) even
  when `tailscale up` fails, defeating `set -e` and the one-shot retry.

- **Secret handling convention**: the auth key is injected at render time by
  chezmoi's `onepasswordRead` piped through `quote` — this is the repo's
  standard secret path (see `AGENTS.md` "Secrets"). **Keep the
  `{{- onepasswordRead "op://Private/Tailscale/Auth Key" | quote -}}` token
  exactly as-is.** Never print, expand, or inline the resolved value; the value
  must never appear in the script text, a log, or your report.

- **Idempotency is already handled** above the bug: lines 38–40 skip `up`
  entirely when `tailscale status --json` reports an already-authenticated
  backend state (`Running|Starting|Stopped|NeedsMachineAuth`). So re-running the
  script after a successful join is a safe no-op — making `up` failures fatal
  will not cause redundant re-auth on healthy machines.

## Commands you will need

| Purpose | Command | Expected on success |
|---|---|---|
| Locate/confirm | `grep -n 'Auth Failed' .chezmoiscripts/auth/run_once_after_auth-tailscale.sh.tmpl` | before: one match on line 42; after: no matches |
| Render (optional, needs 1Password `op` signed in) | `chezmoi execute-template < .chezmoiscripts/auth/run_once_after_auth-tailscale.sh.tmpl > "$XDG_RUNTIME_DIR/ts-render.sh"` | exit 0, a rendered bash script |
| Syntax check the render (optional) | `bash -n "$XDG_RUNTIME_DIR/ts-render.sh"` | exit 0, no syntax errors |

> The render step needs `op` authenticated (the template calls `onepasswordRead`).
> If `op` is not signed in, SKIP the optional render/syntax steps — do NOT
> attempt to stub or bypass the secret. Rely on the grep-based checks instead.

## Scope

**In scope** (the only file you should modify):
- `.chezmoiscripts/auth/run_once_after_auth-tailscale.sh.tmpl`

**Out of scope** (do NOT touch):
- Any other `.chezmoiscripts/**` file — this is a one-line-behavior fix, not a
  sweep of the provisioning scripts.
- The `status --json` guard (lines 38–40) and its accepted backend-state list —
  it is correct as written; do not "tighten" it.
- The `--accept-risk=all` flag on `up` — it suppresses tailscale's interactive
  risk prompts for unattended apply and is intentional here; leave it.

## Git workflow

- Branch: `bugfix/tailscale-auth-failure-propagation`.
- Verify the branch name before the first commit: `git branch --show-current`.
- One commit; Conventional Commits, lowercase subject, e.g.
  `fix(tailscale): fail apply when tailscale up fails`.
- Do NOT push or open a PR unless the operator instructed it.

## Steps

### Step 1: Replace the failure-masking `else` branch

In `.chezmoiscripts/auth/run_once_after_auth-tailscale.sh.tmpl`, replace this
exact line (line 42):

```bash
  "${SUDO[@]}" "${TAILSCALE[@]}" up --operator "$USER" --accept-routes --accept-dns --accept-risk=all --auth-key={{- onepasswordRead "op://Private/Tailscale/Auth Key" | quote -}} || echo "Auth Failed"
```

with these four lines (note: the `--auth-key={{- … -}}` token is copied
verbatim — only the wrapping changes from `|| echo` to `if ! …; then … exit 1`):

```bash
  if ! "${SUDO[@]}" "${TAILSCALE[@]}" up --operator "$USER" --accept-routes --accept-dns --accept-risk=all --auth-key={{- onepasswordRead "op://Private/Tailscale/Auth Key" | quote -}}; then
    printf 'auth-tailscale.sh: `tailscale up` failed; node did not join the tailnet. Fix the auth key or connectivity, then re-run `chezmoi apply`.\n' >&2
    exit 1
  fi
```

Why `if ! …; then` rather than just deleting `|| echo "Auth Failed"`: under
`set -e` a bare failing `up` would also exit nonzero, but the explicit form adds
a clear diagnostic to **stderr** and an explicit `exit 1`, which is easier to
spot in an apply log and unambiguous about intent.

**Verify**:
- `grep -n 'Auth Failed' .chezmoiscripts/auth/run_once_after_auth-tailscale.sh.tmpl` → **no output**.
- `grep -n 'if ! ' .chezmoiscripts/auth/run_once_after_auth-tailscale.sh.tmpl` → shows the new line.
- `grep -n 'exit 1' .chezmoiscripts/auth/run_once_after_auth-tailscale.sh.tmpl` → shows the new line.
- `grep -c 'onepasswordRead "op://Private/Tailscale/Auth Key"' .chezmoiscripts/auth/run_once_after_auth-tailscale.sh.tmpl` → `1` (the secret token is preserved exactly once).

### Step 2: (Optional) Confirm the rendered script is valid bash

Only if 1Password `op` is signed in on this machine:

```sh
chezmoi execute-template < .chezmoiscripts/auth/run_once_after_auth-tailscale.sh.tmpl > "$XDG_RUNTIME_DIR/ts-render.sh"
bash -n "$XDG_RUNTIME_DIR/ts-render.sh"
rm -f "$XDG_RUNTIME_DIR/ts-render.sh"
```

**Verify**: `bash -n` exits 0 (no syntax errors). Then delete the rendered file
(it contains the secret) — do not read it, print it, or leave it on disk.

If `op` is not signed in, skip this step; the Step 1 grep checks are sufficient
to confirm the edit.

## Test plan

There is no automated test harness for the `.sh.tmpl` provisioning scripts (they
require a live machine, `sudo`, and a real tailnet), so verification is
structural:

- The masking string `Auth Failed` is gone (grep, Step 1).
- The failure path now `exit 1`s (grep, Step 1).
- The secret token is preserved intact (grep count = 1, Step 1).
- If `op` is available, the rendered script parses under `bash -n` (Step 2).

No new automated test file is created. (Note for the reviewer: plan 001 does not
lint `.sh.tmpl` files either, because shellcheck cannot parse Go templates.)

## Done criteria

Machine-checkable. ALL must hold:

- [ ] `grep -c 'Auth Failed' .chezmoiscripts/auth/run_once_after_auth-tailscale.sh.tmpl` → `0`.
- [ ] `grep -c 'exit 1' .chezmoiscripts/auth/run_once_after_auth-tailscale.sh.tmpl` → `1`.
- [ ] `grep -c 'onepasswordRead "op://Private/Tailscale/Auth Key"' .chezmoiscripts/auth/run_once_after_auth-tailscale.sh.tmpl` → `1`.
- [ ] If `op` is signed in: `chezmoi execute-template <` the file piped to `bash -n` exits 0 (and the rendered file is deleted afterward).
- [ ] `git status` shows only this one file modified (the pre-existing
      `dot_config/agent-of-empires/config.toml` change is not yours; leave it unstaged).
- [ ] `plans/README.md` status row updated.

## STOP conditions

Stop and report back (do not improvise) if:

- The line-42 content in the live file does not match the "Current state"
  excerpt (the file drifted since this plan was written).
- `bash -n` on the rendered script reports a syntax error (your edit produced
  malformed bash once the template expands — report the rendered structure
  WITHOUT the secret value).
- Rendering fails for any reason **other** than `op` not being signed in.
- You find yourself needing to change the `status --json` guard or any other
  file to make this work.

## Maintenance notes

- Because this is a `run_once` script, editing its content changes its hash, so
  chezmoi will execute it once more on the next apply regardless — expected. On
  an already-authenticated machine the `status --json` guard makes that a no-op.
- Watch for the same `|| echo …`/`|| true` failure-masking anti-pattern in the
  sibling auth scripts (`run_onchange_before_auth-github.sh.tmpl`,
  `run_onchange_before_auth-gitlab.sh.tmpl`) if they are ever revisited — this
  plan deliberately scopes to tailscale only, where the masking was confirmed.
- A reviewer should confirm the diff changes exactly one logical line into the
  `if ! …; then … exit 1; fi` form and preserves the `onepasswordRead` token
  character-for-character.
