# Secrets and API Authentication

This guide describes how dotfiles encrypts API tokens in version control, imports GitHub and GitLab credentials, provisions native OS keyrings, and secures Git HTTPS authentication.

## Encryption Architecture

Secrets are encrypted directly in git using chezmoi's built-in GPG encryption (without external tools such as SOPS).

- **Recipient:** Public key fingerprint `621512777E6933FEB4458FDC4945855D4F283F05`
- **Configuration:** Stored in `home/.chezmoidata/gpg.yaml`
- **Encrypted Source:** `home/.secrets/api-tokens.yaml.asc` (excluded from destination files by `.chezmoiignore`)
- **Key Access:** Delegated to the host's GPG agent; private keys remain in your personal keyring or smartcard.

### Configuration Initialization

Before editing or decrypting secrets, initialize chezmoi configuration from your dotfiles checkout:

```sh
mise exec -- chezmoi --source . init
```

This enforces repository encryption policies:
- Sets the designated GPG recipient.
- Disables symmetric-passphrase fallbacks.
- Passes `--no-options` to prevent personal `gpg.conf` files from accidentally adding hidden recipients or groups.

### Authoring and Editing Encrypted Secrets

To edit the encrypted file directly in your editor:

```sh
mise exec -- chezmoi --source . edit-encrypted home/.secrets/api-tokens.yaml.asc
```

> **Path Constraint:** Chezmoi's `edit-encrypted` requires the file to reside under your user home directory (such as `~/src/github.com/hyperlapse122/dotfiles`). If your checkout is located elsewhere, maintain a temporary plaintext file outside the repository and encrypt it:

```sh
mise exec -- chezmoi --source . encrypt --output home/.secrets/api-tokens.yaml.asc /path/outside-repo/api-tokens.yaml
```

### Consuming Secrets in Templates

Templates access decrypted tokens through the shared `secrets` partial:

```gotemplate
{{- $secrets := includeTemplate "secrets" . | fromYaml -}}
{"apiToken": {{ $secrets.example.serviceB | toJson }}}
```

Decryption occurs only during explicit `mise run apply` when a template calls the partial. Worktree preparation (`mise install`) and bootstrap do not decrypt secrets.

### Security Boundaries

- **Plaintext Generation:** Encryption protects committed repository source. Generated destination files on your filesystem contain plaintext. Be cautious with `diff`, `cat`, and template previews.
- **Temporary Files:** Editing encrypted files creates temporary plaintext files. Use trusted local editors and avoid insecure scratch disks.
- **Fail Closed:** If private-key access is unavailable, apply fails with an error. No dummy or empty token fallback is permitted.

---

## SSH Identity

The former `MS-7D91` SSH identity from `hyperlapse122/nix-config` is managed as
`~/.ssh/id_ed25519` and `~/.ssh/id_ed25519.pub`. OpenSSH discovers this default
identity without an additional SSH configuration file.

