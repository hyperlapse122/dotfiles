# Chezmoi source

This directory is the chezmoi source state, not the application destination.
The repository's `.chezmoiroot` selects it; managed files are applied to the actual user home directory.
This README is excluded by `.chezmoiignore`.

The source contains `.chezmoi.toml.tmpl` to retain the permanent checkout binding when chezmoi configuration is regenerated.
It preserves unrelated TOML values while updating the source and working-tree paths and enforcing native GPG encryption policy.
The source manages global Git identity, OpenPGP commit signing, and the initial branch default through `dot_gitconfig.tmpl`.
Shared data is split under `.chezmoidata/`: `git.yaml` contains the Git identity, `gpg.yaml` contains the encryption recipient and OS-specific executable defaults, and `windows.yaml` lists the Windows host applications.
Chezmoi merges these files into the root data dictionary for managed templates; configuration initialization reads the public GPG data explicitly because that dictionary is not available at that stage.
See the root README for prerequisites and installation-path overrides.
GPG agent modify templates share the partial-file transformation in `.chezmoitemplates/gpg-agent-config`, preserving settings outside `pinentry-program`.
Modify templates use `chezmoi:modify-template` and deliberately have no `.tmpl` suffix.
OS-conditional ignores select the Windows or Unix GPG home.
Before/after scripts check the effective GPG home and reload the agent only during explicit application; Windows uses a profile-free PowerShell invocation through `.cmd` scripts.
The Windows app script uses WinGet after the GPG-home check and runs on every explicit apply to restore missing apps without requesting upgrades of existing installations.
Its package list includes Chrome, 1Password, and 1Password CLI; account sign-in and app preferences are not managed.
Keys and trust databases are not source-state entries.
Use scripts only for actions that cannot be represented as managed files.
Native-CA startup modify templates share `.chezmoitemplates/native-ca-shell` and preserve content outside their marked block.
Optional Bash login files are selected only when they already exist at the destination.
Linux uses an OS-managed `environment.d` file; macOS uses an Aqua login LaunchAgent.
Windows explicit apply invokes the shared registry-provider body in `.chezmoitemplates/native-ca-windows`, changing only the managed user environment value.
These settings do not provision certificates; the root README lists runtime support and activation limits.

## Secret source

`.secrets/api-tokens.yaml.asc` is encrypted source data, excluded from destination enumeration by `.chezmoiignore`.
The `secrets` partial under `.chezmoitemplates/` returns its decrypted YAML only when a consumer requests it.
Parse that result with `fromYaml` in the consuming template and select the needed field; do not load secrets into global configuration data.
The committed payload contains dummy API tokens, not real credentials.
Use chezmoi's native `encrypt` and `edit-encrypted` commands as documented in the root README.

The recipient in `.chezmoidata/gpg.yaml` is authoritative during explicit initialization.
The configuration template replaces recipient-affecting options, including inherited symmetric mode and additional recipients.
It uses the shared GPG executable selection, but ignores personal `gpg.conf` options for these calls to prevent implicit extra recipients.
Private-key access remains GPG's responsibility, without source-level hardware checks.

## Script ordering

When scripts depend on order within the same execution phase, prefix their descriptive names with consistently padded numbers, for example:

- `run_once_before_10-windows.ps1.tmpl`
- `run_once_before_20-windows-tools.ps1.tmpl`

The numbers order scripts within a phase; they do not override `before_` or `after_`.
Use OS-conditional templates for platform-specific scripts so they render empty on other operating systems.
Choose `run_`, `run_onchange_`, or `run_once_` according to when the action must run, and keep scripts idempotent.
