# oh-my-pi (omp) restore notes (operator-run, not automated)

> **Label:** omp restore checklist. omp was retired on 2026-09-03 and brought
> back as a managed harness with a deliberately narrow surface: the binary, MCP
> servers, the instruction file, the compound-engineering plugin, and a model
> policy asserted into omp's own `config.yml`. This document is what chezmoi
> cannot do for you — the leftovers of the retirement, and the two facts the
> restore could only assume. Chezmoi executes none of it.

## 1. Before the first apply on a host that ran the old omp

The retirement's reclaim block told operators to delete `~/.omp` entirely. On a
host where that was never run, pre-retirement state is still live and this
restore does **not** clean it up:

- **Old plugins stay installed.** `agents.omp.pluginsRemoved` is empty, so the
  reconciler installs compound-engineering without retiring anything else. The
  old local marketplace carried `mxm4-haptic`, `i-have-adhd`, and
  `unmanaged-repo-guard`. Remove any you no longer want:

  ```sh
  omp plugin list
  omp plugin uninstall --scope user '<name>@<marketplace>'
  ```

- **Old Figma authorization stays valid.** `figma-auth` wrote omp's Figma MCP
  credential into `~/.omp/agent/agent.db`, and deleting a token store does not
  revoke the grant. This restore manages no Figma credential. Read the client id
  out of the row while the database exists — project that one field, because
  `data` also holds the access and refresh tokens:

  ```sh
  sqlite3 -readonly ~/.omp/agent/agent.db \
    "select json_extract(data,'\$.clientId') from auth_credentials
     where provider like '%mcp.figma.com%';"
  ```

  No output means this host never authorized Figma through omp. Otherwise revoke
  only the matching registration at **Figma → Settings → Security → Connected
  apps**. **Do not revoke every `Codex` registration** — Antigravity holds its
  own live grant under the same client name, in
  `~/.gemini/antigravity-cli/mcp_oauth_tokens.json`. If you cannot tell the
  registrations apart, leave them alone; a stranded token is a smaller problem
  than a broken surviving harness.

- **The old plaintext credential is gone on the next apply.** The retirement
  left `~/.omp/agent/.env` in the prune set and it stays there, because the
  restored MCP target resolves the Exa key at render time instead.

## 2. Leftovers this restore does not take back

These paths were omp's own, never chezmoi's, and nothing manages them now:

```sh
rm -rf ~/.local/share/omp-plugins
rm -f  ~/.local/bin/figma-auth
rm -f  ~/.local/share/zsh/site-functions/_omp
```

`~/.local/bin/omp` is managed again through the command manifest, so leave it
alone. `~/.local/share/agy-plugin-bundles` is removed by the agy plugin updater
itself and needs no action here.

## 3. Confirm after the first apply

Two assumptions in the restore plan could only be settled on a live host. Check
both and record what you find.

**Skill visibility.** The plan assumes omp sees the shared skill tree through its
own Discovery behaviour — it inherits rules, skills, and MCP servers from
`.claude`, `.gemini`, and `.codex`, and in this repository all three are symlinks
to `~/.agents/skills`. No omp-specific symlink target is declared. Upstream
documents this as happening "on first run", so check it at two moments:

```sh
# 1. Right after the first apply and first omp start.
omp   # then ask it to list the skills it can see
# 2. After adding a skill to the shared tree.
ls ~/.agents/skills
```

If a skill present in `~/.agents/skills` is missing in omp at either moment,
Discovery is not a live lookup and omp needs its own declared skills target.
That is follow-up work, not a defect in this restore.

**Skill discovery scope.** The restore declares no key narrowing which skill
scopes omp reads. The pre-retirement declaration set
`skills.enableClaudeProject`, `skills.enableClaudeUser`, and
`skills.enableCodexUser` all to `false`. Check what the current default is:

```sh
omp config list --json | jq '{skills: (.skills // {})}'
```

If project-scope discovery is on, a `SKILL.md` inside any repository omp opens
becomes agent instructions — a trust boundary worth closing when omp runs as an
Orca worker across arbitrary checkouts. Declaring those keys in
`agents.omp.settings` is the fix.

**Model availability.** The model policy asserts
`google-antigravity/gemini-3.8-flash` and `google-antigravity/gemini-3.1-flash-lite`.
The reconciler validates a selector only when the catalog speaks for its
provider, so on a host where `google-antigravity` is not authenticated it prints
a skip and asserts anyway. Confirm the models actually resolve:

```sh
omp models --json | jq -r '.models[] | select(.provider == "google-antigravity") | .selector'
```

An apply that fails with `which provider google-antigravity does not serve` means
the declared id is wrong or retired; correct it in `.chezmoidata/agents.yaml`.
