# Encrypted migration material

This directory contains no plaintext credentials. Each host's age identity and all service tokens, Wi-Fi credentials, printer URIs, SSH private keys, Apple Account credentials, and TLS inspection CAs are encrypted before they enter this repository and are decrypted only on the target machine. Do not add an age private key, GPG private key, PIN, password, or token in plain text.

## Bootstrap age material

Bootstrap material is scoped per host under `secrets/bootstrap/<host>/`, which holds:

- `age-key.asc`: the host's age private key encrypted to the OpenPGP card's encryption subkey (`keys/signing.asc`, fingerprint `621512777E6933FEB4458FDC4945855D4F283F05`).
- `recipient.txt`: that identity's single public `age1...` recipient string.

Every host directory under `hosts/` (`MS-7D91` and `MacBook-Pro-Mac17-9`) has a matching directory under `secrets/bootstrap/`, and every directory here has a matching host; the `bootstrap-recipients` check (`tests/bootstrap-recipients.nix`) fails when either side is missing, when either file is missing, or when the recorded recipient does not appear in `.sops.yaml`. `scripts/prepare-age-identity` creates both files for a new host; do not write either file by hand. See [adding a host](../docs/adding-a-host.md) for the full procedure.

## Recipient layout in `.sops.yaml`

`.sops.yaml` carries one creation rule per encrypted file, listing the age recipients that may decrypt it:

```yaml
creation_rules:
  - path_regex: secrets/tokens\.yaml$
    age: <MS-7D91 recipient>,<MacBook-Pro-Mac17-9 recipient>
  - path_regex: secrets/wifi\.yaml$
    age: <MS-7D91 recipient>
  - path_regex: secrets/tailscale\.yaml$
    age: <MS-7D91 recipient>
  - path_regex: secrets/printers\.yaml$
    age: <MS-7D91 recipient>
  - path_regex: ^secrets/hosts/MS-7D91/ssh\.yaml$
    age: <MS-7D91 recipient>
  - path_regex: ^secrets/hosts/MacBook-Pro-Mac17-9/ssh\.yaml$
    age: <MacBook-Pro-Mac17-9 recipient>
  - path_regex: ^secrets/hosts/MacBook-Pro-Mac17-9/apple-account\.yaml$
    age: <MacBook-Pro-Mac17-9 recipient>
  - path_regex: ^secrets/hosts/MacBook-Pro-Mac17-9/tls-inspection-ca\.yaml$
    age: <MacBook-Pro-Mac17-9 recipient>
```

Only a host whose recipient appears in a file's rule can decrypt that file:

- `secrets/tokens.yaml` is encrypted to both hosts (`MS-7D91` and `MacBook-Pro-Mac17-9`).
- `secrets/wifi.yaml`, `secrets/tailscale.yaml`, and `secrets/printers.yaml` are encrypted to `MS-7D91` only. The `user-identity-secrets` check (`tests/user-identity-secrets.nix`) fails if a macOS (`darwin`) host recipient appears on `secrets/wifi.yaml` or `secrets/tailscale.yaml`, and `printing` (`tests/printing.nix`) checks `secrets/printers.yaml` against hosts that declare `my.printing.queues`.
- Each per-host file under `secrets/hosts/<host>/` is encrypted to `<host>`'s recipient alone.

The `sops-recipients` check (`tests/sops-recipients.nix`) fails when the recipients stored in an encrypted file's SOPS metadata differ from those in its matching `.sops.yaml` creation rule, so a removed recipient cannot linger in ciphertext. Adding a new host's bootstrap material does not by itself grant access to existing files: update `.sops.yaml` and run `sops updatekeys`.

## Shared files

### `secrets/tokens.yaml`

`secrets/tokens.yaml` is a flat YAML mapping of string fields (service usernames are public configuration in `modules/shared/cli-accounts.nix` and are not secret):

```yaml
github_token: <GitHub token>
gitlab_token: <GitLab.com token>
jpi_token: <git.jpi.app token>
docker_token: <Docker Hub token>          # NixOS opt-in: my.cliAuth.enableDockerToken
tokscale_token: <Tokscale API token>      # NixOS opt-in: my.cliAuth.enableTokscaleToken
synthetic_api_key: <Synthetic API key>    # NixOS opt-in: my.cliAuth.enableSyntheticApiKey
exa_api_key: <Exa API key>                # NixOS opt-in: my.cliAuth.enableExaApiKey
openrouter_api_key: <OpenRouter API key>  # NixOS opt-in: my.cliAuth.enableOpenRouterApiKey
```

