# Git and GPG Configuration

This guide explains how this repository configures global Git identity, automatic commit signing, GPG pinentry dialogs, directory safety guards, and repository cloning with `ghq`.

## Overview

The repository manages global Git configuration (`~/.gitconfig`) and GPG agent pinentry settings (`gpg-agent.conf`) declaratively.

- **Author Identity:** Joosung Park (`iam@h82.dev`)
- **Default Branch:** `main` (for newly initialized repositories)
- **Commit Signing:** Enabled by default using OpenPGP key `621512777E6933FEB4458FDC4945855D4F283F05`
- **Repository Root:** `~/src` (managed via `ghq.root`)

> **Important:** The entire global `~/.gitconfig` is repository-managed. Edit the source template in `home/dot_gitconfig.tmpl` rather than manually editing the generated file, as manual changes will be overwritten on the next apply.

## Prerequisites

Before applying dotfiles, verify that Git, mise, GnuPG (including `gpgconf`), and a compatible pinentry program are installed.
Explicit application builds the repository's Rust pinentry using the mise-pinned Rust toolchain. Windows application first runs the existing Visual Studio Build Tools readiness/provisioning task; Linux needs a native linker, and macOS uses the selected Xcode compiler and SDK.
Worktree preparation (`mise install`) validates source state without building or installing the personal pinentry.

Your private signing key (and physical hardware token/YubiKey, if applicable) must already be configured on the host. Explicit application provisions the configured recipient's public key; private keys and ownertrust remain the user's responsibility.

## Public Recipient Provisioning

During explicit application, `run_before_15-import-gpg-recipient` runs after the GPG home guard and before later apply scripts and ordinary target-template rendering. It uses the selected native `gpgProgram`, so the public recipient is available to subsequent encryption operations. The disposable-home lifecycle test checks both encryption in a later before-script and key lookup from a target template. GnuPG and its sibling `gpgconf` must already be installed when the home guard runs.

The reviewed public key is stored as ASCII armor in `home/.chezmoidata/gpg-recipient.yaml`. Application first inspects a temporary copy in a disposable GPG home and requires exactly one public primary key matching `gpgRecipient`. This avoids changing the managed keyring during artifact verification. If the exact primary key is already present, import is skipped. Otherwise the script imports it and reads back its primary fingerprint. Unrelated keys and assigned ownertrust are preserved; fresh application does not need a keyserver connection.

Worktree bootstrap (`mise install`), source inspection, and dry-run application do not import the key. The script does not run for standalone encryption commands or configuration initialization; apply first when preparing a fresh keyring.

Explicit Mac initialization and the Apple-account importer render the same GPG home guard and public-recipient import partials through the repository's hook-free chezmoi config.
They can therefore prepare the recipient before Xcode and personal application.
The cold-start decryption path sets `GPG_TTY` from the operator's terminal and captures plaintext privately while Homebrew's default terminal pinentry handles PIN entry.
It does not require the Rust wrapper, replace existing agent configuration, or assign ownertrust.

Public-key presence does not establish recipient validity or authorize private-key access. An unknown-validity recipient can still trigger GPG's trust prompt during encryption, including a failure in a shell without a TTY. Make any personal trust decision separately; application does not assign ownertrust or disable encryption trust checks.

