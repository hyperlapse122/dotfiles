# infra -- the k3s platform for Orca per-workspace environments

Repository-only tree, like `./system` and `./container`. `.chezmoiignore`
excludes it, so nothing here is ever linked into `$HOME`.

Flux reconciles this path from the public GitHub repository. That is only
possible because the tree carries no secrets: every Secret is seeded once with
the CLI and referenced here by name. The trade-off is deliberate and worth
stating plainly -- a public repository publishes cluster topology, service names
and tailnet names. Those are not secrets, but they are public.

```
infra/
  bootstrap/        the one file applied by hand: GitRepository + Kustomization
  clusters/
    hp-z1-g6-01/    what this cluster runs: namespaces + one Kustomization per component
  platform/
    tailscale-operator/    HelmRelease; puts the proxy Service on the tailnet
    onepassword-connect/   HelmRelease; runtime `op://` resolution for workers
    cliproxyapi/           the model proxy: the only holder of agent OAuth
    orca-workers/          namespace RBAC, quota, shared cache, worker PodTemplate
  secrets/          `op inject` templates -- references only, never values
```

## What is deliberately absent

- **No rotation CronJob.** CLIProxyAPI refreshes its own provider tokens.
- **No worker NetworkPolicy.** Workers hold no agent OAuth, and egress limits
  break ordinary development, which is the entire job of a worker.
- **No SOPS.** Hand-seeding keeps ciphertext out of a public repository. The cost
  is one manual step during a cluster rebuild, which the runbook documents.
- **No 1Password Operator.** Connect exists for runtime `op://` resolution only;
  cluster Secrets are seeded by CLI, so a second automated Secret writer would
  only add drift.

## Deploying

Read `docs/runbooks/orca-per-workspace/`. Bootstrap order is: seed the Secrets,
apply `infra/bootstrap/orca-platform.yaml`, verify reconciliation, then
authenticate the proxy.
