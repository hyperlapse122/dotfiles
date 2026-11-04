# Chezmoi source

This directory is the chezmoi source state, not the application destination.
The repository's `.chezmoiroot` selects it; managed files are applied to the actual user home directory.
This README is excluded by `.chezmoiignore`.

The source contains `.chezmoi.toml.tmpl` to retain the permanent checkout binding when chezmoi configuration is regenerated.
It preserves existing TOML values while updating the source and working-tree paths.
The source has no concrete personal dotfiles payload or installation scripts yet.
Place managed configuration here using chezmoi's source naming conventions.
Use scripts only for actions that cannot be represented as managed files.

## Script ordering

When scripts depend on order within the same execution phase, prefix their descriptive names with consistently padded numbers, for example:

- `run_once_before_10-windows.ps1.tmpl`
- `run_once_before_20-windows-tools.ps1.tmpl`

The numbers order scripts within a phase; they do not override `before_` or `after_`.
Use OS-conditional templates for platform-specific scripts so they render empty on other operating systems.
Choose `run_`, `run_onchange_`, or `run_once_` according to when the action must run, and keep scripts idempotent.
