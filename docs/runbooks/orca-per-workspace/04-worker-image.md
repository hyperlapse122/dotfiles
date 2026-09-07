# 04 -- Worker image

The image is built from `container/` and published to
`ghcr.io/hyperlapse122/dotfiles/orca-worker`. It is public on purpose: this
repository is public, the render gates prove no resolved secret reaches a layer,
and a public image spares the platform an `imagePullSecrets` Secret and the PAT
lifecycle behind it. What it does publish is the toolchain inventory and its
versions, which are not secrets but are visible.

## What builds it

`.github/workflows/publish-worker-image.yml`, on a push to `main` that touches
`container/`, the chezmoi data, externals, templates, `.chezmoiignore`,
`.chezmoi.toml.tmpl` or `.install-prerequisites.sh`. A pull request builds without
pushing, so a Containerfile that cannot build is caught before merge.

The secret gate runs FIRST and the push depends on it. That ordering is the point:
a published image is public and permanent, so "no credential in a layer" is
decided before anything leaves the runner.

Two tags are pushed: the commit SHA and `latest`. There is no semantic version --
the image has no release cadence of its own.

## Building it by hand

The image CLONES this repository rather than copying the checkout, so the build
must be told which ref. The Containerfile defaults to `main`.

```sh
podman build --file container/Containerfile \
  --build-arg DOTFILES_REF="$(git branch --show-current)" \
  --tag ghcr.io/hyperlapse122/dotfiles/orca-worker:latest .
podman push ghcr.io/hyperlapse122/dotfiles/orca-worker:latest
```

`container/entrypoint.sh` is COPYed from the build context, not cloned, so an
entrypoint change is testable in a local build before it is committed. Everything
else comes from the clone at `DOTFILES_REF`.

## How a rebuild propagates

The PodTemplate references `:latest` with `imagePullPolicy: Always`, so a new
image reaches the next worker created -- no Flux change, no rollout. Running
workers keep the image they started with, which is what you want: a workspace's
toolchain must not change under it mid-task.

To pin instead, replace the tag in
`infra/platform/orca-workers/podtemplate.yaml` with the digest the publish job
prints. Pinning trades automatic propagation for reproducibility; the choice is a
commit either way.

The first pull of this image on a fresh node takes minutes. A worker whose
readiness probe is still failing during that window is not broken -- the probe's
`failureThreshold` is sized for it.

## What the entrypoint does at pod start, and why it can fail

In order: refuse to start without `OP_CONNECT_HOST`/`OP_CONNECT_TOKEN`, state the
container fact, generate per-pod SSH host keys, run `chezmoi apply` against
Connect, fetch `authorized_keys`, resolve the proxy credential into
`/etc/profile.d`, then become `sshd`.

| Symptom in the worker log | Cause |
|---|---|
| `the platform did not supply: OP_CONNECT_TOKEN` | the `orca-worker-connect` Secret is missing or its key is not `token` |
| `sudo: a terminal is required to read the password` | the container marker is absent, so the apply thinks it is on a host. Fixed in the entrypoint; an old image predates the fix |
| `authorized_keys came back empty` | `WORKER_SSH_PUBKEY_REF` points at an item or field the worker token cannot reach |
| `the proxy credential came back empty` | the `orca-worker-proxy` Secret holds an empty `api-key`, or `ANTHROPIC_AUTH_TOKEN_REF` points at an item the worker token cannot reach |

All four are the image refusing to start half-configured, which is the design:
the alternative is a worker that starts and fails later, far from the cause.
