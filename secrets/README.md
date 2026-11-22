# Encrypted migration material

This directory contains no plaintext credentials. Each host's age identity and all service tokens, Wi-Fi credentials, printer URIs, SSH private keys, Apple Account credentials, and TLS inspection CAs are encrypted before they enter this repository and are decrypted on the target machine or by the owner during SOPS maintenance. Do not add an age private key, GPG private key, PIN, password, or token in plain text.

## Bootstrap age material

Bootstrap material is scoped per host under `secrets/bootstrap/<host>/`, which holds:

- `age-key.asc`: the host's age private key encrypted to the OpenPGP card's encryption subkey (`keys/signing.asc`, fingerprint `621512777E6933FEB4458FDC4945855D4F283F05`).
- `recipient.txt`: that identity's single public `age1...` recipient string.

Every host directory under `hosts/` (`MS-7D91` and `MacBook-Pro-Mac17-9`) has a matching directory under `secrets/bootstrap/`, and every directory here has a matching host; the `bootstrap-recipients` check (`tests/bootstrap-recipients.nix`) fails when either side is missing, when either file is missing, or when the recorded recipient does not appear in `.sops.yaml`. `scripts/prepare-age-identity` creates both files for a new host; do not write either file by hand. See [adding a host](../docs/adding-a-host.md) for the full procedure.

## Recipient layout in `.sops.yaml`

`.sops.yaml` carries one creation rule per encrypted file, listing the age recipients that may decrypt it:

```yaml
creation_rules:
  - path_regex: ^secrets/git-hosting\.yaml$
    age: <MS-7D91 recipient>,<MacBook-Pro-Mac17-9 recipient>
  - path_regex: ^secrets/provider-services\.yaml$
    age: <MS-7D91 recipient>,<MacBook-Pro-Mac17-9 recipient>
  - path_regex: secrets/wifi\.yaml$
    age: <MS-7D91 recipient>
  - path_regex: secrets/tailscale\.yaml$
    age: <MS-7D91 recipient>
  - path_regex: secrets/printers\.yaml$
    age: <MS-7D91 recipient>
  - path_regex: ^secrets/hosts/MS-7D91/ssh\.yaml$
    age: <MS-7D91 recipient>
  - path_regex: ^secrets/hosts/MS-7D91/wired-network\.yaml$
    age: <MS-7D91 recipient>
  - path_regex: ^secrets/hosts/MacBook-Pro-Mac17-9/ssh\.yaml$
    age: <MacBook-Pro-Mac17-9 recipient>
  - path_regex: ^secrets/hosts/MacBook-Pro-Mac17-9/apple-account\.yaml$
    age: <MacBook-Pro-Mac17-9 recipient>
  - path_regex: ^secrets/hosts/MacBook-Pro-Mac17-9/tls-inspection-ca\.yaml$
    age: <MacBook-Pro-Mac17-9 recipient>
  - path_regex: ^secrets/hosts/MacBook-Pro-Mac17-9/wired-network\.yaml$
    age: <MacBook-Pro-Mac17-9 recipient>
```

Only a host whose recipient appears in a file's rule can decrypt that file:

- `secrets/git-hosting.yaml` and `secrets/provider-services.yaml` are encrypted to both hosts (`MS-7D91` and `MacBook-Pro-Mac17-9`). The legacy `secrets/tokens.yaml` rule has the same recipients for rollback.
- `secrets/wifi.yaml`, `secrets/tailscale.yaml`, and `secrets/printers.yaml` are encrypted to `MS-7D91` only. The `user-identity-secrets` check (`tests/user-identity-secrets.nix`) fails if a macOS (`darwin`) host recipient appears on `secrets/wifi.yaml` or `secrets/tailscale.yaml`, and `printing` (`tests/printing.nix`) checks `secrets/printers.yaml` against hosts that declare `my.printing.queues`.
- Each per-host file under `secrets/hosts/<host>/` is encrypted to `<host>`'s recipient alone.

