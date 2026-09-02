# Figma global skills decommission checklist (operator-run, not automated)

> **Label:** Figma global skills decommission checklist. This document is manual
> operator guidance for hosts that previously received the global Figma skill
> collection. Chezmoi does not run these commands, and this source change adds
> no teardown or revert script.

Run this checklist only after the revised dotfiles source is available. It
removes obsolete global state. It does not affect project-owned Figma support.

## 1. Apply the revised source

- Run your normal `chezmoi apply` from the revised source.
- The revised source stops creating the global Figma archive, staging tree, and
  reconciliation state. It does not delete an existing host's residue.

## 2. Review and remove direct Figma skill children

This deliberate prefix cleanup removes every direct `figma-*` child, including
an unledgered child. First list the matches:

```sh
skills_dir="${HOME:?}/.agents/skills"
[ -d "$skills_dir" ] || { printf 'missing: %s\n' "$skills_dir" >&2; exit 1; }
find "$skills_dir" -mindepth 1 -maxdepth 1 -name 'figma-*' -print
```

The former global collection contained `figma-code-connect`,
`figma-create-new-file`, `figma-design-to-code`, `figma-generate-design`,
`figma-generate-diagram`, `figma-generate-library`, `figma-implement-motion`,
`figma-swiftui`, `figma-use`, `figma-use-figjam`, `figma-use-motion`, and
`figma-use-slides`. Back up or move any other listed child before continuing.
The next command deletes every listed `figma-*` child.

```sh
set -eu
skills_dir="${HOME:?}/.agents/skills"
[ -d "$skills_dir" ] || { printf 'missing: %s\n' "$skills_dir" >&2; exit 1; }
find "$skills_dir" -mindepth 1 -maxdepth 1 -name 'figma-*' -exec rm -rf -- {} +
find "$skills_dir" -mindepth 1 -maxdepth 1 -type d -name '.figma-skills-txn-*' \
  -exec rm -rf -- {} +
```

Do not remove other children of `~/.agents/skills/`. They can be independently
managed skills such as `agent-browser`, `glab`, or project-provided skills.

## 3. Remove the obsolete collection stage and ownership state

```sh
set -eu
rm -rf -- \
  "$HOME/.local/share/figma-skills-stage" \
  "$HOME/.local/state/figma-skills"
```

These paths belonged only to the retired global collection lifecycle. Missing
paths are expected.

## 4. Verify the cleanup

```sh
set -eu
skills_dir="${HOME:?}/.agents/skills"
[ -d "$skills_dir" ] || { printf 'missing: %s\n' "$skills_dir" >&2; exit 1; }
leftover=$(find "$skills_dir" -mindepth 1 -maxdepth 1 -name 'figma-*' -print)
[ -z "$leftover" ] || { printf 'remaining Figma skills:\n%s\n' "$leftover" >&2; exit 1; }
transactions=$(find "$skills_dir" -mindepth 1 -maxdepth 1 -type d \
  -name '.figma-skills-txn-*' -print)
[ -z "$transactions" ] || { printf 'remaining Figma transactions:\n%s\n' "$transactions" >&2; exit 1; }
test ! -e "$HOME/.local/share/figma-skills-stage"
test ! -e "$HOME/.local/state/figma-skills"
```

All commands must exit successfully. The verification must report no remaining
Figma skill or transaction paths.

## 5. Credential boundary — do not remove or rotate

- **Superseded for omp.** `~/.omp/agent/agent.db` and `packages/figma-auth/` were
  protected here while the omp harness was managed. Both have since been retired;
  [`omp.md`](omp.md) owns their removal and orders the Figma revocation before the
  database is deleted. Follow that document instead of this section for omp.
- The surviving harnesses keep their own Figma credential stores. Do not delete
  those while the harness is in use.
- Do not revoke credentials or reauthorize as part of this cleanup. Project
  repositories own any future Figma MCP configuration and skills.
