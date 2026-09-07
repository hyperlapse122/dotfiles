# 06 -- Validation

Two stages, cheap first.

## Dry run -- static wiring

```sh
orca vm recipe doctor <recipe-id> --repo-path <repo> --json
```

Free and non-destructive. It checks that the recipe id exists, that the
create/suspend/resume/destroy command paths resolve, that suspend and resume are
paired, and that each script carries the exec bit.

Its verdict is `ok` when nothing FAILS, so warnings do not stop it. Read them
anyway: a warning about a non-`./`-relative command means that command was never
checked for existence at all.

## Live self-test -- the loop that actually proves it

```sh
orca vm recipe doctor <recipe-id> --repo-path <repo> --provision --json
```

This runs `create`, validates the returned JSON against Orca's schema, then runs
`destroy`. On failure the result carries a `provisionTranscript` with each
stage's complete output, which is enough to diagnose without reading cluster logs
first.

The recipe result Orca accepts is strict. The `ssh` target rejects unknown keys,
so `create` cannot pad the object:

```json
{
  "schemaVersion": 1,
  "connection": {
    "type": "ssh",
    "projectRoot": "/home/worker/workspace",
    "target": {
      "label": "orca-<recipe>-<instance>",
      "host": "<MagicDNS name or node address>",
      "port": 22,
      "username": "worker",
      "identityAgent": "~/.1password/agent.sock"
    }
  },
  "userData": { "provider": "k3s", "resourceId": "<pod name>" }
}
```

## Checking the platform by hand

```sh
export KUBECONFIG=~/.kube/orca-platform.yaml

# create a worker exactly as Orca would
ORCA_RECIPE_ID=selftest ORCA_VM_INSTANCE_ID=$(date +%s) orca-worker create | tee /tmp/worker.json

# log in the way the workspace will
host=$(jq -r .connection.target.host /tmp/worker.json)
port=$(jq -r .connection.target.port /tmp/worker.json)
ssh -p "$port" "worker@$host" 'mise --version; claude --version; op --version'

# the model path, end to end
ssh -p "$port" "worker@$host" \
  'curl -sS -o /dev/null -w "%{http_code}\n" -H "x-api-key: $ANTHROPIC_AUTH_TOKEN" \
     -H "anthropic-version: 2023-06-01" "$ANTHROPIC_BASE_URL/v1/models"'

# and tear it down through the same path Orca uses
jq -n --arg id "$(jq -r .userData.resourceId /tmp/worker.json)" \
  '{recipeResult:{userData:{resourceId:$id}}}' | orca-worker destroy
```

A `200` from the models call proves the whole chain: the worker resolved the
proxy key through Connect, reached CLIProxyAPI by ClusterIP, and the proxy
accepted the key. A `401` means the `worker-api-key` Secret and the 1Password
item have drifted apart. A `503` means the proxy has no authenticated agent
account -- run [03](03-authenticate-the-proxy.md).

## What "healthy platform" looks like

```sh
kubectl -n flux-system get kustomization | grep orca
kubectl -n cliproxyapi logs deploy/cliproxyapi | grep 'clients and configuration updated'
kubectl -n orca-workers get resourcequota orca-workers
```

`orca-tailscale-operator` is the one component allowed to be NotReady on a
cluster whose tailnet material has not been seeded, and workers then use node
addressing. Everything else NotReady is a real failure.
