# 07 -- Second-cluster checklist

A gate, not a footnote. Work through it BEFORE a second cluster runs a second
CLIProxyAPI.

## 1. The token-refresh writer question

Every cluster gets its own proxy instance, and therefore its own writer of the
same provider refresh tokens. Providers that ROTATE a refresh token on use will
invalidate the other cluster's copy, and the symptom is an intermittent 401 in
whichever cluster refreshed second -- which looks like a flaky provider rather
than a design error.

Pick one, and record which:

1. **A separate agent account per cluster.** Simplest, and costs an account.
2. **Verify the providers do not rotate refresh tokens.** Verify, do not assume;
   this changes on the provider's schedule, not yours.
3. **One fleet-wide proxy** reached over the tailnet by every cluster. One writer
   again, at the cost of a cross-cluster dependency and tailnet latency on every
   model call.

Do not skip this check. Sharing an account across two proxies without settling it
is the one failure in this design that corrupts state rather than stopping.

## 2. RWX becomes a real requirement

The shared package cache is `ReadWriteOnce`, and that works only because RWO
binds a volume to one NODE and every worker lands on the only node there is.

A second node -- not even a second cluster -- makes this an RWX requirement, and
RWX here means NFS, Longhorn RWX or similar. Price the alternative first: an
in-cluster pull-through registry proxy (npm, PyPI, crates) delivers most of the
speedup with no shared filesystem and no RWX dependency, at the cost of one more
Flux-managed service. Decide between the two before building either.

## 3. Tailnet names collide

`tailscale.com/hostname: orca-proxy` is fixed in
`infra/platform/cliproxyapi/service-tailnet.yaml`. A second cluster registering
the same name gets a numeric suffix from Tailscale, silently, and then two
clusters answer to names that differ by one character. Give each cluster's proxy
its own hostname in its own cluster directory.

The same applies to the workers' `TS_HOSTNAME`, which is the pod name: pod names
are unique per cluster, not per tailnet.

## 4. One cluster directory per cluster

`infra/clusters/<name>/` is copied, not parameterised. The bootstrap file names
the directory, so a second cluster is a second directory and a second bootstrap
apply -- and each cluster's quota, hostnames and component set stay independently
reviewable.

## 5. Secrets are per cluster

Every Secret in [02](02-secret-contract.md) is seeded again in the new cluster.
The Connect server credential and its tokens are per Connect server; do not copy
one cluster's `op-credentials` into another.
