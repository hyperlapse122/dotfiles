# packages/

The **`@h82/dotfiles` Bun workspace** — a single Bun workspace whose root is
this directory. It holds the repo's TypeScript/JavaScript library packages.

- **Workspace root**: [`package.json`](package.json) is the private
  `@h82/dotfiles` root with `"workspaces": ["*"]`. Each subdirectory containing
  a `package.json` is a member.
- **The root is `packages/`, not the repo root.** This is deliberate: there is
  no `package.json`/`bun.lock` at `~/dotfiles`, so `cd ~/dotfiles` stays a plain
  checkout, while `cd ~/dotfiles/packages` is the Bun project. A repo-root
  manifest would otherwise turn the whole checkout into a Bun project.

## What this is NOT

- **Built on apply, not directly deployed.** Unlike the other files here which chezmoi deploys to `$HOME`, `packages/` and `crates/` are source-only trees. They are excluded from deployment via `.chezmoiignore`. Instead, they are built on apply by the `.chezmoiscripts/build/` run_onchange scripts. The plugins built from `packages/` are symlinked into `~/.config/opencode/plugins/`.
- **Not published.** Members are `private: true`; the `@h82/` scope is a naming
  namespace, not a registry target.

## Members

| Path | Package | Purpose |
|---|---|---|
| [`mxm4-haptic/`](mxm4-haptic/) | `@h82/mxm4-haptic` | Node/Bun client for the `mxm4-hapticd` daemon — sends MX Master 4 haptic waveforms over the daemon's AF_UNIX socket. Mirrors the portable client surface of [`../crates/mxm4-haptic/src/lib.rs`](../crates/mxm4-haptic/src/lib.rs). |
| [`opencode-mxm4-haptic/`](opencode-mxm4-haptic/) | `@h82/opencode-mxm4-haptic` | OpenCode plugin that pulses MX Master 4 haptics on OpenCode events (e.g. `session.idle` → `COMPLETED`). Forwards waveforms to the `mxm4-hapticd` daemon via a bundled `@h82/mxm4-haptic`. |
| [`opencode-playwright-cli-session-injection/`](opencode-playwright-cli-session-injection/) | `@h82/opencode-playwright-cli-session-injection` | OpenCode plugin that sets `PLAYWRIGHT_CLI_SESSION = opencode-<hash8>` (first 8 hex chars of the SHA-1 of the raw `cwd` string) via the `shell.env` hook, giving each project a stable, isolated `playwright-cli` browser session. Cross-platform. |
| [`opencode-scratch-guard/`](opencode-scratch-guard/) | `@h82/opencode-scratch-guard` | OpenCode plugin that enforces the `AGENTS.md` temp-file policy: injects a per-user scratch dir as `$TMPDIR` via `shell.env`, and denies the shared system temp (`/tmp`, `/var/tmp`, `/dev/shm`) for `bash`/`write`/`edit`/`read` via `tool.execute.before`. Mode via `OPENCODE_SCRATCH_GUARD` (`enforce`/`warn`/`off`). Cross-platform. |

## Conventions

- **Package manager: Bun** (the repo-wide preferred manager). The
  user-global `~/.bunfig.toml` hardening applies to the whole workspace: exact
  version pinning (`exact = true`), a 1-week dependency cooldown gate
  (`minimumReleaseAge = 604800`), and disabled lifecycle scripts
  (`ignoreScripts = true`). Do not relax these. The workspace-root
  [`package.json`](package.json) pins `"packageManager": "bun@1.3.14"`, so the
  workspace uses a single known Bun version regardless of what is installed
  globally.
- **One lockfile**: the workspace-root `packages/bun.lock` is the only lockfile
  and is **tracked** (lockfile convention, like the Rust `Cargo.lock` under
  `crates/`). `node_modules/` hoists to `packages/node_modules/`. There are no
  per-member lockfiles or `node_modules/`. Per-member `dist/` build output,
  `packages/node_modules/`, and Turbo caches are git-ignored (scoped patterns
  in the root `.gitignore`).
