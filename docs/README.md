# Documentation Index

This directory contains task-oriented user guides, setup instructions, and maintenance documentation for this dotfiles repository.

## Setup Guides

Getting started on a new device or configuring platform prerequisites:

- **[macOS Setup and Readiness](setup/macos.md)**
  Explicit Homebrew prerequisite provisioning, separate checkout preparation and source registration, explicit application, native builds, managed harnesses/apps, and manual/runtime readiness evidence on Apple Silicon.

- **[Windows Setup and Bootstrap](setup/windows.md)**
  Automated PC bootstrap, chezmoi source registration, host application provisioning via WinGet, virtualization preflight checks, native C++/.NET/Rust build environments, and Podman / Kubernetes onboarding.

## User Guides

Day-to-day operations, application management, and tool configurations:

- **[Git and GPG Configuration](guides/git-and-gpg.md)**
  Git author identity, automatic OpenPGP commit signing, pinentry dialog selection, GPG home path safety guards, and repository cloning with `ghq`.
- **[Secrets and API Authentication](guides/secrets-and-authentication.md)**
  Chezmoi GPG encryption, GitHub and GitLab token import workflows, native OS keyring provisioning (Windows Credential Manager, macOS Keychain, Linux Secret Service), and Git HTTPS credentials.
- **[Personal CLI Applications](guides/personal-applications.md)**
  Management of Claude Code, Codex, `gh`, `ghq`, and `glab` under `~/.local/bin`, shell PATH activation across OS families, release pin maintenance, and PowerShell mise activation.
- **[User Fonts](guides/fonts.md)**
  Pinned JetBrains Mono, Pretendard, D2Coding, and Nerd Font installation, native user-scope discovery, release updates, and Windows loaded-file recovery.
- **[T3 Code Desktop and Harness Integration](guides/t3-code.md)**
  T3 Code desktop app installation, bundled CLI launchers, native Claude Code, Codex, pi, and Grok providers.
- **[Harness Plugins and AI Agent Configuration](guides/harness-plugins.md)**
  Compound Engineering and the pinned korean-skills writing skills for every managed harness, local marketplace cutover, update policies, version rollback, shared user-scope instructions with the writing-skills rule, and account source isolation for Claude Code and Codex.
- **[macOS Dock](guides/macos-dock.md)**
  Declared personal, work, and development app pins, Dock preferences, repeat application, and isolated verification.
- **[Native System CA Trust](guides/system-ca.md)**
  Enterprise root certificate trust via `NODE_USE_SYSTEM_CA=1`, runtime support matrix, OS environment activation, and TLS verification.

## Maintenance Guides

Internal architecture, authoring rules, testing, and continuous integration:

- **[Chezmoi Source Maintenance](maintenance/chezmoi-source.md)**
  Source layout (`./home`), script lifecycles (`run_before_`, `run_onchange_`, `run_after_`), numeric ordering conventions, dependency signatures, modify-template rules, and AI harness onboarding procedures.
- **[Development, Testing, and CI](maintenance/development-and-testing.md)**
  Worktree preparation with `mise install`, bootstrap isolation mechanics, unit test suite architecture, standalone smoke tests, and the CI runner support matrix.
