---
name: js-package-managers
description: >
  Playbook for the hardened npm / pnpm / Yarn Berry / Bun policy. Load this
  BEFORE editing a `package.json` dependency, unblocking a package's
  install-time lifecycle script, correcting a version range to an exact pin,
  or handling a "version too fresh" cooldown failure. It covers the
  per-manager lifecycle-script override mechanics (the narrowest-scope opt-in
  for each manager), the exact-version-pinning correction rule, and the
  1-week cooldown gate handling. Do NOT load it for ordinary `import`/usage of
  an already-installed package, for non-JS dependency systems, or for running
  scripts that don't touch dependency resolution. The binding one-liners
  (preserve the three switches; pin exact; never lower the cooldown) are in
  core AGENTS.md and apply regardless.
---

# JavaScript package managers

User-global config hardens **npm, pnpm, Yarn, and Bun** against supply-chain attacks via
three switches. **MUST** preserve all three:

| Switch | npm | pnpm | Yarn Berry | Bun |
|---|---|---|---|---|
| Lifecycle scripts disabled | `ignore-scripts` | `ignore-scripts` | `enableScripts: false` | `ignoreScripts` |
| Exact version pinning | `save-exact` | `save-exact` | `defaultSemverRangePrefix: ""` | `[install] exact` |
| 1-week cooldown | `min-release-age=7` (days) | `minimumReleaseAge: 10080` (min) | `npmMinimalAgeGate: 10080` (min) | `minimumReleaseAge = 604800` (sec) |

**MUST NOT** edit user-global configs (`~/.npmrc`, `~/.yarnrc.yml`, `~/.bunfig.toml`,
`~/.config/pnpm/config.yaml`, or per-OS equivalents) to relax any switch. The per-project
escape hatches are the supported override.

## Overriding the lifecycle-script block

Opt in at the **narrowest possible scope**. Per-manager mechanics + the
"name-the-behaviour" requirement → [`references/override-mechanics.md`](references/override-mechanics.md).

## Exact version pinning

- Every dependency in `dependencies`, `devDependencies`, and `optionalDependencies` of every
  `package.json` **MUST** be pinned to an exact version — no `^`, `~`, `>=`, `latest`, `*`,
  `x`.
- The user-global config produces exact specs automatically via `yarn add` / `npm install`
  / `pnpm add` / `bun add` — agents **SHOULD NOT** pass any range flag.
- **MUST** correct any existing range specifier to an exact version when modifying a
  `package.json` for any reason.
- **MUST NOT** introduce a new range specifier.
- **MUST NOT** edit a lockfile by hand to dodge the rule.

### `peerDependencies` are exempt — use ranges or wildcards

- `peerDependencies` (and the matching `peerDependenciesMeta`) **MUST NOT** be exact-pinned.
  Pinning a peer to one exact version forces that single version on every downstream
  consumer and provokes peer-conflict errors — the opposite of the intent.
- **MUST** express peers as the widest range the package actually supports: a caret/`>=`
  range (`^18.0.0`, `>=18`), a multi-major OR range (`^18 || ^19`), or `*` when genuinely
  version-agnostic.
- **MUST NOT** "correct" an existing peer range to an exact pin — leave peer ranges alone,
  and when adding a peer, author the range deliberately rather than copying the installed
  exact version.
- The cooldown gate and lifecycle-script switches still apply to whatever concrete version
  ends up installed to satisfy the peer.
- **Other exception**: a project-level `AGENTS.md` may permit ranges elsewhere where
  genuinely required (e.g. a library `package.json` authored for downstream consumers) —
  state the exception explicitly when applying it.

## Cooldown gate (1 week)

A version must be **at least one week old** before any manager resolves it. "Does not meet
the minimumReleaseAge constraint" (or equivalent) means the version is too fresh and
**MUST NOT** be installed.

- **MUST** pin to the most recent version that already satisfies the gate.
- **MUST NOT** add the package to a preapproved/exclude list (`npmPreapprovedPackages` in
  Yarn, `minimumReleaseAgeExclude` in pnpm, `minimumReleaseAgeExcludes` in Bun) without
  explicit per-package user approval.
- **MUST NOT** lower the cooldown value in any user-global or project-level config to work
  around a fresh-version failure.