- **First install**: `bun install --frozen-lockfile` restores dependencies
  once `bun.lock` exists. To add a dependency, edit `package.json` to an
  exact, cooldown-valid version and run `bun install` from `packages/` so the
  lockfile updates.

## Working in the workspace

Tasks are orchestrated by [Turborepo](https://turborepo.com)
([`turbo.json`](turbo.json) defines `build`, `typecheck`, `test`, `lint`,
`format`, and `format:check`). The workspace-root scripts delegate to
`turbo run …`:

```sh
cd packages
bun install --frozen-lockfile   # restore deps (clean once bun.lock exists)
bun run build                   # turbo run build        (across all members, cached)
bun run typecheck               # turbo run typecheck
bun test                        # turbo run test
bun run lint                    # turbo run lint         (ESLint, per-member config)
bun run format                  # turbo run format       (Prettier --write)
bun run format:check            # turbo run format:check (Prettier --check; CI uses this)

# or target a single member directly:
cd packages/mxm4-haptic && bun run build
```

`build` outputs `dist/**`; `typecheck` and `test` `dependsOn` `^build`;
`lint`/`format`/`format:check` have no deps (ESLint/Prettier read source
directly). `format` is `cache: false` because it writes. Turbo's caches
(`packages/.turbo/`, `packages/*/.turbo/`) are git-ignored.

## Lint + format

ESLint does the **linting**, Prettier does the **formatting** — there is
intentionally **no Biome**. ESLint configuration is **per member** (no
root-level ESLint config); Prettier has a shared root base plus per-member
overrides:

- `eslint.config.mjs` — flat config: `@eslint/js` + `typescript-eslint`
  recommended, `@typescript-eslint/no-unused-vars` tuned to allow `_`-prefixed
  identifiers, and `eslint-config-prettier` appended last so ESLint never fights
  Prettier over style.
- `.prettierrc.json` — `printWidth: 100`, `semi: true`. The workspace root also
  carries a [`.prettierrc.json`](.prettierrc.json) with the same settings as a
  shared base; Prettier resolves the closest config, so the per-member files are
  authoritative for member source and the root one is the fallback for loose
  files under `packages/`.
- `.prettierignore` — excludes `dist/`, `.turbo/`, `node_modules/`, `*.json`,
  `*.md` so Prettier only touches `.ts`/`.mjs` source.

CI runs the workspace `lint` + `format:check` (plus `build`, `typecheck`, and
`test`) via [`../.github/workflows/ci.yml`](../.github/workflows/ci.yml),
alongside the Rust crate build/test and shell linting.

### Editor (VS Code)

The `.vscode/` editor configuration is intentionally not vendored.

## Adding a new package

1. `mkdir packages/<name>` and add `package.json` (`@h82/<name>`,
   `private: true`, `"type": "module"`). The `"workspaces": ["*"]` glob picks it
   up automatically. Reference sibling packages with the `workspace:*` protocol.
2. Pin every dependency to an exact, cooldown-valid (≥7 days old) version. Run
   `bun install` from `packages/` to update the single root `bun.lock`.
3. Give the member its own lint/format setup (per-member ESLint, per-member
   Prettier overriding the shared root base): add
   `eslint`, `@eslint/js`, `typescript-eslint`, `eslint-config-prettier`, and
   `prettier` as exact-pinned devDeps, an `eslint.config.mjs`, a
   `.prettierrc.json`, a `.prettierignore`, and `lint`/`format`/`format:check`
   scripts. Copy an existing member's config as the template.
4. Document the package in its own `README.md` and add a row to the members
   table above.
5. Update the root [`AGENTS.md`](../AGENTS.md) Layout block and
   [`README.md`](../README.md) repo-structure table in the **same commit** (the
   repo's hard documentation-sync rule).
