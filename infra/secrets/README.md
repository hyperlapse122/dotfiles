# Secret templates

Every Secret in this cluster is created with the CLI. Flux never creates one and
never carries secret data: the manifests under `../platform/` reference Secrets
by NAME only, so a Secret that was never seeded shows up as a NotReady
Kustomization or HelmRelease instead of a component silently starting with a
default.

These files are `op inject` templates. They hold `op://` references, which are
addresses rather than secrets, and they render to plaintext manifests that MUST
NOT be written into this repository or committed:

```sh
op inject -i infra/secrets/<name>.op.yaml | kubectl apply -f -
```

The rendered manifest goes straight into the pipe. `op inject -o` writes
plaintext to disk and there is no reason to do that here.

On a host where the 1Password CLI cannot be approved non-interactively, seed the
same Secret with `kubectl create secret` instead -- the contract is the Secret's
name and keys, not the tool that creates it. The exact names and keys, and the
seeding order, are in
`docs/runbooks/orca-per-workspace/02-secret-contract.md`.
