# Check changes in dotfiles

From the root of a dotfiles clone or linked worktree, run the checker with its pinned tools on Linux or macOS.

```bash
nix develop .#agent-check -c ./scripts/agent-check
```

Inside that development shell, run `./scripts/agent-check` directly. The default checks staged, unstaged and untracked changes using their working-tree contents. It checks Nix formatting and lints Markdown. Changed source and configuration files also receive local advisories that report the filename, line and rule. A clean checkout exits quietly.

## Check a commit

Enable the repository's Git hook once with `git config core.hooksPath .githooks`. Commit from the development shell to put the pinned tools on your path. The hook runs the checker from the checkout being committed. It checks the Git index, including the staged version of a partially staged file. Markdown lint uses the configuration and files in that snapshot.

Use `--staged` to run the same check by hand.

```bash
nix develop .#agent-check -c ./scripts/agent-check --staged
```

## Check a committed range

The `agent-check` CI job checks the committed head tree even when the working tree is clean. Pull requests compare against the merge base. Pushes compare the before and head commits. A manual run or a push with an all-zero before SHA compares against the first parent, or the empty tree for the initial commit.

```bash
nix develop .#agent-check -c ./scripts/agent-check --range "$base" "$head"
```

## Approve registry lookups

The registry step requires the development shell, which supplies the pinned Python interpreter. Keep the policy outside the checkout under the control of the person or system authorizing the lookups. Pass its absolute path before the snapshot selection.

```bash
nix develop .#agent-check -c ./scripts/agent-check --registry-policy /absolute/path/to/registries.json --range "$base" "$head"
```

This example approves three public packages and routes private names to their registries.

```json
{
  "public": {
    "npm": ["react", "@types/react"],
    "python": ["httpx"],
    "go": ["golang.org/x/text"]
  },
  "private": {
    "npm": {
      "@team/": { "url": "https://npm.example.org", "tokenEnv": "TEAM_NPM_TOKEN" }
    },
    "python": {
      "team-tools": { "url": "https://python.example.org" }
    },
    "go": {
      "git.example.org/team/": { "url": "https://go.example.org" }
    }
  }
}
```

Public approvals name individual packages. Use normalized names for Python (`team_tools` becomes `team-tools`). Private routes use an exact name or a prefix ending in `/`. The longest private match wins even when the same dependency appears in `public`. The registry must offer the ecosystem's metadata API over HTTPS. Use a trusted dotfiles checkout for authenticated runs and set the token variable only for that invocation. The inspector removes configured token variables from the child environment and gives the HTTP client the token in the request header for the approved registry. It follows no redirects.

The check compares `package.json`, `pyproject.toml`, and `go.mod` with the selected base, using the old path for a detected rename. It follows manifest links within the selected tree and checks them when their targets change. An unresolved link reports incomplete verification. The check handles npm aliases, Python extras and markers, and Go `require` and `replace` directives. Workspace and local path references, Git dependencies, and direct URLs are skipped.

A named Python source or a private npm registry declaration requires a private route in the policy. The check reads default and scoped `registry` settings from the selected tree's `.npmrc` files at or above the manifest. A changed registry setting can require a new lookup even when the manifest is unchanged. The trusted policy supplies the lookup destination. A missing package, missing approval, authentication failure, or unreachable registry fails the check. [npm project configuration](https://docs.npmjs.com/cli/v12/configuring-npm/npmrc/)

Successful lookups report the publication date and download count offered by the approved registry. Public npm reports the package creation date and last week's downloads. PyPI reports the latest release's upload date and the Go proxy reports the queried version's time. Fields the registry does not supply are marked unavailable.

In this repository, the CI registry step reads `AGENT_CHECK_REGISTRY_POLICY` from GitHub Actions repository variables and writes it to the runner's temporary directory. Its default is an empty approval list. Add public approvals there when introducing a dependency. CI runs the offline checks in a separate step. Keep private registry credentials and confidential names out of public pull request workflows.
