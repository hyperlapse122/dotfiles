/*
  Check interface:

    import ./tests/codex-settings.nix { inherit pkgs self; }

  Asserts that the Codex declared set reaches user `h82` on every host this
  flake declares, through the shared settings merger in TOML mode.

  The configuration list comes from `tests/lib/configurations.nix`, so a host
  added later is covered the day it is added, and the helper's guard fails the
  build when that list is empty instead of letting it pass.

  Verifies, per host:
  - `home.activation.codexSettings` exists and runs after installPackages, so a
    refusal cannot strand linkGeneration and installPackages behind it.
  - its script invokes the packaged merger with `--format toml`; without the
    flag the merger parses config.toml as JSON and refuses every run.
  - it does not swallow the merger's exit status.
  - `--settings` is exactly ~/.codex/config.toml, read from the flags the
    merger is invoked with rather than from anywhere in the text.
  - no Home Manager file targets ~/.codex/config.toml, which Codex rewrites.
  - applied in a scratch HOME, the merge adds `[mcp_servers.fff]` with the
    fff-mcp store path and keeps the MCP server already in the file, and it
    turns off the enabled `computer_use` feature and both bundled Computer Use
    plugins while an unrelated plugin stays enabled.

  Every lookup carries an `or` fallback and every conditional block sits behind
  `lib.optionalString`, so a removed declaration fails inside the builder
  rather than during evaluation. See
  .compound-engineering/artifacts/solutions/best-practices/unguarded-derivation-interpolation-defeats-nix-check-mutation-testing.md

  The builder collects every failure instead of exiting at the first.
*/
{ pkgs, self }:
let
  inherit (pkgs) lib;

  configurations = import ./lib/configurations.nix { inherit pkgs self; };

  esc = value: lib.escapeShellArg (toString value);

  executeActivation = import ./lib/agent-activation.nix { inherit pkgs; };

  settingsFile = ".codex/config.toml";

  declared = {
    setPaths = [
      {
        path = [ "model" ];
        value = "gpt-6.1-sol";
      }
      {
        path = [ "model_reasoning_effort" ];
        value = "high";
      }
      {
        path = [ "service_tier" ];
        value = "default";
      }
      {
        path = [
          "agents"
          "default_subagent_model"
        ];
        value = "gpt-6.1-terra";
      }
      {
        path = [
          "agents"
          "default_subagent_reasoning_effort"
        ];
        value = "medium";
      }
      {
        path = [ "check_for_update_on_startup" ];
        value = false;
      }
      {
        path = [
          "features"
          "in_app_updates"
        ];
        value = false;
      }
      {
        path = [
          "features"
          "daemon_auto_start"
        ];
        value = false;
      }
      {
        path = [
          "features"
          "apps"
        ];
        value = false;
      }
      {
        path = [
          "features"
          "memories"
        ];
        value = false;
      }
      {
        path = [
          "features"
          "computer_use"
        ];
        value = false;
      }
      {
        path = [
          "plugins"
          "computer-use@openai-bundled"
          "enabled"
        ];
        value = false;
      }
      {
        path = [
          "plugins"
          "unified-computer-use@openai-bundled"
          "enabled"
        ];
        value = false;
      }
    ];
    remove = [ "developer_instructions" ];
    # The fff MCP server by its store path, so the T3 Code Codex instance,
    # which shares this file but not the login PATH, still starts it.
    ownEntries = [
      {
        path = [ "mcp_servers" ];
        entries.fff = {
          command = "${pkgs.fff-mcp}/bin/fff-mcp";
          args = [ "--no-update-check" ];
        };
      }
    ];
  };
  expected = pkgs.writeText "codex-expected-settings.json" (builtins.toJSON declared);

  seed = ''
    # user comment survives
    model = "old-model"
    model_reasoning_effort = "low"
    service_tier = "priority"
    developer_instructions = "retired"
    unrelated = "keep me"
    [features]
    apps = true
    computer_use = true
    [agents]
    default_subagent_model = "old-child"
    default_subagent_reasoning_effort = "low"
    max_threads = 3
    [projects."/scratch/project"]
    trust_level = "trusted"
    [plugins."example@local"]
    enabled = true
    [plugins."computer-use@openai-bundled"]
    enabled = true
    [plugins."unified-computer-use@openai-bundled"]
    enabled = true
    [mcp_servers.local]
    command = "local-mcp-server"
  '';
  applied = {
    model = "gpt-6.1-sol";
    model_reasoning_effort = "high";
    service_tier = "default";
    unrelated = "keep me";
    agents = {
      default_subagent_model = "gpt-6.1-terra";
      default_subagent_reasoning_effort = "medium";
      max_threads = 3;
    };
    projects."/scratch/project".trust_level = "trusted";
    plugins = {
      "example@local".enabled = true;
      "computer-use@openai-bundled".enabled = false;
      "unified-computer-use@openai-bundled".enabled = false;
    };
    mcp_servers = {
      local.command = "local-mcp-server";
      fff = {
        command = "${pkgs.fff-mcp}/bin/fff-mcp";
        args = [ "--no-update-check" ];
      };
    };
    check_for_update_on_startup = false;
    features = {
      apps = false;
      in_app_updates = false;
      daemon_auto_start = false;
      memories = false;
      computer_use = false;
    };
  };
  assertHost =
    entry:
    let
      hostName = entry.name;
      userConfig = entry.user;
      activation = userConfig.home.activation.codexSettings or null;
      script = if activation == null then "" else (activation.data or "");
      runsAfterPackages = lib.elem "installPackages" (
        if activation == null then [ ] else (activation.after or [ ])
      );
      targeted = lib.any (file: (file.target or "") == settingsFile) (
        lib.attrValues (userConfig.home.file or { })
      );

      activationAbsent = lib.optionalString (activation == null) ''
        echo 'missing home.activation.codexSettings on ${hostName}' >&2
        failed=1
      '';

      activationPresent = lib.optionalString (activation != null) ''
        if [ ${esc (lib.boolToString runsAfterPackages)} != "true" ]; then
          echo 'home.activation.codexSettings must run after installPackages on ${hostName}' >&2
          failed=1
        fi

        if ! printf '%s' ${esc script} | grep -F '/bin/agent-settings' >/dev/null; then
          echo 'the codexSettings activation script must invoke the packaged merger on ${hostName}' >&2
          failed=1
        fi

        formatArg=$(printf '%s' ${esc script} \
          | tr '\n' ' ' | grep -oE -- '--format[[:space:]]+[^[:space:]]+' \
          | sed -n '1p' | awk '{print $2}' || true)
        if [ "$formatArg" != toml ]; then
          echo "codexSettings must run the merger with --format toml on ${hostName}, got: '$formatArg'" >&2
          failed=1
        fi

        # Comment lines are stripped first, as in tests/claude.nix, so a comment
        # explaining why the swallow is absent cannot fail the honest script.
        if printf '%s' ${esc script} | grep -v '^[[:space:]]*#' \
          | grep -E '(\|\|[[:space:]]*(true|:|echo)|;[[:space:]]*true|set \+e)' >/dev/null; then
          echo 'the codexSettings activation script must not swallow the merger exit status on ${hostName}' >&2
          failed=1
        fi

        settingsArg=$(printf '%s' ${esc script} \
          | tr '\n' ' ' | grep -oE -- '--settings[[:space:]]+[^[:space:]]+' \
          | sed -n '1p' | awk '{print $2}' || true)
        if [ "$settingsArg" != ${esc "${userConfig.home.homeDirectory or ""}/${settingsFile}"} ]; then
          echo "codexSettings must point the merger at ~/${settingsFile} on ${hostName}, got: '$settingsArg'" >&2
          failed=1
        fi

        declaredPath=$(printf '%s' ${esc script} \
          | tr '\n' ' ' | grep -oE -- '--declared[[:space:]]+/nix/store/[^[:space:]]+' \
          | sed -n '1p' | awk '{print $2}' || true)
        if [ -z "$declaredPath" ]; then
          echo 'the codexSettings activation script passes no declared-settings file on ${hostName}' >&2
          failed=1
        elif ! diff -u "$declaredPath" ${expected} >/dev/null; then
          echo 'the declared keys codexSettings renders drifted from the asserted values on ${hostName}' >&2
          failed=1
        fi
      '';
    in
    ''
      ${activationAbsent}${activationPresent}
      ${executeActivation {
        inherit script;
        home = userConfig.home.homeDirectory or "";
        contract = {
          file = settingsFile;
          format = "toml";
          inherit declared;
          inherit seed;
          expected = applied;
        };
      }}
      if [ ${esc (lib.boolToString targeted)} != "false" ]; then
        echo 'Home Manager must not target ~/${settingsFile} on ${hostName}; Codex owns it' >&2
        failed=1
      fi
    '';
in
pkgs.runCommand "codex-settings-tests" { nativeBuildInputs = [ pkgs.diffutils ]; } ''
  ${configurations.userGuard}
  failed=0

  ${lib.concatMapStringsSep "\n" assertHost configurations.userEntries}

    if [ "$failed" != "0" ]; then
      exit 1
    fi

    touch $out
''
