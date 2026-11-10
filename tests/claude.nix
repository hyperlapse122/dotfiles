/*
  Check interface:

    import ./tests/claude.nix { inherit pkgs self; }

  Asserts that Claude Code's declared settings reach user `h82` through the
  right tier on every Home Manager user environment
  `tests/lib/configurations.nix` yields (`userEntries`): NixOS and non-NixOS
  hosts, production and bootstrap alike, since no tier depends on a host kind,
  a host trait, or `my.bootstrap`. The one exception, the stream idle timeout
  the network recovery trait adds on macOS, is checked by
  tests/darwin-config.nix.

  The declared set is split across three tiers. A setting whose persistent
  form is an environment variable is declared through session variables; a key
  Claude Code reads only from its global config is written into ~/.claude.json
  at activation; everything else is written into ~/.claude/settings.json at
  activation. Claude Code rewrites both files itself, so a read-only store
  symlink cannot live at either. The managed settings tier is deliberately
  unused: it blocks a change even inside a running session. A plugin is
  enabled through one leaf of settings.json's enabledPlugins object, declared
  as a nested path so the merge leaves every other plugin's entry alone.

  Verifies, per configuration:
  - every environment-tier variable carries its declared value.
  - for each merge -- home.activation.claudeSettings into
    ~/.claude/settings.json and home.activation.claudeGlobalConfig into
    ~/.claude.json -- the activation exists, runs after installPackages,
    invokes the packaged merger on that file, and does not swallow the merger's
    exit status, so a symlinked or malformed file fails the rebuild instead of
    passing silently.
  - the JSON this repository renders for each merge carries every declared key
    and nested path at its declared value and lists every retired key for
    removal. It declares no effort, so an effort level already in the file,
    top-level or per model, survives the merge.
    Asserting the rendered file rather than the Nix attribute set keeps the
    check on what activation actually feeds the merger.
  - no environment.etc entry declares claude-code/managed-settings.json, on
    each NixOS configuration (`entries`), the only kind with environment.etc.
  - no Home Manager file targets either merged file. An activation-time
    merge and a store symlink are mutually exclusive, so this assertion now
    guards the mechanism rather than contradicting it. Home Manager resolves a
    file's destination from `target`, which only defaults to the attribute
    name, so the lookup compares resolved targets rather than attribute names.

  Whether the merge preserves undeclared keys is not assertable from evaluated
  configuration at all -- it is behaviour of the packaged script. The
  `agent-settings` check in flake.nix runs that script against a seeded,
  divergent settings file instead.

  Every lookup carries an `or` fallback so a mutation that removes an entry or
  a key reaches the builder as shell rather than failing evaluation on a null
  interpolation. See
  .compound-engineering/artifacts/solutions/best-practices/unguarded-derivation-interpolation-defeats-nix-check-mutation-testing.md

  The builder collects every failure instead of exiting at the first, so one
  red build names every broken assertion across every configuration.
*/
{ pkgs, self }:
let
  inherit (pkgs) lib;

  configurations = import ./lib/configurations.nix { inherit pkgs self; };

  esc = value: lib.escapeShellArg (toString value);

  executeActivation = import ./lib/agent-activation.nix { inherit pkgs; };

  environmentTier = {
    DISABLE_AUTOUPDATER = "1";
    CLAUDE_CODE_DISABLE_AUTO_MEMORY = "1";
    CLAUDE_CODE_MAX_CONCURRENT_SUBAGENTS = "20";
    CLAUDE_CODE_MAX_SUBAGENT_SPAWN_DEPTH = "1";
    CLAUDE_CODE_EVEN_MORE_DANGEROUSLY_SKIP_PERMISSIONS = "1";
  };

  settingsTier = {
    model = "opus[1m]";
    theme = "auto";
    preferredNotifChannel = "ghostty";
    agentPushNotifEnabled = false;
    inputNeededNotifEnabled = false;
    cleanupPeriodDays = 30;
    disableClaudeAiConnectors = true;
  };

  retiredKeys = [
    "advisorModel"
    "autoCompactWindow"
    "language"
  ];

  settingsPaths = [
    {
      path = [
        "enabledPlugins"
        "cc-plugin-you-should-know@builtin"
      ];
      value = true;
    }
    {
      path = [
        "worktree"
        "baseRef"
      ];
      value = "head";
    }
  ];

  globalConfigTier = {
    leftArrowOpensAgents = false;
  };

  # The user-scope fff MCP server, by its store path so a GUI or T3 Code
  # session that lacks the login PATH still starts it.
  globalConfigEntries = [
    {
      path = [ "mcpServers" ];
      entries.fff = {
        type = "stdio";
        command = "${pkgs.fff-mcp}/bin/fff-mcp";
        args = [ "--no-update-check" ];
      };
    }
  ];

  expectedDeclared =
    name: set: remove: setPaths:
    pkgs.writeText name (
      builtins.toJSON {
        inherit set remove setPaths;
      }
    );

  merges = [
    {
      attr = "claudeSettings";
      file = ".claude/settings.json";
      declared = {
        set = settingsTier;
        remove = retiredKeys;
        setPaths = settingsPaths;
      };
      expected = expectedDeclared "claude-expected-settings.json" settingsTier retiredKeys settingsPaths;
    }
    {
      attr = "claudeGlobalConfig";
      file = ".claude.json";
      declared = {
        set = globalConfigTier;
        ownEntries = globalConfigEntries;
      };
      expected = pkgs.writeText "claude-expected-global-config.json" (
        builtins.toJSON {
          set = globalConfigTier;
          ownEntries = globalConfigEntries;
        }
      );
    }
  ];

  assertUser =
    entry:
    let
      hostName = entry.name;
      userConfig = entry.user;
      sessionVariables = userConfig.home.sessionVariables or { };

      environmentChecks = lib.concatStringsSep "\n" (
        lib.mapAttrsToList (name: value: ''
          actual=${esc (sessionVariables.${name} or "")}
          if [ "$actual" != ${esc value} ]; then
            echo "Expected ${name} to be ${value} on ${hostName}, got: '$actual'" >&2
            failed=1
          fi
        '') environmentTier
      );

      mergeChecks =
        merge:
        let
          activation = userConfig.home.activation.${merge.attr} or null;
          script = if activation == null then "" else (activation.data or "");
          # After installPackages, so a refusal cannot strand linkGeneration and
          # installPackages behind it. Asserting writeBoundary instead would pass
          # the position that causes that, since installPackages is itself after
          # writeBoundary.
          runsAfterPackages = lib.elem "installPackages" (
            if activation == null then [ ] else (activation.after or [ ])
          );

          # Home Manager resolves each entry's destination from `target`, which
          # defaults to the attribute name but can be set explicitly, so an
          # attribute-name test would miss a renamed entry.
          targeted = lib.any (file: (file.target or "") == merge.file) (
            lib.attrValues (userConfig.home.file or { })
          );

          activationAbsent = lib.optionalString (activation == null) ''
            echo 'missing home.activation.${merge.attr} on ${hostName}' >&2
            failed=1
          '';

          activationPresent = lib.optionalString (activation != null) ''
            if [ ${esc (lib.boolToString runsAfterPackages)} != "true" ]; then
              echo 'home.activation.${merge.attr} must run after installPackages on ${hostName}' >&2
              failed=1
            fi

            if ! printf '%s' ${esc script} | grep -F '/bin/agent-settings' >/dev/null; then
              echo 'the ${merge.attr} activation script must invoke the packaged merger on ${hostName}' >&2
              failed=1
            fi

            # Swallowing the merger's exit status turns a refusal into a silent
            # no-op, which is the failure mode the no-swallow rule exists for.
            # `|| true` is only the most obvious spelling, so this matches the
            # equivalents too -- a check that names one of them lets the others
            # through while reporting the guarantee as held. The merger invocation
            # spans several lines, so this looks anywhere in this single-purpose
            # block rather than on the line naming the binary; a line-anchored
            # pattern silently passes the mutation that adds the swallow. Comment
            # lines are stripped first, because the block documents why the swallow
            # is absent and matching that sentence would fail the honest script.
            if printf '%s' ${esc script} | grep -v '^[[:space:]]*#' \
              | grep -E '(\|\|[[:space:]]*(true|:|echo)|;[[:space:]]*true|set \+e)' >/dev/null; then
              echo 'the ${merge.attr} activation script must not swallow the merger exit status on ${hostName}' >&2
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
              file = merge.file;
              declared = merge.declared;
            }
            // lib.optionalAttrs (merge.attr == "claudeGlobalConfig") {
              # A server the user added with `claude mcp add -s user` must
              # survive beside the declared one.
              seed = {
                activationUnmanaged = "keep";
                leftArrowOpensAgents = true;
                mcpServers.other.command = "other";
              };
              preservePaths = [
                [ "activationUnmanaged" ]
                [
                  "mcpServers"
                  "other"
                ]
              ];
            }
            // lib.optionalAttrs (merge.attr == "claudeSettings") {
              seed = {
                activationUnmanaged = "keep";
                language = "korean";
                advisorModel = "retired";
                autoCompactWindow = "retired";
                effortLevel = "retired";
                model = "divergent";
                enabledPlugins.custom = false;
                worktree.custom = "keep";
                modelSettings = {
                  claude-opus-5-5.effortLevel = "medium";
                  custom.effortLevel = "high";
                };
              };
              expected = {
                activationUnmanaged = "keep";
                effortLevel = "retired";
                model = "opus[1m]";
                theme = "auto";
                preferredNotifChannel = "ghostty";
                agentPushNotifEnabled = false;
                inputNeededNotifEnabled = false;
                cleanupPeriodDays = 30;
                disableClaudeAiConnectors = true;
                enabledPlugins = {
                  custom = false;
                  "cc-plugin-you-should-know@builtin" = true;
                };
                worktree = {
                  custom = "keep";
                  baseRef = "head";
                };
                modelSettings = {
                  claude-opus-5-5.effortLevel = "medium";
                  custom.effortLevel = "high";
                };
              };
            };
          }}
          # Read the flags the merger is actually invoked with, not merely whether
          # the script mentions a path somewhere. A check that greps for the store
          # path anywhere in the text passes a script that names the right file in
          # a comment and hands the merger a different one, and a check that
          # re-derives the JSON from this file's own attribute set compares a
          # literal against itself, which no mutation of the module can turn red.
          # The builder runs under `set -e -o pipefail`, so a non-matching grep
          # would abort before the remaining assertions ran and leave one mutation
          # round with evidence about a single assertion.
          settingsArg=$(printf '%s' ${esc script} \
            | tr '\n' ' ' | grep -oE -- '--settings[[:space:]]+[^[:space:]]+' \
            | sed -n '1p' | awk '{print $2}' || true)
          if [ "$settingsArg" != ${esc "${userConfig.home.homeDirectory or ""}/${merge.file}"} ]; then
            echo "${merge.attr} must point the merger at ~/${merge.file} on ${hostName}, got: '$settingsArg'" >&2
            failed=1
          fi

          declaredPath=$(printf '%s' ${esc script} \
            | tr '\n' ' ' | grep -oE -- '--declared[[:space:]]+/nix/store/[^[:space:]]+' \
            | sed -n '1p' | awk '{print $2}' || true)
          if [ -z "$declaredPath" ]; then
            echo 'the ${merge.attr} activation script passes no declared-settings file on ${hostName}' >&2
            failed=1
          elif ! diff -u "$declaredPath" ${merge.expected} >/dev/null; then
            echo 'the declared keys ${merge.attr} renders drifted from the asserted values on ${hostName}' >&2
            failed=1
          fi

          if [ ${esc (lib.boolToString targeted)} != "false" ]; then
            echo 'Home Manager must not target ~/${merge.file} on ${hostName}; Claude Code owns it' >&2
            failed=1
          fi
        '';
    in
    ''
      ${environmentChecks}
      ${lib.concatMapStringsSep "\n" mergeChecks merges}
    '';

  # environment.etc exists only on a NixOS system configuration, so this one
  # assertion runs over the NixOS entries alone.
  assertManagedUnused =
    entry:
    let
      managed = entry.config.environment.etc."claude-code/managed-settings.json" or null;
    in
    lib.optionalString (managed != null) ''
      echo 'the managed settings tier must stay unused, but ${entry.name} declares claude-code/managed-settings.json' >&2
      failed=1
    '';
in
pkgs.runCommand "claude-tests" { nativeBuildInputs = [ pkgs.diffutils ]; } ''
  set -x
  ${configurations.guard}
  ${configurations.userGuard}
  failed=0

  ${lib.concatMapStringsSep "\n" assertUser configurations.userEntries}
  ${lib.concatMapStringsSep "\n" assertManagedUnused configurations.entries}

  if [ "$failed" != "0" ]; then
    exit 1
  fi

  touch $out
''
