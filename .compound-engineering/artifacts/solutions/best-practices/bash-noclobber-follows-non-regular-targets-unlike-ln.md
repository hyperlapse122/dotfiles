---
title: "bash set -C (noclobber) still opens symlinks to devices and FIFOs; stage with mktemp and ln instead"
date: "2026-10-19"
category: best-practices
module: "Exclusive file creation in bash scripts and Nix shell wrappers"
problem_type: best_practice
component: tooling
severity: medium
applies_when:
  - "A bash script or Nix writeShellScript wrapper must create a credential or state file without overwriting or following any existing entry at the target path"
  - "The target directory could contain a planted symlink to an existing file, /dev/null, or a named pipe (FIFO)"
root_cause: wrong_api
resolution_type: code_fix
related_components:
  - authentication
  - testing_framework
tags:
  - bash
  - noclobber
  - symlink
  - fifo
  - atomic-write
---

# bash set -C (noclobber) still opens symlinks to devices and FIFOs; stage with mktemp and ln instead

## Context

The since-removed `packages/antigravity-acp-path.nix` wrapper seeded `$GEMINI_HOME/antigravity-acp/acp_token.json` from `~/.gemini/antigravity-acp/acp_token.json` when `GEMINI_HOME` was a private Compound Engineering scratch home that held no token yet. Its first implementation checked `if [ -f "$token_target" ] && [ ! -L "$token_target" ]; then return 0; fi` and then relied on bash's `set -C` (`noclobber`) redirection to create the file exclusively:

```sh
if ! (
  umask 077
  set -C
  ${coreutils}/cat "$token_source" > "$token_target"
) 2>/dev/null; then
  printf 'agy_acp_server.par: could not copy the ~/.gemini sign-in into GEMINI_HOME\n' >&2
fi
```

That rejected a dangling symlink (because `O_CREAT|O_EXCL` fails when the symlink entry exists and `stat()` on the target fails) and an existing regular file, but it failed on two other planted entries at `$token_target`:

1. **A symlink to `/dev/null` (or another character device):** bash's `set -C` redirection succeeded, wrote the token into `/dev/null`, left the symlink in place, and exited `0` without printing the failure diagnostic.
2. **A FIFO (`mkfifo`) or a symlink to a FIFO with no reader:** bash opened the FIFO for writing before running `cat`, blocking the wrapper indefinitely before `exec`.

## Why bash `set -C` does this

In bash's `redir_open` (`redir.c`), `noclobber` does not simply pass `O_CREAT|O_EXCL` to a single `open(2)` call. It first tries `open(filename, O_WRONLY|O_CREAT|O_EXCL, mode)`. When that returns `EEXIST`, bash calls `stat(filename, &finfo)` (which follows symlinks) and allows the redirection whenever `!S_ISREG(finfo.st_mode)` by reopening `filename` without `O_EXCL`. That rule exists so `set -C` interactive shells can still redirect to `/dev/null` or `/dev/tty`, and it means `set -C` follows any symlink whose target is a character device, block device, FIFO, or socket, and opens a FIFO directly.

## The fix: stage with `mktemp` and link with `ln`

Stage the contents in a sibling temporary file created by `mktemp` in the same directory (which uses `O_CREAT|O_EXCL` on a fresh random name under `umask 077`), verify it is non-empty, and link it into place with `ln`:

```sh
if ! (
  umask 077
  tmp=$(${coreutils}/mktemp "$acp_dir/.acp_token.XXXXXX") || exit 1
  if ! ${coreutils}/cat "$token_source" > "$tmp" || [ ! -s "$tmp" ] || ! ${coreutils}/ln "$tmp" "$token_target"; then
    ${coreutils}/rm -f "$tmp"
    exit 1
  fi
  ${coreutils}/rm -f "$tmp"
) 2>/dev/null; then
  printf 'agy_acp_server.par: could not copy the ~/.gemini sign-in into GEMINI_HOME\n' >&2
fi
```

`ln "$tmp" "$token_target"` invokes `linkat(2)` without `AT_SYMLINK_FOLLOW`. The kernel refuses to replace or follow any existing directory entry at `$token_target` — regular file, dangling symlink, symlink to an existing file, symlink to `/dev/null`, FIFO, socket, or directory — and returns `EEXIST` without ever opening `$token_target`. Because `$tmp` is populated before `ln` runs, no reader can observe an empty target file while `cat` is in flight or after an unreadable source fails.

## How to apply

- Do not use bash `set -C` (`noclobber`) as a security or exclusivity gate when the destination path could be a symlink to a non-regular file or a FIFO.
- Stage into the destination directory with `mktemp` under `umask 077`, then publish with `ln "$tmp" "$target"` (when refusing any existing entry) or `mv -f "$tmp" "$target"` (when atomically replacing). Always remove `$tmp` on both success and failure.
- In wrapper and activation checks (as the since-removed `tests/antigravity-acp-path.nix` did), test planted symlinks to existing regular files, planted symlinks to `/dev/null`, and planted FIFOs under `timeout` alongside dangling symlinks, and assert that no temporary staging file remains after any run.
