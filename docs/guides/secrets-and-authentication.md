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