The `sops-recipients` check (`tests/sops-recipients.nix`) fails when the recipients stored in an encrypted file's SOPS metadata differ from those in its matching `.sops.yaml` creation rule, so a removed recipient cannot linger in ciphertext. Adding a new host's bootstrap material does not by itself grant access to existing files: update `.sops.yaml` and run `sops updatekeys`.

## Shared files

### Shared CLI credentials

The [credential manifest](../modules/shared/cli-credentials.json) maps each
field to its encrypted file and sets the platform publication rules. Each
file is a flat YAML map of strings.

| Encrypted file | Field | Consumer |
| --- | --- | --- |
| `git-hosting.yaml` | `github_token` | GitHub CLI and registry credential helper |
| `git-hosting.yaml` | `gitlab_token`, `jpi_token` | GitLab CLI and registry credential helper |
| `provider-services.yaml` | `docker_token` | Docker Hub registry helper, NixOS opt-in |
| `provider-services.yaml` | `tokscale_token` | Tokscale wrapper |
| `provider-services.yaml` | `synthetic_api_key`, `openai_api_key`, `anthropic_api_key` | Pi and OpenCode |
| `provider-services.yaml` | `exa_api_key`, `openrouter_api_key` | Pi |
| `provider-services.yaml` | `opencode_go_api_key` | OpenCode |

NixOS uses sops-nix to publish enabled fields to `/run/secrets/cli-auth/<field>`
and writes the user-owned, writable gh and glab configuration after decryption.
The production profile enables every field except `docker_token`. Darwin
stages the same fields before Home Manager changes links, then publishes them
to `~/.local/state/cli-auth/<field>` and writes the gh and glab configuration
after link generation. Darwin skips `docker_token`.

`pi-state` and `opencode-auth-sync` read the published provider keys. The
scheduled catalog job still needs the `OPENAI_API_KEY` and `ANTHROPIC_API_KEY`
Actions secrets. For registry pulls, `github_token` needs `read:packages` or
`write:packages`, and `gitlab_token` needs `read_registry` or `write_registry`.
Public usernames live in [cli-accounts.nix](../modules/shared/cli-accounts.nix).

#### Rotate or add a CLI credential

Run SOPS maintenance from the repository root as the owner. On either
platform, load the pinned tools with
`nix shell --inputs-from . nixpkgs#sops nixpkgs#yq-go nixpkgs#python3 nixpkgs#gnupg`.
With the YubiKey connected, set the key command in the maintenance shell.

```sh
export SOPS_AGE_KEY_CMD="sh -c 'for f in secrets/bootstrap/*/age-key.asc; do gpg --batch --no-tty --decrypt -- \"\$f\"; done'"
```

Use the manifest to select the file and field. For example, paste a rotated
OpenAI key at the terminal prompt. The value goes to SOPS through the pipe.

```sh
set -o pipefail
python3 -c 'import getpass, json, warnings; warnings.simplefilter("error", getpass.GetPassWarning); print(json.dumps(getpass.getpass("New value: ")))' \
  | sops set --value-stdin secrets/provider-services.yaml '["openai_api_key"]'
```

For a new field, add its manifest entry and provision the encrypted value in
that group in the same change. For a new consumer, use the platform's
published field path. Clear `SOPS_AGE_KEY_CMD` when maintenance is complete.

#### Migrate from the legacy layout

On the candidate checkout, leave `secrets/tokens.yaml` in place until the
verified new files are ready. Pause rotations while taking the migration
snapshot. Use the pinned tools and key command above, then run:

```sh
work=$(mktemp -d)
python3 scripts/migrate-cli-credentials.py forward "$work/forward"
```

The command writes only verified ciphertext to
`$work/forward/{git-hosting,provider-services}.yaml`. The new directory
must be absent when the command starts. The tool checks creation rules and
ciphertext recipient sets, refuses unknown, duplicate, missing required, or
misgrouped fields, and compares every decrypted output value to its input in
memory. Classify any unknown field in the manifest before retrying.

