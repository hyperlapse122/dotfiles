{
  config,
  pkgs,
  lib,
  ...
}:
let
  streamTimeoutEnabled =
    config.my.kind == "darwin" && config.my.networkRecovery.enable && !config.my.bootstrap;
  merger = "${
    (import ../../../packages/agent-tools.nix { inherit pkgs; }).agentSettings
  }/bin/agent-settings";

  # Declared through the environment because that is where these settings
  # persist.  A variable that only overrides one session -- ANTHROPIC_MODEL,
  # CLAUDE_CODE_EFFORT_LEVEL -- does not move its setting out of the file.
  environmentTier = {
    DISABLE_AUTOUPDATER = "1";
    CLAUDE_CODE_DISABLE_AUTO_MEMORY = "1";
    CLAUDE_CODE_MAX_CONCURRENT_SUBAGENTS = "20";
    CLAUDE_CODE_MAX_SUBAGENT_SPAWN_DEPTH = "1";
    # Lets a bypass-permissions (T3 Code full access) session run a command
    # that trips the dangerous-rm check without an approval prompt. Claude
    # Code ignores it whenever any PermissionRequest hook or Bash, Edit, or
    # Read deny or ask rule exists, so one left in ~/.claude/settings.json or
    # an enabled plugin silently brings the prompt back.
    CLAUDE_CODE_EVEN_MORE_DANGEROUSLY_SKIP_PERMISSIONS = "1";
  };

  # Claude Code owns ~/.claude/settings.json and rewrites it whenever a /config
  # option changes, so Home Manager cannot place a read-only store symlink
  # there.  Activation assigns these keys instead and leaves every other key as
  # the agent wrote it.  A key listed here returns to its declared value on the
  # next rebuild; a key absent from here stays the user's permanently.  Note
  # that a project-level .claude/settings.json still outranks this tier.
  settingsTier = {
    model = "opus[1m]";
    # `auto` follows the background the terminal reports, so the palette
    # tracks whichever theme Ghostty is running rather than pinning one here.
    theme = "auto";
    preferredNotifChannel = "ghostty";
    agentPushNotifEnabled = false;
    inputNeededNotifEnabled = false;
    cleanupPeriodDays = 30;
    # Stops claude.ai connectors from loading into local sessions.  A settings
    # key rather than ENABLE_CLAUDEAI_MCP_SERVERS: Claude Code honours it from
    # any settings source, so a project-level file cannot turn it back on, and
    # it does not depend on how the session's environment was built.
    disableClaudeAiConnectors = true;
  };

  # Leaves assigned inside nested objects of settings.json. A plugin is enabled
  # by one entry of enabledPlugins, an object that also holds the plugins
  # agent-plugins.nix registers, so declaring the whole object in settingsTier
  # would drop theirs. To turn a plugin off, set its value to false rather than
  # deleting the entry: the merge only assigns, and retiredKeys can only remove
  # enabledPlugins as a whole.
  settingsPaths = [
    {
      path = [
        "enabledPlugins"
        "cc-plugin-you-should-know@builtin"
      ];
      value = true;
    }
    # Native worktrees start from the remote default branch unless this is
    # `head`, which starts them from the parent's current commit.
    {
      path = [
        "worktree"
        "baseRef"
      ];
      value = "head";
    }
  ];

  # Keys Claude Code reads only from its global config, ~/.claude.json, and
  # never from settings.json.  That file is Claude Code's own runtime state too,
  # so the same merge assigns these keys and leaves the rest untouched.
  globalConfigTier = {
    leftArrowOpensAgents = false;
  };

  # Keys this repository used to declare and has since retired. The merge only
  # assigns, so dropping a key from settingsTier alone would leave its last
  # written value on every machine forever. Move it here instead, and delete
  # the entry once every host has rebuilt past it.
  retiredKeys = [
    "advisorModel"
    "autoCompactWindow"
    "language"
  ];

  renderDeclared =
    name: set: remove: setPaths:
    pkgs.writeText name (
      builtins.toJSON {
        inherit set remove setPaths;
      }
    );

  declared = renderDeclared "claude-declared-settings.json" settingsTier retiredKeys settingsPaths;
  # User-scope MCP servers live in the global config's top-level mcpServers.
  # ownEntries upserts only the servers named here and leaves the ones the
  # user adds with `claude mcp add -s user`.
  fff = import ./fff-server.nix { inherit pkgs; };
  declaredGlobalConfig = pkgs.writeText "claude-declared-global-config.json" (
    builtins.toJSON {
      set = globalConfigTier;
      ownEntries = [
        {
          path = [ "mcpServers" ];
          entries.fff = {
            type = "stdio";
            inherit (fff) command args;
          };
        }
      ];
    }
  );
