# Grok Build

Grok is installed as a native executable at `~/.local/bin/grok` (`grok.exe` on Windows). Supported targets are Windows x64/ARM64, Linux x64/ARM64, and Apple Silicon. The committed application lock pins the complete official versioned URL and SHA-256 checksum. The resolver reads the official stable pointer and hashes the published binaries; upstream does not publish SHA-256 sidecars for these artifacts. Explicit apply uses shared external-asset preparation and never runs the upstream installer or selects an installation-time latest version.

Run `mise run apply` from the intended worktree to prepare the locked executable, merge private `~/.grok/config.toml`, render `~/.grok/AGENTS.md` from the shared instruction template with `harness=grok`, and register the pinned local Compound Engineering source through native Grok plugin commands. Worktree preparation does not apply settings or sign in.

The managed scope is the default `~/.grok`. Custom `GROK_HOME` directories remain unmanaged.

The managed configuration disables CLI automatic updates and Claude/Cursor instruction and skill compatibility. Native Grok plugins remain available. Other configuration, credentials, sessions, and unrelated plugins are preserved. Sign in separately with `grok login`, or provide `XAI_API_KEY` through the native environment route. Authentication is not provisioned by dotfiles.

Repository instructions follow Grok's native project-trust decision. Dotfiles does not pretrust repositories.

CE registration points at `~/.local/share/dotfiles/harness-plugins/compound-engineering`, using the repository's existing release and commit pin. Native local installs can be live links or Windows copies. Grok 1.0.77 reports both as live during native update, so explicit apply uses native uninstall/install to repair copies and reenables the owned plugin. A source containing unrelated companion plugins is preserved and rejected for cutover; separate CE from that source before applying.

T3 uses its built-in `grok` driver and the fully expanded native executable path. The driver owns the `agent stdio` ACP launch. Its process environment disables the updater as well. The pinned T3 driver does not support a `launchArgs` field, so it cannot currently supply the native Grok `--rules` addition through provider settings.

Run `python tests/smoke_grok.py` with repository tools on PATH for isolated native verification. Add `--t3` to exercise the installed T3 server. `--install-desktop` provisions T3 only on disposable hosted runners. The smoke verifies shared instructions, foreign-content exclusion, plugin preservation/repair, and complete CE skill expansion through a rejecting loopback endpoint. It does not use a real account or claim authenticated model completion.
