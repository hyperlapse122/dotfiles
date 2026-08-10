# unmanaged-repo-guard decommission checklist (operator-run, not automated)

> **Label:** unmanaged-repo-guard decommission checklist. This document is
> manual operator guidance for hosts that previously applied the managed
> `unmanaged-repo-guard` omp plugin. Chezmoi executes none of it: the removal is
> source-only plus a `.chezmoiremove` prune, apply never uninstalls an omp
> plugin, and no teardown script exists or may be added.

**Ordering is NOT load-bearing here**, unlike `docs/decommission/ydotool.md`.
`omp plugin uninstall` resolves its target from `~/.omp/plugins/installed_plugins.json`,
which is keyed by the plugin id independently of the marketplace catalog, so an
apply that has already dropped the guard from the `h82-dotfiles` catalog does
not strand the uninstall. Apply-then-uninstall and uninstall-then-apply both
work.

One ordering fact does matter: the uninstall is durable only once the source
change has landed. While `.chezmoidata/agents.yaml` still carries the
`unmanaged-repo-guard` plugin row, the phase-70 reconciler reinstalls the plugin
on the next apply.

**What the apply does and does not reach.** After `chezmoi apply`, the deployed
source tree at `~/.local/share/omp-plugins/plugins/unmanaged-repo-guard` is
gone. The copy omp installed under `~/.omp/plugins` is not chezmoi-managed and
is still loaded, so **until you finish this checklist the guard still blocks**.

Work through this on each previously provisioned host.

## 1. Read the block log before destroying it

The guard wrote a durable record of every block it made. It is the only evidence
for or against the claim that the guard prevented no harm, and once it is gone
there is no baseline for judging the replacement rule. The log excludes command
text by design, but it does carry the host and the target repository of every
block, so treat those two fields as private.

```sh
log="${XDG_STATE_HOME:-$HOME/.local/state}/unmanaged-repo-guard/blocks.jsonl"
[ -f "$log" ] && wc -l "$log"
[ -f "$log" ] && jq -r '.outcome' "$log" | sort | uniq -c
```

Record only the aggregate counts — total blocks and the tally by outcome — in
the `Reversed on 2026-08-10` note under decision 1 of
`docs/plans/feedback-sweep-plan.md`. Do not commit host or repository names:
this repository is public, and those fields identify third parties. Read them
locally if you want them (`jq -r '[.host, .repo] | @tsv' "$log" | sort -u`) and
leave them out of the note. A missing file means the guard never blocked on this
host; note that instead.

## 2. Disable and uninstall the plugin

```sh
omp plugin disable --scope user unmanaged-repo-guard@h82-dotfiles
omp plugin uninstall --scope user unmanaged-repo-guard@h82-dotfiles
```

**Do not rehearse this with `--dry-run`.** `omp plugin uninstall` accepts the
flag and ignores it: it prints `✔ Uninstalled …` and performs the uninstall.
Observed on omp at the version this repository pins, 2026-08-10.

**Do not remove the `h82-dotfiles` marketplace.** `mxm4-haptic` still lives in
it, and the phase-70 reconciler re-adds it on every apply.

## 3. Confirm the surviving plugin set

```sh
omp plugin list --json | jq -r '.marketplace[].id'
```

On a non-container host exactly two ids must remain:

```text
mxm4-haptic@h82-dotfiles
compound-engineering@compound-engineering-plugin
```

Inside a container only `compound-engineering@compound-engineering-plugin`
remains: `marketplaces.h82-dotfiles.container: skip` keeps `mxm4-haptic` out
there, which is also why step 2's note about the reconciler re-adding the
marketplace applies only where an `h82-dotfiles` row is eligible.

## 4. Delete the runtime state directory

Only after step 1 has captured its contents.

```sh
rm -rf "${XDG_STATE_HOME:-$HOME/.local/state}/unmanaged-repo-guard"
```

## 5. Confirm the block is gone

The whole point of the change. In a fresh session, have an agent file an issue
in a GitLab project in your personal namespace. It must file with no permission
probe, no block, and no confirmation prompt.

Then check the other direction: point an agent at a repository that plainly is
not yours, such as an upstream dependency's tracker. It must ask first, stating
the target repository, the proposed title, and the proposed body — and honor a
"no".

Those two checks are the only proof of the new behavior. No automated gate in
this repository covers them: the change deletes the CI harness that drove a real
omp through scripted tool calls.
