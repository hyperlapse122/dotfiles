# Chezmoi source

This directory is the chezmoi source state, not the application destination.
The repository's `.chezmoiroot` selects it; managed files are applied to the actual user home directory.
This README is excluded by `.chezmoiignore`.

The source contains `.chezmoi.toml.tmpl` to retain the permanent checkout binding when chezmoi configuration is regenerated.
It preserves existing TOML values while updating the source and working-tree paths.
The source manages global Git identity, OpenPGP commit signing, and the initial branch default through `dot_gitconfig.tmpl`.
Shared data is split by tool under `.chezmoidata/`: `git.yaml` contains the Git identity and `gpg.yaml` contains OS-specific executable defaults.
Chezmoi merges these files into the root data dictionary, preserving the existing template keys; see the root README for prerequisites and installation-path overrides.
GPG agent modify templates share the partial-file transformation in `.chezmoitemplates/gpg-agent-config`, preserving settings outside `pinentry-program`.
Modify templates use `chezmoi:modify-template` and deliberately have no `.tmpl` suffix.
OS-conditional ignores select the Windows or Unix GPG home.
Before/after scripts check the effective GPG home and reload the agent only during explicit application; Windows uses a profile-free PowerShell invocation through `.cmd` scripts.
Keys and trust databases are not source-state entries.
Use scripts only for actions that cannot be represented as managed files.

## Script ordering

When scripts depend on order within the same execution phase, prefix their descriptive names with consistently padded numbers, for example:

- `run_once_before_10-windows.ps1.tmpl`
- `run_once_before_20-windows-tools.ps1.tmpl`

The numbers order scripts within a phase; they do not override `before_` or `after_`.
Use OS-conditional templates for platform-specific scripts so they render empty on other operating systems.
Choose `run_`, `run_onchange_`, or `run_once_` according to when the action must run, and keep scripts idempotent.