On NixOS (`modules/nixos/system/secrets.nix`), `github_token`, `gitlab_token`, and `jpi_token` are always decrypted into `/run/secrets/cli-auth/` when `my.cliAuth.enable` is true, and the shared NixOS profile (`modules/nixos/profile.nix`) enables `enableTokscaleToken`, `enableSyntheticApiKey`, `enableExaApiKey`, and `enableOpenRouterApiKey` by default on production outputs.

On macOS (`home/h82/security/non-nixos-secrets.nix` and `scripts/host-secrets`), production activation always decrypts `github_token`, `gitlab_token`, `jpi_token`, `tokscale_token`, `synthetic_api_key`, `exa_api_key`, and `openrouter_api_key` into `~/.local/state/cli-auth/` (and removes any retired key files), failing activation before any symlink changes if any required key is missing or invalid. It never decrypts `docker_token`.

`synthetic_api_key` backs Pi (`home/h82/agents/pi.nix` and `packages/pi.nix`): activation writes the `synthetic` credential in `~/.pi/agent/auth.json` via `pi-state`, and `pi-provider-key` reads the published key file at runtime.

For container pulls through `docker-credential-sops`, `github_token` must carry `read:packages` (or `write:packages`) and `gitlab_token` must carry `read_registry` (or `write_registry`). The public accounts declared in `modules/shared/cli-accounts.nix` are `hyperlapse122` on GitHub and `hyperlapse` on GitLab.com and `git.jpi.app`.

To add or rotate an encrypted token in `secrets/tokens.yaml` without passing plaintext in command arguments, save the value to a mode `0600` file outside the checkout and pipe a JSON string into `sops set --value-stdin` from the repository root:

```sh
nix develop
export SOPS_AGE_KEY_CMD="sh -c 'for f in secrets/bootstrap/*/age-key.asc; do gpg --batch --no-tty --decrypt -- \"\$f\"; done'"
python3 -c 'import json, sys; sys.stdout.write(json.dumps(sys.stdin.read().strip()))' < <token-file> \
  | sops set --value-stdin secrets/tokens.yaml '["<key>"]'
rm <token-file>
unset SOPS_AGE_KEY_CMD
```

### `secrets/wifi.yaml`

`secrets/wifi.yaml` nests one SSID/PSK pair per network label under a top-level `wifi` key (the label is an arbitrary local identifier, never the literal SSID; see `modules/nixos/wifi.nix`), matching `sops-nix`'s `/`-separated key lookup (`sops.secrets."wifi/<label>/ssid"`):

```yaml
wifi:
  <label>:
    ssid: <network SSID>
    psk: <network passphrase>
```

### `secrets/tailscale.yaml`

`secrets/tailscale.yaml` holds `auth_key` for unattended NixOS Tailscale authentication (`modules/nixos/services/tailscale.nix`).

### `secrets/printers.yaml`

`secrets/printers.yaml` nests one device URI and description per CUPS queue label under a top-level `printers` key (`modules/nixos/services/printing.nix`). The label is the queue name a NixOS host lists in `my.printing.queues` (such as `office` on `MS-7D91`), never the printer model:

```yaml
printers:
  <label>:
    uri: <IPP Everywhere device URI>
    info: <description shown in print dialogs>
```

## Per-host files under `secrets/hosts/<host>/`

### `secrets/hosts/<host>/ssh.yaml` and `ssh.pub`

Each host has its own encrypted SSH private key document, `secrets/hosts/<host>/ssh.yaml`, and matching public key file, `secrets/hosts/<host>/ssh.pub`. `ssh.yaml` holds one key, `ssh_private_key`, whose value is the OpenSSH private key as a YAML block scalar:

```yaml
ssh_private_key: |
  -----BEGIN OPENSSH PRIVATE KEY-----
  <key lines>
  -----END OPENSSH PRIVATE KEY-----
```

Its `.sops.yaml` creation rule lists only `<host>`'s recipient.

