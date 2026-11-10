# Encrypted migration material

This directory is deliberately empty of plaintext credentials.  The machine
age identity and the service tokens are created during migration, encrypted
before they enter this repository, and are only decrypted on the target
machine.  Do not add an age private key, GPG private key, PIN, or token in
plain text.

Bootstrap material is scoped per host under
`secrets/bootstrap/<host>/`, which holds `age-key.asc` (the age identity
encrypted to the OpenPGP card's encryption subkey) and `recipient.txt` (that
identity's single public `age1...` recipient).  Every directory under `hosts/`
has a matching directory here, and every directory here has a matching host;
the `bootstrap-recipients` check fails when either side is missing, when
either file is missing, or when the recorded recipient does not appear in
`.sops.yaml`.  `scripts/prepare-age-identity` creates both files for a new
host; do not write either file by hand.  [Adding a host](../docs/adding-a-host.md)
covers the full procedure.

`.sops.yaml` carries one creation rule per encrypted file, each listing every
recipient host that may decrypt it:

```yaml
creation_rules:
  - path_regex: secrets/tokens\.yaml$
    age: <comma-separated recipients of every host that shares this file>
  - path_regex: secrets/wifi\.yaml$
    age: <comma-separated recipients of every host that shares this file>
  - path_regex: secrets/tailscale\.yaml$
    age: <comma-separated recipients of every host that shares this file>
  - path_regex: secrets/printers\.yaml$
    age: <comma-separated recipients of every host that declares a printer queue>
  - path_regex: ^secrets/hosts/<host>/ssh\.yaml$
    age: <that one host's recipient>
  - path_regex: ^secrets/hosts/<host>/tls-inspection-ca\.yaml$
    age: <that one host's recipient>
```

Only a host whose recipient appears in a file's rule can decrypt it.
`secrets/tokens.yaml` lists every host's recipient.  `secrets/wifi.yaml` and
`secrets/tailscale.yaml` list only the NixOS hosts' recipients; the
`linux-host-secrets` check fails when the recipient of a non-NixOS or macOS
host appears in either rule.  Adding a new host's bootstrap material does not by itself give
it access to an existing file: add its recipient to the file's rule and
re-encrypt the file with `sops updatekeys`, or split the rule per host.

The `sops-recipients` check fails when the recipients stored in an encrypted
file differ from those of the `.sops.yaml` rule that matches it, so a removed
recipient cannot linger in a file's ciphertext.

The encrypted token document (`secrets/tokens.yaml`) is a flat YAML mapping
of string fields (the service usernames are public configuration and are not
secret):

```yaml
github_token: <GitHub token>
gitlab_token: <GitLab.com token>
jpi_token: <git.jpi.app token>
docker_token: <Docker Hub token>     # opt-in: my.cliAuth.enableDockerToken
tokscale_token: <Tokscale API token> # opt-in: my.cliAuth.enableTokscaleToken
synthetic_api_key: <Synthetic API key> # opt-in: my.cliAuth.enableSyntheticApiKey
exa_api_key: <Exa API key>            # opt-in: my.cliAuth.enableExaApiKey
openrouter_api_key: <OpenRouter API key> # opt-in: my.cliAuth.enableOpenRouterApiKey
```

The first three are always decrypted when `my.cliAuth` is enabled. The opt-in
keys are decrypted only when their `my.cliAuth` flag is set. sops-nix checks
every decrypted key against this file at build time, so a flag set without its
key fails the build.

For container pulls through `docker-credential-sops`, `github_token` must carry `read:packages` (or `write:packages`) and `gitlab_token` must carry `read_registry` (or `write_registry`). To add or rotate an encrypted token (such as `tokscale_token`, `docker_token`, `synthetic_api_key`, or `openrouter_api_key`) without passing plaintext in command arguments, save it to a mode `0600` file outside the checkout and pipe a JSON string into `sops set --value-stdin` from the repository root:

```sh
nix develop
export SOPS_AGE_KEY_CMD="sh -c 'for f in secrets/bootstrap/*/age-key.asc; do gpg --batch --no-tty --decrypt -- \"\$f\"; done'"
python3 -c 'import json, sys; sys.stdout.write(json.dumps(sys.stdin.read().strip()))' < <token-file> \
  | sops set --value-stdin secrets/tokens.yaml '["<key>"]'
rm <token-file>
unset SOPS_AGE_KEY_CMD
```

`exa_api_key` backs the web search and fetch tools of the Pi extension
(`packages/pi-extension/`). Every host kind publishes it beside
`synthetic_api_key`: a NixOS host at `/run/secrets/cli-auth/exa_api_key`, and a
non-NixOS or macOS host at `~/.local/state/cli-auth/exa_api_key`. The shared
profile turns `my.cliAuth.enableExaApiKey` on by default. The extension reads the
file when a tool runs, so the key never enters Pi's environment or the
environment of the commands its tools run.

`openrouter_api_key` backs Pi's OpenRouter provider. Every host kind publishes
it beside `synthetic_api_key`: a NixOS host at
`/run/secrets/cli-auth/openrouter_api_key`, and a non-NixOS or macOS host at
`~/.local/state/cli-auth/openrouter_api_key`. The shared profile turns
`my.cliAuth.enableOpenRouterApiKey` on by default.

A non-NixOS host, like a macOS host, has no `my.cliAuth` options. Its production apply always
decrypts `github_token`, `gitlab_token`, `jpi_token`, `tokscale_token`,
`synthetic_api_key`, `exa_api_key`, and `openrouter_api_key`, and stops when any of them is missing. It never decrypts `docker_token`.

The intended public accounts are `hyperlapse122` on GitHub and `hyperlapse` on
GitLab.com and `git.jpi.app`.

The encrypted Wi-Fi document (`secrets/wifi.yaml`) nests one SSID/PSK pair per
network label under a top-level `wifi` key (the label is an arbitrary local
name, never the literal SSID — see `modules/nixos/wifi.nix`), matching
sops-nix's `/`-separated key lookup (`sops.secrets."wifi/<label>/ssid"`):

```yaml
wifi:
  <label>:
    ssid: <network SSID>
    psk: <network passphrase>
```

The encrypted printer document (`secrets/printers.yaml`) nests one device URI
and description per queue label under a top-level `printers` key.  The label
is the CUPS queue name a host lists in `my.printing.queues`, an arbitrary local
name, never the printer model; sops encrypts values, not keys.  Its rule lists
only the recipients of hosts that declare a queue (see
`modules/nixos/services/printing.nix`):

```yaml
printers:
  <label>:
    uri: <IPP Everywhere device URI>
    info: <description shown in print dialogs>
```

Each host has its own encrypted SSH key document,
`secrets/hosts/<host>/ssh.yaml`.  It holds one key, `ssh_private_key`, whose
value is the OpenSSH private key as a YAML block scalar:

```yaml
ssh_private_key: |
  -----BEGIN OPENSSH PRIVATE KEY-----
  <key lines>
  -----END OPENSSH PRIVATE KEY-----
```

Its `.sops.yaml` rule lists that host's recipient and no other. A leaked host
age identity cannot decrypt another host's SSH source, but the shared recovery
cards can recover every host identity. Removing recipients does not revoke
keys exposed through historical ciphertext; revoke public SSH keys on their
destinations when a host is compromised.

A macOS host with the `my.tlsInspectionCa` trait has an encrypted
`secrets/hosts/<host>/tls-inspection-ca.yaml`, encrypted to that host's
recipient alone.  It holds one key, `certificate`, whose value is the PEM
certificate of the CA its endpoint protection re-signs TLS with:

```yaml
certificate: |
  -----BEGIN CERTIFICATE-----
  <certificate lines>
  -----END CERTIFICATE-----
```

The certificate is not secret, but its subject names an internal server, so
it stays out of this public repository in plain text.
[macOS hosts](../docs/macos.md#tls-inspection-ca) covers adding and replacing it.

For NixOS desktops, `secrets/hosts/<host>/ssh.pub` holds the matching public
Ed25519 identity. The `desktop-ssh` check reads ciphertext recipients,
checks the encrypted field and creation rule, and rejects missing, invalid,
or duplicate public metadata without decrypting real keys. SOPS keeps the
decrypted recovery source root-only. The fixed `desktop-ssh-provision.service`
receives it through systemd credentials only in the configured user's active
local graphical session. It publishes a passphrase-protected working key at
`~/.ssh/id_ed25519_nix_config` with mode 0600 in a 0700 directory. The random
passphrase lives in `kdewallet`, folder `nix-config SSH`, under the public
fingerprint; it never enters Nix expressions or command arguments. Builds and
ordinary configuration applies do not need an unlocked wallet. See
[desktop source creation](../docs/adding-a-host.md#create-the-desktop-ssh-key-source)
and [desktop SSH recovery](../docs/recovery.md#restore-or-rotate-a-desktop-ssh-key).

For non-NixOS hosts and macOS hosts, the `linux-host-secrets` check reads the recipients from
the encrypted file itself and fails when it lists any other. Production
activation publishes the passphrase-free key at `~/.ssh/id_ed25519_nix_config`
with mode 0600, protected by the distribution's disk encryption, or by FileVault
on a macOS host.
[Adding a host](../docs/adding-a-host.md#create-the-host-ssh-key-file) shows how
to generate and encrypt it. This desktop migration does not change that path.

Keep each encrypted document at its path above; do not pass SSID, PSK, or
token values as command arguments or print decrypted output when populating
either file. Each host's bootstrap age identity is encrypted with the
public OpenPGP encryption subkey from `keys/signing.asc`.  Verify that it
decrypts with the real card before installing NixOS;
`scripts/prepare-age-identity` enforces that round trip as it writes the file
and refuses to keep a ciphertext it cannot open again.

To restore the identity after installation, run the recovery helper from the
clone.  It resolves the running host, or takes `--host NAME`:

```sh
./scripts/recover-age-identity
```

It runs exactly the pipeline below with the paths resolved for that host,
decrypting as the normal user and crossing sudo exactly once into the fixed
root installer:

```sh
gpg --batch --no-tty --decrypt -- secrets/bootstrap/<host>/age-key.asc \
  | sudo -- /run/current-system/sw/bin/restore-age-identity \
      --recipient "$(cat secrets/bootstrap/<host>/recipient.txt)"
```

The helper refuses to run as root, because GPG has to reach the invoking
user's own agent and card pinentry.

GPG runs as the invoking user and uses that user's `gpg-agent` and card
pinentry. The fixed root installer accepts only stdin and the public
`--recipient` argument. It validates the derived age recipient before it
atomically replaces `/var/lib/sops-nix/key.txt` (root:root, mode 0600). The
temporary plaintext exists only briefly on the encrypted runtime filesystem;
it is never put in the Nix store, argv, or logs. The recipient is public, so
passing it as an argument is safe; the age identity itself remains on stdin.

A non-NixOS host keeps its identity in the user's home instead.  Run the
helper in user mode, which requires `--host` because the distribution owns
the hostname:

```sh
./scripts/recover-age-identity --user --host <host>
```

It pipes the decrypted identity to `install-user-age-identity`, which the
bootstrap output puts on `PATH`, instead of crossing sudo.  The installer
checks the same public recipient, then atomically replaces
`~/.config/nix-config/age/key.txt`, owned by the user with mode 0600, in a
0700 directory.  Production applies decrypt with that file and need no card.
Its protection rests on the distribution's disk encryption.  A macOS host
recovers and keeps its identity the same way, and there FileVault is the disk
encryption that protects it.

When a host is lost, compromised, or retired, follow
[compromise or decommission of a host](../docs/recovery.md#compromise-or-decommission-of-a-host).
Removing its recipient without rotating every token in `secrets/tokens.yaml`
revokes nothing, because git history keeps the old ciphertext.  A retired NixOS
host also appears in `secrets/wifi.yaml`, `secrets/tailscale.yaml`, and
`secrets/printers.yaml`, so those values need the same treatment.  Remove the recipient and rotate the
file's data key before writing the new values, or the new values are still
encrypted to the removed host.
