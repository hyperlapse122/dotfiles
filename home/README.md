# Chezmoi Source State

This directory (`home/`) is the chezmoi source state, selected by the repository-root `.chezmoiroot`.
Managed files located here are applied to your actual user home directory.
This README file is excluded from destination files by `.chezmoiignore`.

## Authoring and Maintenance

Authoring guidelines, naming conventions, and script lifecycles are documented in:

- **[Chezmoi Source Maintenance](../docs/maintenance/chezmoi-source.md)**
  Complete details on directory layout, `.chezmoidata/` merging, script lifecycles (`run_before_`, `run_onchange_`, `run_after_`), dependency signatures, Windows PowerShell BOM requirements, modify templates, and the AI harness onboarding procedure.

- **[Documentation Index](../docs/README.md)**
  Overview of all setup, user, and maintenance guides.

## Key Rules

- **Development vs. Personal Tools:** Development tools are declared in `mise.toml` and locked in `mise.lock`. Personal settings, desktop apps, and user environment hooks are managed by chezmoi.
- **Source Safety:** Never commit plaintext credentials or private keys. Encrypted secrets belong in `.secrets/api-tokens.yaml.asc` using the repository's GPG encryption workflow.
