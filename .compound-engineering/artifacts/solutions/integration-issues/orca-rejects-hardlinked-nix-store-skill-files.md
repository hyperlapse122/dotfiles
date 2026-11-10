---
title: Orca rejects skill files hardlinked by the Nix store optimiser
date: "2026-09-26"
category: integration-issues
module: Orca agent skills (Home Manager)
problem_type: integration_issue
component: tooling
severity: medium
symptoms:
  - "Orca shows the Nix-installed Orca skills as a different version from the installed Orca, or as unrecognized"
  - "The skills' SKILL.md hashes match the AppImage's bundled skill manifest exactly, and the skills source uses the same release tag as the AppImage"
root_cause: config_error
resolution_type: code_fix
tags: ["orca", "agent-skills", "home-manager", "nix-store", "auto-optimise-store", "hardlink", "nlink"]
retire_when: "No tool this flake configures inspects installed files for their link count or symlink status; Orca skills are no longer installed (2026-10-04), so keep this only for the general lesson"
---

# Orca rejects skill files hardlinked by the Nix store optimiser

**Status (2026-10-04):** The flake no longer installs Orca's skills. `home/h82/agents/orca-skills.nix` and `tests/orca-skills.nix`, named below as the fix, were removed so the skills stop reaching sessions that other orchestrators start. `home/h82/agents/retire-orca-skills.nix` now reads each root's `.orca-skills` manifest once, removes the copies it lists, and deletes the manifest; `tests/retire-orca-skills.nix` covers it. The general lesson under Prevention still applies to any tool that inspects installed files on disk. The store optimiser still applies: `auto-optimise-store = true` in `modules/shared/nix-settings.nix` covers NixOS hosts, while macOS keeps it off (`modules/darwin/nix.nix`).

## Problem

Orca's agent skills were installed with Home Manager `home.file` links into the pinned `stablyai/orca` source in the Nix store. Orca never recognized them as its own skills. The user saw this as a version mismatch between the installed skills and Orca.

## Symptoms

- Orca reported the installed Orca skills as not matching the installed Orca version.
- The version pin was already correct. `packages/orca.nix` fetches the AppImage and the skills source from the same `v${version}` tag (1.4.206 at the time).
- The content was also correct. Every `SKILL.md` hashed identically to its entry in the AppImage's `resources/skills/current-manifest.json`.

## What didn't work

Comparing git references and file contents could not find the fault, because both already matched. Pointing the two fetches at "the same reference" would have changed nothing. The files Orca reads were byte-identical to the release. The difference was in their filesystem metadata.

## Solution

Orca 1.4.206 judges an installed skill by walking the skill directory itself. Its observer in the AppImage's `resources/app.asar` throws when a regular file's link count is not 1:

```js
else if(y.isFile()){if(y.nlink!==1)throw Error(`skill-package-link`); ...
```

The caller catches that error and reports the skill as `unrecognized`, with `installedAppVersion: null`. It never reaches the digest comparison that would have matched.

This host sets `auto-optimise-store = true`, so the store hardlinks identical files. The skills' `SKILL.md` files in `/nix/store/...-orca-skills-1.4.206/skills/*/` had link counts of 3 to 6. A Home Manager link resolves to those files, so every skill failed the check.

The fix installs plain per-user copies instead of links. `home/h82/agents/orca-skills.nix` defines an `orca-skills-install` script and runs it from `home.activation.orcaSkills`, ordered after `linkGeneration`. For each root (`~/.claude/skills`, `~/.gemini/config/skills`, `~/.agents/skills`), the script does the following:

- Copies each skill into a staging directory, makes it user-writable, and moves it into place over the old one.
- Writes a `.orca-skills` manifest of the names it installed. The next run removes a name that left the source and leaves a user's own skills alone.

After the fix, the source files still show a link count of 3 and every copy shows 1.

## Why This Works

A copy in `$HOME` is a new inode with a link count of 1. A second store derivation that copies the tree would not help. The optimiser can hardlink any identical file inside the store, so only files outside the store are guaranteed a link count of 1. That also rules out a Home Manager `home.file` entry of any kind, because Home Manager always links into the store.

## Prevention

- Do not install anything into the store for a tool that inspects the files themselves, as opposed to reading their content. Check the tool for `lstat`/`nlink` tests, symlink rejection, or ownership checks before choosing `home.file`.
- `tests/orca-skills.nix` (removed with the Orca skills; kept as a pattern) ran the materialized activation script twice against a fixture home. It asserted that each copied file has a link count of 1, that no skill is a symlink, and that the copy matches the pinned source. It also checked pruning and that a user's own skill survives. Mutation rounds confirmed that a store link, a hardlinked copy, a missing prune, and a merge-instead-of-replace each turned the check red.
- The builder bash in `pkgs.runCommand` does not include `compgen` (this bit `tests/orca-skills.nix`). An assertion written as `if compgen -G ...; then fail; fi` hits "command not found", which returns nonzero, so the branch never runs and the check stays green. Use `find` for glob-existence tests in checks, and mutation-test any new assertion as `AGENTS.md` requires.
- The copies change only when a new Home Manager generation activates, not on every `nixos-rebuild switch`. See [activation does not re-run when the generation is unchanged](../best-practices/home-manager-activation-does-not-run-on-every-rebuild.md).
