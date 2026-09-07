# 01 -- Cluster bootstrap

The order below is the procedure that stands a cluster back up, not an
illustration. Secrets come first because Flux must never be the thing that
creates one, and because a component whose Secret is missing is supposed to fail
loudly rather than start with a default.

## 0. What the cluster needs first

- k3s with Flux installed and its controllers ready (`flux check`).
- A `local-path` StorageClass, or any default class that can serve two
  ReadWriteOnce claims.
- Outbound network to `ghcr.io`, `docker.io`, `pkgs.tailscale.com` and
  `1password.github.io`.

This platform does not require a dedicated cluster. Its `GitRepository` is named
`orca-platform` rather than `flux-system` exactly so it can coexist with a Flux
source that is already reconciling something else, and every component lives in
its own namespace.

## 1. Seed the Secrets

Follow [02 The Secret contract](02-secret-contract.md) and stop when every Secret
listed there exists. Nothing below works without them, and the failure modes are
much easier to read when the Secrets are already in place.

## 2. Point Flux at this repository

```sh
kubectl apply -f infra/bootstrap/orca-platform.yaml
```

That is the only imperative apply the platform needs. It creates the
`GitRepository` (branch `main`) and one `Kustomization` for
`infra/clusters/hp-z1-g6-01`, which in turn creates one Kustomization per
component.

For a cluster other than `hp-z1-g6-01`, copy that cluster directory, change the
`path` in the bootstrap file, and commit -- the bootstrap file names the cluster's
directory, so a new cluster is a new directory rather than a patch of this one.

## 3. Verify reconciliation

```sh
kubectl -n flux-system get gitrepository orca-platform
kubectl -n flux-system get kustomization | grep orca
kubectl -n onepassword get pods
kubectl -n cliproxyapi get pods
kubectl -n tailscale get pods
kubectl -n orca-workers get podtemplate,resourcequota,pvc
```

What "healthy" looks like:

- Five Kustomizations Ready: `orca-platform` plus the four components.
- `onepassword-connect` 2/2 Running. If the API container logs
  `failed to Unmarshal credentials file data into map`, the credential Secret
  holds base64 where Connect wants raw JSON -- see the contract document.
- `cliproxyapi` 1/1 Running with `management routes registered after secret key
  configuration` in its log. That line is the proof the management key was
  actually composed into the config by the init container.
- `orca-workers` reports `orca-worker-cache` as **Pending**. That is correct:
  the class is `WaitForFirstConsumer`, so the claim binds when the first worker
  mounts it. This is also why the `orca-workers` Kustomization does not use
  `wait: true`.

## 4. Authenticate the proxy

[03 Authenticate the proxy](03-authenticate-the-proxy.md). Until an agent account
is logged in, CLIProxyAPI serves `0 clients` and every worker's model call fails
with no available credential.

## 5. Give the desktop a scoped identity

The recipe scripts run on the desktop and need to create pods in
`orca-workers`. They deliberately do not use the cluster admin kubeconfig.

```sh
kubectl apply -f - <<'YAML'
apiVersion: v1
kind: Secret
metadata:
  name: orca-workspace-admin-token
  namespace: orca-workers
  annotations:
    kubernetes.io/service-account.name: orca-workspace-admin
type: kubernetes.io/service-account-token
YAML
```

A `kubernetes.io/service-account-token` Secret is used rather than
`kubectl create token` because the latter issues a token that expires, and a
recipe that stops working after an invisible deadline is worse than a long-lived
token scoped to one namespace and six verbs.

Build `~/.kube/orca-platform.yaml` from that Secret's `token` and `ca.crt`, with
the cluster's API address as `server` and `orca-workers` as the context
namespace. That path is what `orca-worker` reads by default; override it with
`ORCA_WORKER_KUBECONFIG`.

Check it:

```sh
KUBECONFIG=~/.kube/orca-platform.yaml kubectl get podtemplate
```

## 6. Prove it end to end

[06 Validation](06-validation.md).
