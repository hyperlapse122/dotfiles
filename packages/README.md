# packages/

The **`@h82/dotfiles` Yarn Berry monorepo** — a single Yarn workspace whose root
is this directory. It holds the repo's TypeScript/JavaScript library packages.

- **Workspace root**: [`package.json`](package.json) is the private
  `@h82/dotfiles` root with `"workspaces": ["*"]`. Each subdirectory containing
  a `package.json` is a member.
- **The root is `packages/`, not the repo root.** This is deliberate: there is
  no `package.json`/`yarn.lock`/`.yarn/` at `~/dotfiles`, so `cd ~/dotfiles`
  stays a plain checkout, while `cd ~/dotfiles/packages` is the Yarn project. A
  repo-root manifest would otherwise turn the whole checkout into a Yarn project
  (the user-global `~/.yarnrc.yml` applies repo-wide).

## What this is NOT

- **Not bootstrap-installed.** Unlike [`../crates/`](../crates/) (whose Rust
  binaries are `cargo install`'d into `~/.local/bin` during dotbot bootstrap), a
  library here ships nothing to install. `install.*.yaml` does not touch
  `packages/`, and dotbot does not link anything from it. Consumers install and
  build a package themselves.
- **Not published.** Members are `private: true`; the `@h82/` scope is a naming
  namespace, not a registry target.

## Members

| Path | Package | Purpose |
|---|---|---|
| [`mxm4-haptic/`](mxm4-haptic/) | `@h82/mxm4-haptic` | Node/Bun client for the `mxm4-hapticd` daemon — sends MX Master 4 haptic waveforms over the daemon's AF_UNIX socket. Mirrors the portable client surface of [`../crates/mxm4-haptic/src/lib.rs`](../crates/mxm4-haptic/src/lib.rs). |

## Conventions

- **Package manager: Yarn Berry** (the repo-wide preferred manager). The
  user-global `~/.yarnrc.yml` hardening applies to the whole workspace: exact
  version pinning (no `^`/`~`/ranges), a 1-week dependency cooldown gate
  (`npmMinimalAgeGate`), and disabled lifecycle scripts (`enableScripts: false`).
  Do not relax these. The workspace-root [`.yarnrc.yml`](.yarnrc.yml) overrides
  only `nodeLinker: node-modules` (so plain `tsc`/`node --test` resolve a normal
  `node_modules/` tree instead of PnP); everything else cascades.
- **One lockfile**: the workspace-root `packages/yarn.lock` is the only lockfile
  and is **tracked** (lockfile convention, like the Rust `Cargo.lock` under
  `crates/`). `node_modules/` hoists to `packages/node_modules/`. There are no
  per-member lockfiles or `node_modules/`. Per-member `dist/` build output,
  `packages/node_modules/`, and `packages/.yarn/` are git-ignored (scoped
  patterns in the root `.gitignore`).
- **First install gotcha**: the user-global `enableImmutableInstalls: true`
  makes the very first `yarn install` (which must generate `yarn.lock`) fail.
  Use `yarn add <pkg>@<exact>` (a mutating command) or
  `yarn install --no-immutable` for the initial lockfile; subsequent
  `yarn install --immutable` runs are clean.

## Working in the workspace

Tasks are orchestrated by [Turborepo](https://turborepo.com)
([`turbo.json`](turbo.json) defines `build`, `typecheck`, and `test`). The
workspace-root scripts delegate to `turbo run …`:

```sh
cd packages
yarn install --immutable   # restore deps (clean once yarn.lock exists)
yarn build                 # turbo run build   (across all members, cached)
yarn typecheck             # turbo run typecheck
yarn test                  # turbo run test

# or target a single member directly:
yarn workspace @h82/mxm4-haptic build
```

`build` outputs `dist/**`; `typecheck` and `test` `dependsOn` `^build`. Turbo's
caches (`packages/.turbo/`, `packages/*/.turbo/`) are git-ignored.

## Adding a new package

1. `mkdir packages/<name>` and add `package.json` (`@h82/<name>`,
   `private: true`, `"type": "module"`). The `"workspaces": ["*"]` glob picks it
   up automatically. Reference sibling packages with the `workspace:*` protocol.
2. Pin every dependency to an exact, cooldown-valid (≥7 days old) version. Run
   `yarn install` from `packages/` to update the single root `yarn.lock`.
3. Document the package in its own `README.md` and add a row to the members
   table above.
4. Update the root [`AGENTS.md`](../AGENTS.md) Layout block and
   [`README.md`](../README.md) repo-structure table in the **same commit** (the
   repo's hard documentation-sync rule).
