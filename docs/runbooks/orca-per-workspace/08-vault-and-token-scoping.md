# 08 -- Vault and token scoping

The worker's Connect token is the only 1Password credential an agent-controlled
pod holds, so the vaults that token can reach ARE the blast radius of a worker.
This document is the boundary.

## The rule

A worker needs exactly two project secrets -- Context7 and Exa -- plus its own SSH
public key. The proxy API key does not come from 1Password at all: the cluster
issues it and hands it to the pod from its own Secret. Everything else is out.

| Category | Vault | Worker token |
|---|---|---|
| Agent keys: Context7, Exa, the SSH public key | agents vault | **reachable** |
| Host material: GPG, Wi-Fi, LUKS, Google OAuth, registry PATs | host vault | not reachable |
| Infrastructure: CLIProxyAPI OAuth and management key, Tailscale, the Connect credential | infrastructure vault | not reachable |
| `platform-break-glass` | its own vault | **never**, under any circumstance |

One vault is still too broad if it mixes those categories: separate host-only
material from the agent keys even when both belong to the same person.

## Checking a token instead of trusting a label

A Connect token is a JWT. Its `1password.com/vts` claim lists the vault UUIDs it
can reach, so the scope is verifiable without asking anyone:

```sh
python3 - <<'PY'
import base64, json, sys
tok = open('1password-token.txt').read().strip()
payload = tok.split('.')[1]
payload += '=' * (-len(payload) % 4)
claims = json.loads(base64.urlsafe_b64decode(payload))
print(json.dumps({'vaults': claims['1password.com/vts']}, indent=1))
PY
```

Cross-check each UUID against the vault list. A token that reaches a vault not in
the "reachable" row above is over-scoped: issue a narrower one and re-seed
`orca-worker-connect`.

Read access is also not write access. A read-only token returns

```
403 token does not have permission to perform create on vault <uuid>
```

for any write, which is the right posture for a worker: it consumes references,
it does not author items.

## Why Connect rather than a service account token

- A Connect token is useless outside the cluster that hosts its Connect server.
- Its scope is per vault, and verifiable from the token itself.
- It is revoked centrally, without touching a worker or an image.

## What runs against it

Every executable path in this user's projects uses only `op inject` and `op run`
(`mcbx-kr/reepie/mise.toml`, `examvue-365-flow/telerad-frontend/mise.toml`,
`platform-gitops/tools/registry-cleanup/index.mjs`). Both are supported by
Connect, so nothing breaks. `op inject` on a workstation needs 1Password desktop
approval; through Connect it does not, so those `mise` tasks run better in a
worker than on the host.

## Where a vault reference is named

References are addresses, not secrets, and they appear in exactly two places:

- `infra/platform/orca-workers/podtemplate.yaml`: `WORKER_SSH_PUBKEY_REF`.
- `infra/secrets/*.op.yaml`: the seeding templates.

Both are committed on purpose. Moving an item between vaults means editing them.
