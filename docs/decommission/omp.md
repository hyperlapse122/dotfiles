# oh-my-pi (omp) decommission checklist (operator-run, not automated)

> **Label:** omp decommission checklist. This document is manual operator
> guidance for hosts that previously ran the managed omp harness. Chezmoi
> executes none of it: the removal is source-only plus a `.chezmoiremove` prune
> of the targets chezmoi itself wrote, and no teardown script exists or may be
> added.

Apply the updated source first. That un-writes every managed omp target —
`~/.omp/agent/AGENTS.md`, `mcp.json`, `models.yml`, `APPEND_SYSTEM.md`,
`TITLE_SYSTEM.md`, the `agents/` and `rules/` trees, the auth reconciler's
`.env`, and the local marketplace catalog. Everything below is what omp itself
created, which apply deliberately never touches.

**Revoke the Figma grant before you delete anything.** The reclaim block removes
the credential database, and deleting a token store does not revoke the token.
Section 1 must run first.

## 1. Revoke omp's Figma authorization

`figma-auth` wrote omp's Figma MCP credential row into `~/.omp/agent/agent.db`,
and that grant stays valid at Figma until it is revoked there.

Read the client id out of the row while the database still exists. `figma-auth`
wrote the grant into `auth_credentials`, with the client id inside the JSON
`data` column, so project that one field rather than selecting the whole row —
`data` also holds the access and refresh tokens:

```sh
sqlite3 -readonly ~/.omp/agent/agent.db \
  "select json_extract(data,'\$.clientId') from auth_credentials
   where provider like '%mcp.figma.com%';"
```

No output means this host never authorized Figma through omp; there is nothing
to revoke and you can go straight to section 2.

Otherwise, at **Figma → Settings → Security → Connected apps**, revoke only the
registration matching that client id.

**Do not revoke every `Codex` registration.** Antigravity holds its own live
Figma grant under the same client name, in
`~/.gemini/antigravity-cli/mcp_oauth_tokens.json`. Revoking broadly breaks Figma
MCP for a harness this repository still manages. If you cannot tell the
registrations apart, leave them alone and delete the database only — a stranded
token is a smaller problem than a broken surviving harness.

## 2. Reclaim the host

One block, safe to paste on any previously provisioned host. Nothing here is
chezmoi-managed, so re-running apply will not undo or repeat it.

```sh
rm -rf ~/.omp
rm -rf ~/.local/share/omp-plugins
rm -f  ~/.local/bin/omp
rm -f  ~/.local/share/chezmoi-commands/incomplete/omp/omp
rm -f  ~/.local/bin/figma-auth
rm -f  ~/.local/share/zsh/site-functions/_omp
rm -rf ~/.local/share/agy-plugin-bundles
```

Notes on two of those paths:

- `~/.local/bin/omp` and its staging copy were installed by the command
  manifest, which no longer declares the unit. The reconciler stops managing the
  symlink but does not remove it.
- `~/.local/share/agy-plugin-bundles` existed only because the omp-motivated
  manifest prune forced Antigravity to stage a bundle of its own. The agy plugin
  updater now removes that directory itself on the next apply, so this line only
  matters on a host you are retiring without applying again.

## 3. Confirm

```sh
command -v omp || echo "omp is gone"
test ! -e ~/.omp && echo "~/.omp is gone"
agy plugin list
claude plugin list
```

The last two should still report `compound-engineering`. If either does not, the
harness lost its marketplace registration rather than anything this checklist
removed — re-run `chezmoi apply` to reconcile it.
