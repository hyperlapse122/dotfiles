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

Verified against CPA Manager Plus v1.12.10 and CLIProxyAPI v7.2.152.

Open **OAuth Login** in the panel. It offers Codex, Anthropic, Antigravity
(Google), Kimi and xAI, plus a Vertex service-account import. Start the one whose
account the workers should use -- `ANTHROPIC_BASE_URL` points the workers at this
proxy, so Anthropic is the one that makes `claude` work.

Starting a login does three things: it prints an **Authorization URL**, opens it
in a new tab, and begins waiting with a **Callback URL** box underneath. That box
is the important part, and it is what makes this work from a browser that is not
on the proxy's own host:

1. Sign in and approve the consent screen in the opened tab. This is the step
   that needs a person -- it authenticates a human's own account.
2. The provider then redirects to `http://localhost:<port>/callback?code=...`.
   That port is inside the POD, so the browser shows a connection error. This is
   expected, and the URL in the address bar is the result.
3. Copy that whole failed URL into **Callback URL** and press
   **Submit Callback URL**.

`Copy Link` is there for the case where the sign-in has to happen in another
browser or on another machine entirely; the callback URL still comes back to
this box.


In the panel, add an authentication for each provider account the workers should
use, and complete the provider's OAuth flow. This is interactive by nature -- a
person approves an account they own -- so it is the one step in the whole
platform that is not automated.

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
