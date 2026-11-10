# Codex app connectors and Computer Use

Codex's built-in app and connector integration and its Computer Use feature
are disabled. Home Manager reconciles `features.apps = false` and
`features.computer_use = false` into the writable `~/.codex/config.toml`.
On NixOS, this reconciliation runs when a rebuild produces a new Home Manager
generation. Non-NixOS Linux and macOS applies run Home Manager activation directly.

The packaged `codex` command also passes `--disable apps` and
`--disable computer_use` at startup. This overrides an enabled feature in a
home configuration, including a temporary `CODEX_HOME` that never receives the
declared user settings. T3 Code's declared Codex provider uses this packaged
command from PATH and shares `~/.codex`.

The `computer_use` feature switch alone leaves the `cua_repl` MCP server that
the ChatGPT desktop app's `unified-computer-use@openai-bundled` plugin starts,
and that server still offers the computer surface. The same reconciliation
therefore sets `enabled = false` on the `computer-use@openai-bundled` and
`unified-computer-use@openai-bundled` plugins. The desktop app's own bundled
Codex reads the same `config.toml`, so the feature switch and the plugin
settings reach it too; the wrapper flags do not.

The switch applies to new Codex processes. Restart standalone Codex, the T3
Codex session, or the ChatGPT desktop app after applying the configuration; an
existing process retains its already loaded tools. Running the unwrapped binary
bypasses the startup flags.

Ordinary MCP servers, local skills, unrelated plugin capabilities, installed
plugins, and credentials are preserved. Disabling `apps._default.enabled` alone
would allow individual apps to override the default, so this configuration uses
the feature switch instead. See the [OpenAI configuration reference](https://learn.chatgpt.com/docs/config-file/config-reference)
and [developer command reference](https://learn.chatgpt.com/docs/developer-commands).

## Verification boundaries

- `codex-settings` executes the activation block in a scratch home and checks
  that enabled apps, Computer Use, and both Computer Use plugins become
  disabled while unrelated MCP and plugin settings survive. It also checks
  repeated activation.
- `codex` runs the pinned binary with a default home and an alternate
  `CODEX_HOME`, both initially enabling apps and Computer Use, and checks that
  the wrapper disables both features. The unwrapped binary supplies the enabled
  control for apps.
- The same check verifies local skill discovery and asks a fresh app-server
  process for its effective app feature. It also discovers and calls an ordinary
  MCP tool through that process, without credentials.
- Authenticated standalone and live T3 sessions require separate verification.
  A temporary home is a package test, not evidence that the installed T3 process
  used a changed package. Host-injected tools also need separate attribution:
  Codex's app switch does not filter tools independently supplied by a host.

To inspect the effective features locally, run `codex features list` and check
the `apps` and `computer_use` rows, then run `codex mcp list` and check that no
`cua_repl` server remains. For a fresh authenticated session, inspect its
offered MCP servers and tools without invoking a real connector. Record the
executable, package revision, effective features, and any `codex_apps` or
`cua_repl` tools still exposed.
