---
title: sudo Re-Prompts Inside the expect pty and the MOK Import Never Runs
date: 2026-09-08
last_updated: 2026-09-08
category: integration-issues
module: nvidia
problem_type: integration_issue
component: package_provisioning
symptoms:
  - "the apply prints [sudo] password for <user>: after install-nvidia-fedora: the DKMS MOK keypair already exists; nothing to do, and typing there does nothing"
  - "the prompt appears in English on an otherwise Korean apply, because the enrollment pinned LC_ALL=C"
  - "the apply hangs for 30 seconds at that prompt, then fails with mokutil did not ask for the enrollment password"
  - "install-nvidia-fedora.sh: mokutil --import failed for <cert>; the certificate was NOT queued"
  - "mokutil --list-new is empty after an apply that reported enrollment, and the signed module stays untrusted under Secure Boot"
  - "the same apply authenticated sudo successfully moments earlier, for the package and keypair steps"
root_cause: incorrect_configuration
resolution_type: code_change
severity: high
tags:
  - nvidia
  - secure-boot
  - mok
  - mokutil
  - sudo
  - expect
  - fedora
  - chezmoi
---

# sudo Re-Prompts Inside the expect pty and the MOK Import Never Runs

## Problem

`mokutil --import` asks for a one-time enrollment password twice, and a chezmoi
apply has no terminal to type it on. The enrollment therefore drove the import
through `expect`, unprivileged, letting it spawn the elevation itself:

```tcl
set argv [concat $env(MOK_SUDO) [list mokutil --import $cert]]
spawn -noecho {*}$argv
expect { "input password:" { send -- "$pw\r" } ... }
```

On an interactive apply that never enrolled anything. The visible failure was a
`[sudo] password for <user>:` prompt that swallowed every keystroke, followed by
`exit 90` — `mokutil did not ask for the enrollment password` — after the 30s
timeout, with `mokutil --list-new` still empty afterwards.

## Root cause

Two facts compose into a deadlock:

1. **sudoers scopes its credential timestamp to the terminal.** `timestamp_type`
   defaults to `tty`, and `spawn` gives its child a BRAND NEW pty. However
   recently the apply had authenticated on its own terminal, sudo inside that
   fresh pty found no ticket for it and prompted again.
2. **Nobody in that pty could answer.** `expect` was fed its script on stdin
   (`expect -f -` with a heredoc), so the operator's keystrokes went to the
   terminal expect was not reading, and the script's own `expect` blocks matched
   only mokutil's `input password:` — never sudo's prompt. It fell through to
   `timeout`.

The elevation ladder was working correctly the whole time; the pty is what
invalidated its ticket.

## Solution

Drop `expect` from the enrollment and write the password to mokutil's **stdin**.
`mokutil` reads it with `read_hidden_line()`, which turns echoing off only when
stdin is a terminal and otherwise just `getline()`s the answer, so a pipe
satisfies both prompts:

```bash
if ! {
  trap '' PIPE
  printf '%s\n%s\n' "$MOK_ENROLL_PASSPHRASE" "$MOK_ENROLL_PASSPHRASE" || true
} | "${SUDO[@]}" mokutil --import "$cert"; then
```

Why this holds:

- **sudo stays in the script's own terminal.** No pty is created, so the ticket
  the elevation ladder primed is still valid; where it is not, sudo prompts the
  operator, uses the askpass helper, or fails with its own diagnostic — exactly
  like every other privileged call in the installer.
- **sudo never sees the passphrase.** Without `-S`, sudo reads its own password
  from `/dev/tty` and never from stdin, so the pipe reaches mokutil untouched
  and the enrollment passphrase is never tried as a login password.
- **The passphrase reaches no argv and no file.** `printf` is a shell builtin,
  so the value stays in the shell's memory and the pipe: not in the process
  table, not in a temp file, and not in the privileged process's environment
  (the old shape passed it as an environment prefix to the unprivileged expect).
- **`trap '' PIPE` plus `|| true`.** An already-enrolled certificate makes
  mokutil print `SKIP: <cert> is already enrolled` and exit without reading,
  closing the pipe under `printf`; the trap makes that an ordinary write error
  instead of a SIGPIPE death, and `|| true` keeps the producer out of
  `set -o pipefail`'s answer so the pipeline reports mokutil's status alone.
- **It cannot hang.** There is no prompt matching left (and so no `LC_ALL=C`
  pinning that a localized mokutil would defeat); stdin reaches EOF.

## Consequences elsewhere

`expect` is no longer a precondition of the enrollment, so the
`mok-enroll-no-expect` skip site and the `expect-present` capability probe are
gone, with the matrix totals and the frozen CI boundaries retuned to match.
`expect` stays in the Fedora base package set for the one-time GPG trust edit in
`80-keys`, which does still need a pty.

## Verification

`.ci/smoke-fedora-dkms-mok.sh` drives the rendered `enroll_dkms_mok` against a
real `mokutil` stub process (not a shell function, so argv, environment and
stdin are genuine process properties) and asserts: the passphrase arrives on
stdin once per prompt, appears in neither argv nor the environment, sudo is
never given `-S`, an import that exits without reading the pipe is still a
success, a failing import is propagated and prints the by-hand command, and no
`expect` invocation returns to the enrollment.
