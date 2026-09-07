# 02 -- The Secret contract

Flux never creates a Secret and never carries secret data. Every manifest in
`infra/platform/` references a Secret by name only -- `secretKeyRef`,
`existingSecret`, a chart's `credentialsName`. So this document is the contract
between the manual seeding step and the manifests: get a name or a key wrong and
the component does not start, which is the intended behaviour.

Templates carrying the `op://` references live in `infra/secrets/`. They hold
addresses, not values, which is why they are committable.

```sh
op inject -i infra/secrets/<name>.op.yaml | kubectl apply -f -
```

Pipe the render; never `op inject -o` to a file. On a host where the 1Password
CLI cannot be approved non-interactively, create the same Secret with
`kubectl create secret` instead -- the contract is the name and the keys, not the
tool.

## The six Secrets

| Secret | Namespace | Keys | Consumed by |
|---|---|---|---|
| `operator-oauth` | `tailscale` | `client_id`, `client_secret` | Tailscale Operator Deployment (mounted by name; the chart templates it only when the values carry the client, and they deliberately do not) |
| `op-credentials` | `onepassword` | `1password-credentials.json` | Connect chart `connect.credentialsName` |
| `cliproxyapi` | `cliproxyapi` | `worker-api-key`, `management-secret-key` | the `render-config` init container, and the auth-probe CronJob |
| `orca-worker-connect` | `orca-workers` | `token` | worker pod `OP_CONNECT_TOKEN` |
| `orca-worker-proxy` | `orca-workers` | `api-key` | worker pod `ANTHROPIC_AUTH_TOKEN` |
| `orca-worker-tailscale` | `orca-workers` | `TS_AUTHKEY` | worker tailscale sidecar |

### `op-credentials` -- raw JSON, not base64

Verified against Connect 1.8.2. It unmarshals this key directly:

```sh
kubectl -n onepassword create secret generic op-credentials \
  --from-file=1password-credentials.json=./1password-credentials.json
```

Base64 is what the 1Password **operator** expects, and this platform does not run
the operator. Seeding base64 here produces exactly one symptom, in the
`connect-api` and `connect-sync` logs, and it names no cause:

```
failed to Unmarshal credentials file data into map: invalid character 'e' looking for beginning of value
```

The `'e'` is the first character of a base64 body.

1Password issues `1password-credentials.json` once, when the Connect server is
created, and it cannot be retrieved again. Store it in the vault as a document at
the same time; losing it means creating a new Connect server and re-issuing every
token.

### `orca-worker-connect` -- the scoped token

The token 1Password issues alongside the Connect server. It is the only
1Password credential an agent-controlled pod ever holds, and its vault scope is
the whole boundary -- see [08 Vault and token scoping](08-vault-and-token-scoping.md).

```sh
kubectl -n orca-workers create secret generic orca-worker-connect \
  --from-literal=token="$(cat ./1password-token.txt)"
```

To read a token's scope without trusting a label, decode its JWT payload: the
`1password.com/vts` claim lists the vault UUIDs it can reach.

### `cliproxyapi` -- two generated values

Neither exists anywhere else first; generate them, then store them:

```sh
worker_api_key=$(openssl rand -hex 32)
management_secret_key=$(openssl rand -hex 32)
kubectl -n cliproxyapi create secret generic cliproxyapi \
  --from-literal=worker-api-key="$worker_api_key" \
  --from-literal=management-secret-key="$management_secret_key"
```

`worker-api-key` needs a second home, because Secrets are namespace-scoped and
the worker is in another namespace. Same value, no second credential:

```sh
kubectl -n orca-workers create secret generic orca-worker-proxy \
  --from-literal=api-key="$worker_api_key"
```

Rotate them together. A value changed in one namespace only means every worker
gets a 401 from the proxy at its first model call.

1Password holds neither of these. The cluster issues them, so a vault copy would
be a second thing to rotate in step with the first and nothing else. The worker
image still accepts `ANTHROPIC_AUTH_TOKEN_REF` for a platform that would rather
keep the value in a vault; this one does not.

Store `management-secret-key` where the operator can find it -- the infrastructure
vault, which the worker token must not reach. CLIProxyAPI hashes it on startup,
so the plaintext exists only in this Secret and wherever you put it.

### `orca-worker-tailscale` -- optional, and what it switches on

An ephemeral, reusable auth key tagged `tag:orca-workspace`. Ephemeral is what
makes a deleted worker's node disappear instead of accumulating; reusable is what
lets more than one workspace exist at once.

This is the one Secret whose absence is not an error. The PodTemplate marks it
`optional`, and `orca-worker` picks its addressing from whether the worker's
sidecar actually registers a tailnet node: registered means MagicDNS, and no node
within 45 seconds means a per-pod NodePort on the cluster node. Seeding it later
promotes the platform to the tailnet path with no manifest change.

The test is deliberately behavioural. Asking whether this Secret exists is the
obvious check and the wrong one: the workspace identity cannot read Secrets, so
that question always answers "no" and quietly downgrades a tailnet-capable
cluster.

### `operator-oauth` -- a console step, and the one thing a CLI cannot mint

An OAuth client with `devices` and `auth_keys` write scopes, owning
`tag:orca-proxy`. It is created in the Tailscale admin console; there is no API
path to create the first one, because creating it is what gives you API access in
the first place.

The tailnet policy needs the tags before any key or client can use them:

```jsonc
"tagOwners": {
  "tag:orca-proxy":     ["autogroup:admin"],
  "tag:orca-workspace": ["autogroup:admin"],
  "tag:k8s-operator":   ["autogroup:admin"],
  "tag:k8s":            ["tag:k8s-operator"],
},
```

Authentication into a worker is public-key over `sshd`, not Tailscale SSH, so the
policy needs an ordinary `acls`/`grants` rule from the desktop to
`tag:orca-workspace` on port 22 -- not an `ssh` block. Keeping the permissive
member rule (`{"action":"accept","src":["autogroup:member"],"dst":["*:*"]}`) is
enough for that, and it denies `tag:orca-workspace` to `tag:orca-proxy` for free:
a tagged node is not a member, so nothing grants it that path. Workers reach the
proxy by ClusterIP, so they lose nothing.

Until this Secret exists, the `orca-tailscale-operator` Kustomization stays
NotReady and its Pod stays `ContainerCreating` on the missing volume. That is the
designed signal, not a broken cluster: every other component reconciles
independently.

## Rotation

Each of these is replaced by seeding the Secret again and restarting the
consumer. Three have a second copy that must move at the same time:

- `worker-api-key`: the `cliproxyapi` Secret AND `orca-worker-proxy`. Change one
  only and every worker gets a 401 from the proxy at first model call.
- `op-credentials` and `orca-worker-connect`: both come from the same Connect
  server. Re-creating the server invalidates every token it issued.
- `operator-oauth`: revoking the client makes the operator unable to mint proxy
  auth keys; existing proxy nodes keep running until they need re-auth.