To refresh the public artifact, retrieve it from the [keys.openpgp.org fingerprint endpoint](https://keys.openpgp.org/vks/v1/by-fingerprint/621512777E6933FEB4458FDC4945855D4F283F05), inspect it with the native GPG `--import-options show-only --with-colons --import` in a disposable GPG home, and compare the primary `fpr` record with `gpgRecipient`. Review identities, subkeys, and revocations, then replace the armored YAML field and update its retrieval date. Do not inspect an unverified replacement in the personal keyring: even show-only inspection can create keyring and trust-database files.

### Platform Executable Defaults

Platform paths are declared in `home/.chezmoidata/gpg.yaml`:

| Platform | GPG Executable | Native Fallback Pinentry |
|---|---|---|
| Windows / Gpg4win | `C:/Program Files/GnuPG/bin/gpg.exe` | `C:/Program Files/Gpg4win/bin/pinentry.exe` |
| Linux | `/usr/bin/gpg` | `/usr/bin/pinentry` |
| macOS (Apple Silicon) | `/opt/homebrew/bin/gpg` | `/opt/homebrew/bin/pinentry-mac` |

`gpgconf` must reside in the same directory as the selected `gpg` executable.

### Custom Executable Overrides

If GnuPG or pinentry is installed in a non-standard location, set absolute paths in your persistent chezmoi TOML configuration (`~/.config/chezmoi/chezmoi.toml` on POSIX or `%USERPROFILE%/.config/chezmoi/chezmoi.toml` on Windows):

```toml
[data]
gpgProgram = "D:/Tools/GnuPG/bin/gpg.exe"
pinentryProgram = "D:/Tools/Gpg4win/bin/pinentry.exe"
```

`pinentryProgram` selects the native fallback. The agent uses `~/.local/bin/dotfiles-pinentry` (`dotfiles-pinentry.exe` on Windows), with a private `dotfiles-pinentry.json` sidecar holding the absolute fallback path. The sidecar contains no PIN.

## GPG Home Directory Safety

The expected GPG home directory is:
- **Windows:** `%USERPROFILE%\AppData\Roaming\gnupg`
- **Linux & macOS:** `~/.gnupg`

### Safety Guards

Before writing personal files, an explicit apply checks the effective GPG home reported by `gpgconf --list-dirs homedir`:
- If the effective location differs (e.g. Due to custom `GNUPGHOME` or registry overrides), the apply stops immediately.
- Symlinked GPG home directories or parent directory reparse points are rejected. On Windows, an existing path alias is accepted only if its volume serial and 128-bit file ID match the target directory.
- GnuPG reads `GNUPGHOME` via the Windows ANSI API; paths containing characters outside the system code page must use ASCII aliases.

> **Warning:** Do not bypass this check by forcing `--homedir` in personal scripts. GPG configuration must align with the OS-standard directory structure.

## GPG Agent Configuration and Reloading

The template reconciles `pinentry-program`, `default-cache-ttl 0`, and `max-cache-ttl 0` in `gpg-agent.conf`. Comments, SSH-specific cache directives, and unrelated agent options remain intact.
These TTLs disable the agent's ordinary passphrase memory cache. GnuPG's separate smartcard PIN cache remains permitted; the card's authentication state, touch policy, and retry settings are unchanged. An operation satisfied by the card or smartcard cache may never invoke pinentry.
The platform frontend's external-cache policy is retained separately from the agent's ordinary memory cache.

Explicit application installs the built wrapper before applying agent settings. A byte-identical binary is retained on subsequent applies. Application reloads `gpg-agent` when consumed templates or effective wrapper/fallback settings change; an unchanged apply skips reload.

To inspect template drift without executing apply scripts, run:

```sh
chezmoi diff --exclude=scripts
```

## Card PIN Storage and Recovery

The wrapper uses Windows Credential Manager, macOS Keychain, or Linux Secret Service. Each card has its own OpenPGP user-PIN entry under service `dotfiles.pinentry.openpgp`, with account `yubikey:<decimal-serial>:user`.
Native-store authorization and persistence follow OS policy. A locked or inaccessible store produces an error; it is not treated as an empty store, and no plaintext substitute is created. macOS may request renewed Keychain access approval after the executable changes.

Automatic lookup requires the agent's `allow-external-password-cache` option and a recognized English OpenPGP unlock request with the exact `PIN` prompt and an unambiguous YubiKey serial. The parser follows the inspected GnuPG 2.4.8/2.5.24 prompt layout, including grouped decimal serials such as `12 345 678`.
Unknown layouts or languages, administrator PINs, PIN changes/repeats, and ordinary key passphrases use the native frontend without custom keyring access. Existing `no-allow-external-cache` configuration prevents automatic enrollment and lookup.

On a qualifying miss, the native frontend collects the PIN and the wrapper saves it before returning it to GnuPG. Cancellation saves nothing. Saving an entered value does not prove that the card accepted it.

A recognized `Remaining attempts: 0`, `1`, or `2` warning invalidates the matching record and forces manual entry for that request. GnuPG does not deliver every card rejection back to standalone pinentry. With configured retry counts above three, earlier failed attempts can remain invisible to this heuristic.

After changing, resetting, or unblocking the user PIN, run `dotfiles-pinentry forget <serial>` on every host that saved that card's PIN before the next card operation. Change-PIN dialogs do not update the saved entry. Otherwise the old saved PIN can be submitted automatically and consume a retry attempt.

To remove one saved PIN explicitly and force manual entry on its next qualifying request, use the printed decimal YubiKey serial:

```sh
~/.local/bin/dotfiles-pinentry forget 12345678
```

```powershell
& "$HOME/.local/bin/dotfiles-pinentry.exe" forget 12345678
```

Deletion is idempotent and never displays the PIN. Native keyring errors still fail the command.

This is automation for trusted programs running as the OS user. Prompt matching is a compatibility classifier and does not attest hardware identity. Same-user programs can invoke the helper or synthesize agent requests to obtain an enrolled PIN; protection against compromised same-user code and per-process authorization are outside this feature's boundary.

## Development Verification

The root Cargo workspace owns `crates/pinentry/` and its shared `Cargo.lock`; build output lives under the repository-root `target/`. `mise run pinentry:build` selects the `dotfiles-pinentry` package for installation.

`mise run pinentry:test` runs workspace-wide formatting, lint and protocol/CLI tests with synthetic secrets and fake frontends; it never opens the owner's keyring. The Git/GPG test suite also checks the ordinary cache policy using an isolated software key and agent, without a card.
Successful native-store smoke tests are restricted to disposable GitHub-hosted runners. They use an isolated Linux session bus, a disposable macOS Keychain, or the hosted Windows account. Changing `HOME` alone does not isolate a real OS keyring.

## CLI Completions

`dotfiles-pinentry --usage-spec` prints the canonical public Usage specification without loading frontend configuration, accessing a credential store, or starting the Assuan server. Help and version requests have the same independence. Native pinentry startup arguments continue to pass through unchanged.

Explicit `mise run apply` installs the pinentry binary and then generates Bash, Zsh, and PowerShell completion scripts with the mise-pinned Usage 7.3.0 tool. Each script reads a snapshot of the installed binary's specification; Tab completion invokes Usage only, never pinentry or a card/keyring lookup. Reapply refreshes the specification and scripts when the CLI changes and leaves identical files untouched.

Managed interactive Bash and Zsh profiles load the generated scripts. PowerShell 7's managed profile loads its `.ps1` script after mise activation; Windows PowerShell 5.1 leaves native completion unloaded. Bash requires version 4.2 or newer and bash-completion 2.11 or newer; apply installs a checksummed bash-completion 2.18.0 library, compatibility definitions, and license on Unix. macOS system Bash 3.2 is unsupported; use the managed Zsh integration. Windows supports PowerShell 7 completion; its Bash profiles are not managed. Fish and Nushell startup integration is not managed by this repository.

The library, compatibility definitions, and license are selected together from one archive through shared external-asset preparation. Unchanged applies reuse that prepared tree, and missing installed files are restored from the cache. `mise run assets:verify` checks cached content fully and reconciles the installed files.

The public completion surface is help, version, specification output, and `forget <card-id>`. Completion does not enumerate stored credentials, connected cards, or PINs. New repository CLIs should export a side-effect-free `--usage-spec` and add an entry to the same explicit-apply generator, keeping their canonical spec beside the crate and testing both exported commands and fresh-shell registration.

The Usage 7.3.0 PowerShell generator includes the partial token twice; the source-bound generator corrects that pinned behavior before publication. Paths are quoted for each shell, and PowerShell scripts use the native `.ps1` extension.

## Verifying Commit Signing

To verify that signing and pinentry integration work end-to-end:

```sh
# 1. Create a temporary test repository
mkdir -p /tmp/git-sign-test && cd /tmp/git-sign-test
git init
git commit --allow-empty -m "test: verify signing"

# 2. Complete PIN or touch prompt when requested
# 3. Verify signature
git verify-commit HEAD
```

Clean up the test directory when finished.

## Repository Clones with ghq

Applying personal settings installs [ghq](https://github.com/x-motemen/ghq) to `~/.local/bin/ghq` and configures `ghq.root = ~/src` in `~/.gitconfig`.

### Usage

Clone repositories using standard ghq commands from any directory:

```sh
ghq get https://github.com/hyperlapse122/dotfiles.git
```

This clones the repository to:
```
~/src/github.com/hyperlapse122/dotfiles
```

This path matches the Windows bootstrap destination layout. If the clone already exists, `ghq get` leaves it untouched unless `-u` (update) is supplied.

To check your current ghq root:

```sh
ghq root
```

> **Note:** If an environment variable `GHQ_ROOT` is set in your shell, it overrides the `gitconfig` setting. Unset `GHQ_ROOT` to use `~/src`.
