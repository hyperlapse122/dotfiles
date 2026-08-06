# @h82/release-lock

Resolves external tool releases into the static `.chezmoidata` release lock.

This exists so a chezmoi source-state read performs **no network I/O**.
Versions, asset URLs, and checksums used to be resolved at render time —
partly through chezmoi's `gitHub*` builtins (HTTP-cached, but only for the 60
seconds GitHub's `Cache-Control` allows) and partly through `output "curl"`
and `getRedirectedURL`, which were never cached and shelled out on every
render. Both failed with no network reachable, so an offline `chezmoi diff`
was impossible.

The plan this package implements is
[`docs/plans/2026-07-27-001-refactor-static-release-artifact-lock-plan.md`](../../docs/plans/2026-07-27-001-refactor-static-release-artifact-lock-plan.md).

## Status

All seven resolver kinds are implemented, and the committed
`.chezmoidata/releases.json` covers every render-time resolution source in the
repo. The lock is the sole version, immutable revision, inventory, URL, and
checksum source: every `.chezmoiexternals` file and every version-consuming
script template reads it through `.chezmoitemplates/release-lock-ref.tmpl`.
A source-state read performs no network I/O; re-run this package to refresh the
lock.

| Resolver kind | State |
|---|---|
| `githubRelease` | implemented |
| `githubTag` | implemented |
| `githubSkillCollection` | implemented |
| `gitlabRelease` | implemented |
| `npm` | implemented |
| `vendorManifest` | implemented |
| `gitRef` | implemented |

## Why digests are free

GitHub's `releases/latest` response carries a `digest` field on every asset, so
one call per repository yields the tag, each platform's asset URL, **and** its
sha256. A Linux runner can therefore lock darwin artifacts without
downloading them — verified by hashing a real `darwin-arm64` artifact and
comparing it to the recorded digest.

## Usage

```sh
bun run packages/release-lock/src/cli.ts                          # refresh the repo lock in place
bun run packages/release-lock/src/cli.ts --out .chezmoidata/releases.json
bun run packages/release-lock/src/cli.ts --stdout                 # inspect merged JSON
```

A source that fails to resolve is reported on stderr and omitted from the
fresh resolution, and the process exits non-zero. Plain invocation and `--out`
overlay a partial resolution onto the file already at the destination, so an
omitted entry keeps its last good value rather than being blanked. A clean run
replaces the tool set, which prunes entries removed from the registry. Writes
replace the destination atomically.

`--stdout` reads the repository lock and prints the same complete merged JSON
without modifying it. It is for inspection only: do not redirect any invocation
over the lock it reads (for example, `--stdout > .chezmoidata/releases.json`).
The shell truncates a redirection target before the CLI starts, so the process
cannot recover that prior content. Use plain invocation or `--out` to refresh a
lock safely.

The hourly refresh uses this same CLI and updates a changed generated lock
without a separate approval step. The lock diff remains review-visible for
audit and reproducibility; it is not an approval gate. A resolver failure exits
non-zero and preserves the prior whole entry, so incomplete upstream evidence
cannot silently shrink the desired collection.

## Adding a tool

Add an entry to [`src/registry.ts`](src/registry.ts) naming its resolver kind,
its source, and — for tools with downloadable artifacts — an `asset` selector
returning the upstream filename for a platform. Conventions that matter:

- A selector returns `null` for a platform the tool deliberately does not
  target.
- `emulatedPlatforms` declares targets upstream genuinely does not build,
  served by the amd64 artifact under emulation and marked `emulated: true` in
  the lock, so an `x86_64` URL under an `arm64` key is deliberate. This is
  declared rather than inferred on purpose: any *other* missing asset is a
  hard error, so a stale asset pattern cannot hide behind a silent skip. That
  strictness is what surfaced `buf` naming its linux arm64 build `aarch64`
  while darwin uses `arm64`.
- `tagPrefix` (githubRelease) resolves the newest release whose tag carries
  the prefix instead of `releases/latest`, for repos that interleave several
  tag trains (compound-engineering next to marketplace-*/cli-*).
- `linuxMusl` (githubRelease) locks the distinct static-musl linux builds
  under `-musl` platform keys next to the glibc ones (agent-browser, omp).
- `versionTransform` (githubTag) applies a required tag-shape transform in the
  registry so consumers read the normalized locked version.
- A tool whose binary is not a GitHub asset — `kubectl` from `dl.k8s.io`,
  `helm` from `get.helm.sh` — takes only its tag from the release and carries
  no `asset` selector, so the lock holds a version and no artifacts block.
- `githubSkillCollection` scans the complete commit history for exact
  `Skills v<semver> (#<number>)` subjects, selects the highest semantic
  version, and records its immutable commit plus a sorted inventory of all
  portable immediate `skills/figma-*` trees. Collection entries do not carry
  platform artifacts.
- npm entries record `dist.integrity` as published. It is informational only:
  chezmoi externals verify sha256, so npm entries stay version-only for
  consumers.

## Verification

```sh
vp test            # unit tests, network stubbed
vp run typecheck   # tsc --noEmit
```

The `githubSkillCollection` contract is also verified at its consumers. From
the repository root, the isolated staging and transactional reconciliation
fixtures are:

```sh
.ci/test-figma-skills-stage.sh
.ci/test-figma-skills-reconcile.sh
```

The POSIX entry points run on native Linux and macOS in
`.github/workflows/ci.yml`. They render from the committed lock and operate
only in scratch directories. The `render-dotfiles.yml` Fedora, Ubuntu, and
macOS jobs separately assert the Figma collection external plus both
reconciler templates use the same locked revision and sorted inventory;
scripts and externals remain outside the managed-file archive comparison.
