{
  config,
  pkgs,
  lib,
  inputs,
  ...
}:
let
  agentTools = import ../../../packages/agent-tools.nix { inherit pkgs; };
  syncTool = "${agentTools.agentPluginSync}/bin/agent-plugin-sync";

  # Single source of truth with home/h82/default.nix's package list, so each
  # command's --cli flag can never drift onto a different agent build.
  claudeCode = import ../../../packages/claude-code.nix { inherit pkgs; };
  codex = import ../../../packages/codex.nix { inherit pkgs; };

  pins = import ./agent-plugin-pins.nix;

  sources = {
    compound-engineering = pins.compound-engineering // {
      src = inputs.compound-engineering-plugin;
    };
  };

  # Harness membership is declared separately from the source, so adding a
  # plugin to another agent is a row rather than a second source entry.
  membership = [
    {
      name = "compound-engineering";
      harness = "claude";
    }
    {
      name = "compound-engineering";
      harness = "codex";
    }
  ];

  # The CLI each harness is driven through, and the environment it runs with.
  # Activation carries neither home.packages on PATH nor
  # home.sessionVariables, so Claude Code's declared tier is exported around
  # it; Codex's update overrides travel inside its wrapper.
  harnesses = {
    claude = {
      cli = "${claudeCode}/bin/claude";
      env = claudeEnv;
    };
    # T3 Code's Codex sessions run on ~/.codex, so the sync must install there
    # even when the apply inherits a CODEX_HOME from the shell that ran it.
    codex = {
      cli = "${codex}/bin/codex";
      env = "-u CODEX_HOME";
    };
  };
  knownHarnesses = lib.attrNames harnesses;

  badHarness = lib.filter (row: !(lib.elem row.harness knownHarnesses)) membership;
  badName = lib.filter (row: !(sources ? ${row.name})) membership;

  # An unknown harness or plugin name stops evaluation rather than silently
  # installing nothing, which would look identical to a working configuration.
  checkedMembership =
    lib.throwIf (badHarness != [ ])
      "agent-plugins: membership names unknown harness(es): ${
        lib.concatMapStringsSep ", " (row: row.harness) badHarness
      }"
      (
        lib.throwIf (badName != [ ]) "agent-plugins: membership names undeclared plugin(s): ${
          lib.concatMapStringsSep ", " (row: row.name) badName
        }" membership
      );

  baseDir = "${config.home.homeDirectory}/.local/share/agent-plugins";

  # A source's segment is its tag without the train prefix, the same version
  # the materialized path is keyed by.
  segmentOf = spec: lib.removePrefix spec.tagPrefix spec.tag;

  # Read the declared values rather than restating them: claude.nix owns this
  # tier, and the activation unit carries neither home.packages on PATH nor
  # home.sessionVariables, so the CLI would otherwise run on upstream defaults.
  claudeEnvKeys = [
    "DISABLE_AUTOUPDATER"
    "CLAUDE_CODE_DISABLE_AUTO_MEMORY"
  ];
  claudeEnv = lib.concatMapStringsSep " " (
    key: "${key}=${lib.escapeShellArg (toString config.home.sessionVariables.${key})}"
  ) (lib.filter (key: config.home.sessionVariables ? ${key}) claudeEnvKeys);

  syncInvocation =
    row:
    let
      spec = sources.${row.name};
      harness = harnesses.${row.harness};
    in
    ''
      env ${harness.env} ${syncTool} \
        --harness ${row.harness} \
        --cli ${harness.cli} \
        --source ${spec.src} \
        --base ${lib.escapeShellArg "${baseDir}/${row.name}"} \
        --segment ${lib.escapeShellArg (segmentOf spec)} \
        --plugin ${lib.escapeShellArg spec.plugin} \
        --marketplace ${lib.escapeShellArg spec.marketplace}'';

  # Plugins this repository used to install and has since dropped. Removing a
  # row from `sources` alone leaves the plugin registered with its agent, and
  # its hooks keep firing, on every machine that ran an earlier generation.
  # Move it here instead, and delete the entry once every host has rebuilt
  # past it.
  retired = [ ];

  retireInvocation =
    row:
    let
      harness = harnesses.${row.harness};
    in
    ''
      env ${harness.env} ${syncTool} --retire \
        --harness ${row.harness} \
        --cli ${harness.cli} \
        --base ${lib.escapeShellArg "${baseDir}/${row.name}"} \
        --plugin ${lib.escapeShellArg row.plugin} \
        --marketplace ${lib.escapeShellArg row.marketplace}'';

  withDryRun = invocation: ''
    if [[ -v DRY_RUN ]]; then
      ${invocation} --dry-run
    else
      ${invocation}
    fi
  '';

  # Every harness row of a source shares one base, and each retire deletes the
  # whole base after the membership rows ran, so retiring one harness while
  # another keeps the source would delete that harness's live link on every
  # activation. Retire every row of a source together, or split the base.
  stillMember = lib.filter (row: lib.any (member: member.name == row.name) checkedMembership) retired;

  syncScript =
    lib.throwIf (stillMember != [ ])
      "agent-plugins: retired row(s) still named in membership, which share its link: ${
        lib.concatMapStringsSep ", " (row: "${row.name} (${row.harness})") stillMember
      }"
      (
        lib.concatStringsSep "\n" (
          map (row: withDryRun (syncInvocation row)) checkedMembership
          ++ map (row: withDryRun (retireInvocation row)) retired
        )
      );
in
{
  # Run after installPackages so a sync failure cannot prevent package
  # installation. linkGeneration runs later.
  #
  # The version-keyed path is created here rather than declared as a Home
  # Manager file: this entry runs before linkGeneration, so a declared link
  # would not yet exist when the wiring reads it, and creating it here also
  # keeps the superseded version present until the new one is wired.
  home.activation.agentPlugins = lib.hm.dag.entryAfter [ "installPackages" ] syncScript;
}