After success, copy both encrypted files to their final paths and check the
recipient metadata before removing the old file from the integration change.

```sh
(
  set -eu
  for group in git-hosting provider-services; do
    test ! -e "secrets/$group.yaml"
    test ! -L "secrets/$group.yaml"
  done
  for group in git-hosting provider-services; do
    install -m 600 "$work/forward/$group.yaml" "secrets/$group.yaml"
  done
  bash tests/sops-recipients.sh "$PWD"
  bash tests/user-identity-secrets.sh "$PWD" git-hosting provider-services
  git add secrets/git-hosting.yaml secrets/provider-services.yaml
  git rm secrets/tokens.yaml
)
unset SOPS_AGE_KEY_CMD
```

Run the real-output checks with both encrypted inputs staged before applying
either host. Keep the legacy creation rule for rollback.

#### Roll back with current values

Pause rotations and run the reverse transform in the split-layout checkout
with both current group files present. Use the same tools and key command.

```sh
work=$(mktemp -d)
python3 scripts/migrate-cli-credentials.py reverse "$work/reverse"
```

Use `$work/reverse/tokens.yaml` as `secrets/tokens.yaml` in the rollback
change. Restore the old consumer declarations and retire the split
ciphertexts together. Run `bash tests/sops-recipients.sh "$PWD"` and verify the
old-layout outputs with this ciphertext before applying either host. A copy
of `tokens.yaml` from Git history predates any rotations since the split.
Clear `SOPS_AGE_KEY_CMD` when finished.

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

### `secrets/hosts/<host>/wired-network.yaml`

A host of either kind (`MS-7D91` on NixOS, `MacBook-Pro-Mac17-9` on macOS) with `my.wiredNetwork.enable = true` has `secrets/hosts/<host>/wired-network.yaml`, encrypted to that host's recipient alone:

```yaml
mac: <wired adapter MAC address>
ipv4_address: <static IPv4 address>
ipv4_subnet_mask: <subnet mask>
ipv4_router: <router address>
dns_servers:
  - <first DNS server>
  - <second DNS server>
```

None of these values is a credential, so there is nothing to rotate, but together they describe an internal network, so they stay encrypted in this public repository. `mac` is the adapter's permanent hardware address, not a randomized one.

On NixOS (`modules/nixos/wired-network.nix`), `nixos-wired-network.service` decrypts the file in memory with `/var/lib/sops-nix/key.txt` before NetworkManager starts and writes the `wired-static` profile, bound to the adapter with that MAC address, under `/run/NetworkManager/system-connections/`. The file stays outside `sops-install-secrets`, so a bad file cannot stop other secrets from installing. The NixOS tool applies stricter rules than macOS: `dns_servers` are IPv4 only, the prefix length from `ipv4_subnet_mask` is 1 to 30, and `ipv4_router` lies inside the address's network. A file that cannot be decrypted or breaks a rule writes nothing and the unit still exits 0; the host then falls back to DHCP, or to the hand-made wired profile while that profile exists. A production output with the trait on and no file fails to build. The bootstrap output renders nothing and stays on DHCP. See [wired network on NixOS](../docs/install.md#wired-network) and [macOS hosts](../docs/macos.md#wired-network).

To create or change the file, add the `.sops.yaml` rule shown above, then encrypt the YAML from standard input so no plaintext reaches the checkout:

```sh
printf '%s\n' 'mac: <MAC>' 'ipv4_address: <address>' 'ipv4_subnet_mask: <mask>' \
    'ipv4_router: <router>' 'dns_servers:' '  - <DNS 1>' '  - <DNS 2>' \
  | sops --encrypt --filename-override secrets/hosts/<host>/wired-network.yaml \
      --input-type yaml --output-type yaml /dev/stdin \
  > secrets/hosts/<host>/wired-network.yaml
```

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