- **Encrypted source:** `home/private_dot_ssh/encrypted_private_id_ed25519.asc`
- **Public source:** `home/private_dot_ssh/id_ed25519.pub`
- **Fingerprint:** `SHA256:skScV2Jt3VhRMrzcNAO+qmftolV4EXWuS1Ix65pfk14` (Ed25519)
- **Origin:** [`secrets/hosts/MS-7D91/ssh.yaml` at `c71756ab76eca6031118973726f4139a86e6b4db`](https://github.com/hyperlapse122/nix-config/blob/c71756ab76eca6031118973726f4139a86e6b4db/secrets/hosts/MS-7D91/ssh.yaml),
  before the host was replaced by `MS-7D91-VM`, which has a different identity.

The imported private key was decrypted from SOPS, checked against the original
public key, and re-encrypted to this repository's GPG recipient. Chezmoi decrypts
it during explicit application; SOPS and the old host's age identity are not
needed to apply it. The source uses chezmoi's private file and directory
attributes (0600 and 0700 on POSIX). Apply personal configuration with
`mise run apply` after reviewing any existing default SSH identity.

### Opt-in protected identities

The existing default identity above remains a legacy file-based identity until explicitly migrated. Its GPG source encryption protects version control; it does not add a local OpenSSH passphrase to the generated private key.

For new local enrollment, use a passphrase-protected OpenSSH-format key. Generate one with `ssh-keygen`, or use `ssh-keygen -p -o -f /path/to/key` to protect a deliberate external copy. These native commands prompt for the passphrase; do not put it in a shell command or configuration file. Check the key can be unlocked and keep a recovery copy before enrollment.

```sh
mise exec -- python scripts/ssh-identities.py enroll-local   --private-key /path/outside-repo/work_key   --public-key /path/outside-repo/work_key.pub   --id work --host github-work --hostname github.com --user git
```

The importer rejects unencrypted keys and mismatched public-key envelopes. It encrypts the inventory to the repository GPG recipient, decrypts it in memory to verify publication, and retains the external input files. No OpenSSH passphrase is stored. The encrypted inventory is `home/.secrets/ssh-identities.json.asc`, excluded from destination files by the existing `.secrets` rule.

Explicit `mise run apply` installs the still-passphrase-protected key under `~/.ssh/dotfiles/keys/`, with private permissions and native Windows ACLs. An owned Include block at the beginning of `~/.ssh/config` selects the enrolled host aliases and preserves unrelated configuration. Local aliases use `IdentityAgent none`, a single `IdentityFile`, `IdentitiesOnly yes`, and public-key authentication. OpenSSH prompts to unlock the selected file during normal authentication; it does not try a different agent or unrelated default key when that selection fails.

Enrollment is optional. Without the encrypted inventory, bootstrap and apply do not decrypt SSH enrollment or install its routing. Invalid enrolled data fails before replacing configuration. Reapplying the same inventory leaves identical file bytes untouched.

To deliberately migrate the legacy default identity, first verify recovery and the protected replacement's public fingerprint, then repeat local enrollment with `--replace-default`. That explicit option enrolls a value-free source-membership marker so subsequent chezmoi application stops regenerating the old default key. Apply then writes the protected replacement to `~/.ssh/id_ed25519` and its public companion. Enrollment without that option does not change either existing default file. This repository does not automatically transform or delete the owner's current key.

A lost OpenSSH passphrase cannot be recovered by GPG decryption: GPG restores the same passphrase-protected bytes. Recover from a separately secured backup or rotate the authorized key on the affected servers. Keep the previous working enrollment until its replacement has been validated.

### 1Password identity selection

Enable the SSH agent in 1Password Desktop and copy the selected item's **public** key to an external file. Sign-in, key import, unlock, and authorization remain native user actions. Enroll its public identity and explicit host alias:

```sh
mise exec -- python scripts/ssh-identities.py enroll-1password   --public-key /path/outside-repo/vault_key.pub   --id vault --host github-vault --hostname github.com --user git
```

This stores only the public identity for that entry. Routing uses its public `IdentityFile` and `IdentitiesOnly yes`, so the selected agent cannot offer every available key. On Linux the default socket is `~/.1password/agent.sock`; on macOS it is `~/Library/Group Containers/2BUA8C4S2C.com.1password/t/agent.sock`. Supply `--agent-socket` when the native installation uses another socket. No global `SSH_AUTH_SOCK` is changed.

Windows Microsoft OpenSSH uses one fixed agent pipe. When 1Password owns it, all agent-backed identities use that agent; the repository does not start a competing agent or claim two simultaneous Windows agents. Protected local aliases sign directly from their encrypted files with `IdentityAgent none`. The 1Password alias uses its public identity and the native fixed pipe. An unavailable or locked selected provider fails public-key authentication; it does not fall back to another identity source.

Use `ssh -G github-work` and `ssh -G github-vault` to inspect effective selection without connecting. Synthetic-key tests cover encryption, host routing, native OpenSSH config parsing, repeat application, and failure preservation. They do not prove a real 1Password account was unlocked or authenticated. Complete that check in a disposable authorized account before relying on a new deployment.

See [OpenSSH identity configuration](https://man.openbsd.org/ssh_config) and [1Password agent coexistence](https://developer.1password.com/docs/ssh/agent/advanced/) for client and platform constraints.

## GitHub Authentication

The repository manages GitHub CLI authentication and Git HTTPS credentials for `github.com` and `gist.github.com`.

### Development vs. Personal Executable

- **Development Tool:** Declared in `mise.toml` for repo workflows.
- **Personal CLI:** Installed to `~/.local/bin/gh` via chezmoi externals. Git credential helpers point strictly to `~/.local/bin/gh`.

### 1. Import GitHub Token

Store your GitHub Personal Access Token (PAT) in a temporary UTF-8 file and import it:

```sh
mise exec -- python scripts/github-auth.py import --token-file /path/to/github-token.txt
```

The importer:
1. Validates the token in memory.
2. Encrypts and stages the updated ciphertext into `home/.secrets/api-tokens.yaml.asc`.
3. Verifies that the new ciphertext decrypts correctly.
4. Deletes the input file from disk.

### 2. Apply and Provision Native Keyring

Run explicit apply to reconcile credentials:

```sh
mise run apply
```

Credentials are written to your platform's secure credential store:
- **Windows:** Windows Credential Manager
- **macOS:** macOS Keychain (via `security -i` stdin)
- **Linux:** Secret Service API (login / default collection)

Plaintext tokens are never passed as command arguments or written to disk.

### 3. Verify Authentication

Check active credentials without printing sensitive values:

```sh
gh auth status --active --hostname github.com
```

> **Warning:** Never run `gh auth token` or `git credential fill` in scripts or shared terminal sessions where logs may be captured.

---

## GitLab Authentication

The repository supports private GitLab instances for both the GitLab CLI (`glab`) and Git HTTPS operations.

### 1. Prepare Connection Details

Create a temporary JSON connection file outside the repository:

```json
{
  "host": "gitlab.example.com",
  "registry": "registry.example.com",
  "user": "your-username"
}
```

If `user` is omitted, the importer resolves it through GitLab's authenticated `/api/v4/user` endpoint.

### 2. Import Token and Connection

```sh
mise exec -- python scripts/gitlab-auth.py import \
  --token-file /path/outside-repo/gitlab-token.txt \
  --connection-file /path/outside-repo/gitlab-connection.json
```

The importer encrypts the parameters under the `gitlab` key in `api-tokens.yaml.asc`, verifies decryption, cleans up temporary recovery artifacts, and removes the token file. The connection file is retained locally outside git.

### 3. Apply Credentials and Git Configuration

Reconcile GitLab credentials into the native store:

```sh
mise run apply
```

To run targeted GitLab reconciliation without applying other personal application hooks:

```sh
mise exec -- python scripts/gitlab-auth.py apply --destination /path/to/user-home
```

This writes helper configuration to `~/.local/share/dotfiles/gitlab.gitconfig` and sets up the personal `glab` executable as the HTTPS credential helper.

### Troubleshooting `null` Settings

If `glab` reports `parsing time "null"` or tries to open a certificate file named `null`, reapply GitLab authentication with the targeted command above. Earlier authentication reconciliation serialized empty YAML settings as JSON `null`; `glab` reads that scalar as the literal text `null`, affecting timestamps, certificate paths, and other optional settings.

Reconciliation now writes these empty global and host settings as empty strings, including settings for other hosts, while retaining their configured values and credentials. It does not disable update checks or TLS verification. A separate `401 Unauthorized` after repair means that host still needs valid credentials; use `glab auth login --hostname <host>` for that account.

## SOPS dotenv Timestamp Errors on Windows

An error such as `parsing time "2026-10-14T09:28:37Z\x0d": extra text: "\x0d"`
can come from SOPS during a project's `mise install` postinstall hook. Check the
failing command before treating it as a glab authentication error. SOPS 3.13.3
retains the CR in a CRLF dotenv file's `sops_lastmodified` value and cannot parse
the timestamp.

The managed Git configuration sets `core.autocrlf = input`, overriding Git for
Windows' system default of `true`. New checkouts retain LF; repository attributes
and local configuration can still override this policy. Projects sharing SOPS
dotenv files should also declare `*.sops.env text eol=lf` in their own
`.gitattributes`.

Apply the managed Git configuration explicitly through chezmoi. This does not
rewrite existing working files. For an affected checkout, convert only the SOPS
dotenv file's CRLF line endings to LF, preserving its encrypted contents, then
rerun `mise install`. Avoid a repository-wide reset or checkout that could discard
local changes.

## Docker Hub and GitLab Container Registries

Registry enrollment is optional and separate from GitHub/GitLab API authentication. A GitLab API token must have the registry permissions needed for the intended pull or push; enroll a separate registry token when it does not. Host CLI credentials do not provision Kubernetes image-pull secrets or credentials inside containers.

The repository pins the official Docker credential helpers (`wincred`, `osxkeychain`, and `secretservice`) for supported targets. An enrolled registry is stored in Windows Credential Manager, macOS Keychain, or Linux Secret Service. The helper must be installed on the client host and discoverable on `PATH`; a configured Docker or Podman client is required. No engine, VM, WSL machine, or cluster is installed or started by this feature.

Import a Docker Hub account using a plaintext token file outside the repository:

```sh
mise exec -- python scripts/container-auth.py import --registry docker.io --user ACCOUNT --token-file /path/outside-repo/registry-token.txt
```

For a private GitLab registry, replace `docker.io` with its registry hostname and use the registry account. To opt in the already imported GitLab registry/user/token record:

```sh
mise exec -- python scripts/container-auth.py import-gitlab
```

The importer writes `home/.secrets/container-auth.json.asc` using the initialized repository GPG policy and verifies decryption. External token inputs are retained. Do not commit them. A missing enrollment is a no-op and does not decrypt the API token document.

Run explicit `mise run apply`, or reconcile only this capability:

```sh
mise exec -- python scripts/container-auth.py apply --destination /path/to/user-home
```

Reconciliation verifies native helper readback before removing owned plaintext authentication from Docker and Podman client files. It preserves unrelated registries, helper choices, and configuration. Docker Hub aliases share the intended account. Namespace-specific plaintext entries below an enrolled registry are owned by that registry and are removed after secure-store verification.

The effective `DOCKER_CONFIG` and `REGISTRY_AUTH_FILE` overrides are reconciled alongside the default files. Linux's `XDG_RUNTIME_DIR/containers/auth.json` and persistent `XDG_CONFIG_HOME/containers/auth.json` are both covered so an earlier Podman plaintext entry cannot shadow the managed helper. Use absolute override paths. When Linux has no `XDG_RUNTIME_DIR`, the existing `/run/user/UID` location is covered; otherwise set `REGISTRY_AUTH_FILE` explicitly for nonstandard runtime locations.

Locked or unavailable native storage fails without a plaintext fallback. Rotate credentials by importing the replacement and applying again. No real registry push is part of the smoke tests. `tests/smoke_container_auth.py` writes only synthetic records on disposable GitHub-hosted runners, restoring macOS Keychain selection and erasing its record. CI supplies the mise-pinned Podman 6.1.4 client and requires a real host-side `podman login --get-login` lookup. Remote Podman initializes a connection before this local lookup; a ping-only loopback fixture satisfies that handshake without returning credentials or starting an engine. The account must still come from the official helper and native credential store.
