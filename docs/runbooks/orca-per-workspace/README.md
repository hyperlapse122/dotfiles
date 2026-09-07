# Orca per-workspace environments -- runbooks

The platform is in `infra/`, the worker image in `container/`, and the recipe
lifecycle in the `orca-worker` command. Two things about it are deliberately not
discoverable from any of those: Secrets are seeded by hand, and recovering the
proxy's credentials is a manual re-authentication. Both are decisions rather than
gaps, so they are written down here -- otherwise the design is not reproducible.

Read in order for a cluster rebuild:

| | |
|---|---|
| [01 Cluster bootstrap](01-cluster-bootstrap.md) | seed Secrets, point Flux at this repository, verify |
| [02 The Secret contract](02-secret-contract.md) | every Secret name and key the manifests reference |
| [03 Authenticate the proxy](03-authenticate-the-proxy.md) | first bring-up and `auth-dir` loss are the same procedure |
| [04 Worker image](04-worker-image.md) | build, publish, and how a rebuild propagates |
| [05 Adding a project](05-adding-a-project.md) | the `orca.yaml` entry and the primary-checkout rule |
| [06 Validation](06-validation.md) | doctor dry run, then the `--provision` self-test |
| [07 Second-cluster checklist](07-second-cluster-checklist.md) | the gate to pass before a second proxy exists |
| [08 Vault and token scoping](08-vault-and-token-scoping.md) | which vaults the worker token may reach |

## The shape in one paragraph

Flux reconciles `infra/` from this public repository into a single-node k3s
cluster. It runs the Tailscale Operator, 1Password Connect, CLIProxyAPI, and a
worker namespace holding a `PodTemplate`. Agent OAuth lives only in CLIProxyAPI;
a worker receives a base URL and a proxy API key. A worker resolves project
`op://` references at runtime through Connect with a vault-scoped token. Workspace
pods are created imperatively by the `orca-worker` command from that PodTemplate,
and Orca attaches over SSH.