On NixOS desktops (`MS-7D91`), `modules/nixos/system/desktop-ssh.nix` decrypts `secrets/hosts/MS-7D91/ssh.yaml` to a root-only credential and `desktop-ssh-provision.service` writes a passphrase-protected working copy at `~/.ssh/id_ed25519_nix_config` (`0600` in `~/.ssh` mode `0700`) whose random passphrase is stored in `kdewallet` (folder `nix-config SSH`, keyed by public fingerprint). The `desktop-ssh` check (`tests/desktop-ssh.nix`) verifies recipient isolation, field structure, and public metadata without decrypting real keys. See [desktop SSH source creation](../docs/adding-a-host.md#create-the-desktop-ssh-key-source) and [desktop SSH recovery](../docs/recovery.md#restore-or-rotate-a-desktop-ssh-key).

On macOS (`MacBook-Pro-Mac17-9`), the `user-identity-secrets` check (`tests/user-identity-secrets.nix`) verifies that `secrets/hosts/<host>/ssh.yaml` is encrypted to `<host>`'s recipient alone, and `scripts/host-secrets` publishes the key at `~/.ssh/id_ed25519_nix_config` (`0600`), protected at rest by FileVault. See [adding a host](../docs/adding-a-host.md#create-the-macos-hosts-secrets).

### `secrets/hosts/MacBook-Pro-Mac17-9/apple-account.yaml`

Every macOS host has `secrets/hosts/<host>/apple-account.yaml`, encrypted to that host's recipient alone:

```yaml
username: <Apple Account email>
password: <Apple Account password>
```

During a production switch on macOS (`!config.my.bootstrap`), `modules/darwin/xcode.nix` runs `macos-xcode`, which decrypts `secrets/hosts/<host>/apple-account.yaml` from the applying checkout in memory using `~/.config/nix-config/age/key.txt` and passes `XCODES_USERNAME` and `XCODES_PASSWORD` only in the environment of the `xcodes` child process. Bootstrap switches skip Xcode and never read this file.

### `secrets/hosts/MacBook-Pro-Mac17-9/tls-inspection-ca.yaml`

A macOS host with `my.tlsInspectionCa.enable = true` has `secrets/hosts/<host>/tls-inspection-ca.yaml`, encrypted to that host's recipient alone:

```yaml
certificate: |
  -----BEGIN CERTIFICATE-----
  <certificate lines>
  -----END CERTIFICATE-----
```

The certificate is not a private key, but its subject identifies an internal corporate server, so it stays encrypted in this public repository. See [macOS hosts](../docs/macos.md#tls-inspection-ca).

## Recovering a host's age identity

Each host's bootstrap age identity is encrypted with the OpenPGP encryption subkey from `keys/signing.asc`. `scripts/prepare-age-identity` verifies a round-trip decryption with the card before keeping a newly generated file.

### NixOS (`MS-7D91`)

After installing the bootstrap output, run the recovery helper as your normal user (`h82`) from the repository checkout:

```sh
./scripts/recover-age-identity
```

It resolves `<host>` from `uname -n` (or accepts `--host NAME`) and runs:

```sh
gpg --batch --no-tty --decrypt -- secrets/bootstrap/<host>/age-key.asc \
  | sudo -- /run/current-system/sw/bin/restore-age-identity \
      --recipient "$(cat secrets/bootstrap/<host>/recipient.txt)"
```

`recover-age-identity` refuses to run as root so `gpg` reaches the invoking user's `gpg-agent` and `dotfiles-pinentry`. `restore-age-identity` reads the key from stdin, verifies that it derives the public `--recipient`, and atomically writes `/var/lib/sops-nix/key.txt` (`root:root`, mode `0600`).

### macOS (`MacBook-Pro-Mac17-9`)

A macOS host stores its age identity in the primary user's home directory, protected by FileVault. After applying `<host>-bootstrap`, run the helper in user mode (`--user` requires `--host`):

```sh
./scripts/recover-age-identity --user --host <host>
```

It pipes the `gpg --decrypt` output to `install-user-age-identity --recipient "$(cat secrets/bootstrap/<host>/recipient.txt)"`, without `sudo`. `install-user-age-identity` verifies the derived recipient and atomically writes `~/.config/nix-config/age/key.txt` (owned by the user, mode `0600`, in `~/.config/nix-config/age` with mode `0700`).

## Compromise or decommission

When a host is lost, compromised, or retired, follow [compromise or decommission of a host](../docs/recovery.md#compromise-or-decommission-of-a-host). Removing a recipient without running `sops rotate -i` and reissuing the underlying tokens at their providers revokes nothing, because Git history retains the earlier ciphertext.
