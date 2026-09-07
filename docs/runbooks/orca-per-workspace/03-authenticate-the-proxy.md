# 03 -- Authenticate the proxy

One procedure, two situations. First bring-up and recovery after losing the
`auth-dir` PVC are the same action, so there is one document rather than a
runbook and a disaster-recovery plan that drift apart. Write it before it is
needed, not during an outage.

## Why there is no backup to restore

The `cliproxyapi-auth` PVC is the only copy of the agent OAuth credentials. That
is a decision: recovery is re-authenticating, which is a procedure that has to
exist and be tested anyway, so a backup would be a second mechanism protecting
against nothing a login does not already fix. Provider refresh tokens also rotate,
so a restored backup can be stale in a way that is harder to diagnose than a
fresh login.

## Reach the management UI

CLIProxyAPI serves the API and the management routes on the same port, 8317. Two
ways in, in order of preference:

**Over the tailnet.** With the Tailscale Operator running, `orca-proxy` is a
tailnet node: `http://orca-proxy:8317/management.html`. The ACL grants the
desktop and denies `tag:orca-workspace`.

**Over a port-forward.** Works with no tailnet material at all, which makes it the
path during a first bring-up:

```sh
kubectl -n cliproxyapi port-forward deploy/cliproxyapi 8317:8317
```

then `http://127.0.0.1:8317/management.html`.

The management key is the `management-secret-key` value from the `cliproxyapi`
Secret:

```sh
kubectl -n cliproxyapi get secret cliproxyapi \
  -o jsonpath='{.data.management-secret-key}' | base64 -d
```

## Log in each agent account

In the panel, add an authentication for each provider account the workers should
use, and complete the provider's OAuth flow. This is interactive by nature -- a
person approves an account they own -- so it is the one step in the whole
platform that is not automated.

If a provider's OAuth flow insists on a `localhost` callback, keep the
port-forward open and run the login from the same desktop: the callback then
lands on the forwarded port and reaches the pod.

Confirm afterwards, in `kubectl -n cliproxyapi logs deploy/cliproxyapi`:

```
server clients and configuration updated: N clients (N auth entries + ...)
```

`0 clients` means nothing is authenticated, and every worker's model call will
fail with no available credential -- the proxy itself stays healthy, which is why
this line is the check that matters.

## The probe that tells you it broke later

`cliproxyapi-auth-probe` is a CronJob that GETs the management API's auth-files
route every 15 minutes and fails the Job when the answer is not a credential
list. It never writes, so it cannot become a second writer to `auth-dir`.

```sh
kubectl -n cliproxyapi get jobs -l batch.kubernetes.io/job-name
kubectl -n cliproxyapi logs job/<failed job>
```

A failing probe means: re-run this document.

## After a PVC loss

Nothing else to do first. Flux recreates the claim, the Deployment starts with an
empty `auth-dir`, and this document is the recovery.