in
{
  my.agents.crossModelPeers = [ "claude" ];

  # A running session drops a stream that stalls after a network switch within
  # a minute instead of Claude Code's 180-second default, so it recovers on the
  # next request once the network recovery daemon has the Mac back online.
  home.sessionVariables =
    environmentTier
    // lib.optionalAttrs streamTimeoutEnabled {
      CLAUDE_BYTE_STREAM_IDLE_TIMEOUT_MS = "60000";
    };

  # Finder and Dock launches never read hm-session-vars.sh, so a T3 Code
  # launched from them gets the dangerous-rm waiver from launchd instead.
  launchd.agents.claude-rm-waiver = lib.mkIf (config.my.kind == "darwin") {
    enable = true;
    config = {
      ProgramArguments = [
        "/bin/launchctl"
        "setenv"
        "CLAUDE_CODE_EVEN_MORE_DANGEROUSLY_SKIP_PERMISSIONS"
        environmentTier.CLAUDE_CODE_EVEN_MORE_DANGEROUSLY_SKIP_PERMISSIONS
      ];
      RunAtLoad = true;
    };
  };

  # Finder and Dock launches inherit launchd's environment, not shell exports.
  launchd.agents.claude-stream-timeout = lib.mkIf streamTimeoutEnabled {
    enable = true;
    config = {
      ProgramArguments = [
        "/bin/launchctl"
        "setenv"
        "CLAUDE_BYTE_STREAM_IDLE_TIMEOUT_MS"
        "60000"
      ];
      RunAtLoad = true;
    };
  };

  home.activation.claudeStreamTimeout = lib.mkIf (config.my.kind == "darwin") (
    lib.hm.dag.entryAfter [ "installPackages" ] ''
      if [[ ! -v DRY_RUN ]]; then
        ${
          if streamTimeoutEnabled then
            "/bin/launchctl setenv CLAUDE_BYTE_STREAM_IDLE_TIMEOUT_MS 60000"
          else
            ''
              if [[ $(/bin/launchctl getenv CLAUDE_BYTE_STREAM_IDLE_TIMEOUT_MS) == 60000 ]]; then
                /bin/launchctl unsetenv CLAUDE_BYTE_STREAM_IDLE_TIMEOUT_MS
              fi
            ''
        }
      fi
    ''
  );

  # No executable-existence guard, unlike the KDE activation blocks. Those test their
  # tool with `[ -x ]` because it comes from a package that may be absent; this
  # merger is a store path built from this module, so the test could only ever
  # be true -- and if it somehow were not, the false branch would skip the
  # merge silently, which is the opposite of what the merge must do. A refusal
  # or a missing binary both have to stop the rebuild loudly.
  # After installPackages, not merely after writeBoundary. A refusal has to
  # fail the rebuild, and an activation entry that fails stops every entry
  # ordered behind it -- from writeBoundary that would strand linkGeneration
  # and installPackages, leaving the system generation switched while the home
  # generation is not linked and packages are missing. A file another program
  # owns should not be able to do that.
  home.activation.claudeSettings = lib.hm.dag.entryAfter [ "installPackages" ] ''
    if [[ ! -v DRY_RUN ]]; then
      ${merger} \
        --label 'Claude Code' \
        --settings ${config.home.homeDirectory}/.claude/settings.json \
        --declared ${declared}
    fi
  '';

  # Its own entry, so each merge names exactly one file and a refusal reports
  # which one. It shares claudeSettings' ordering and dry-run behavior.
  home.activation.claudeGlobalConfig = lib.hm.dag.entryAfter [ "installPackages" ] ''
    if [[ ! -v DRY_RUN ]]; then
      ${merger} \
        --label 'Claude Code' \
        --settings ${config.home.homeDirectory}/.claude.json \
        --declared ${declaredGlobalConfig} \
        --ledger ${config.home.homeDirectory}/.claude/global-config-ownership.json
    fi
  '';
}
