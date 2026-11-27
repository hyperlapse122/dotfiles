/*
  One-shot cleanup for the retired T3 Code settings. The packages and the
  mutable settings module are gone; this entry removes only the values the
  repository declared, restores the launch arguments it composed, and then
  records that the cleanup ran. Conversations, worktrees, caches, and refs stay.
*/
{
  config,
  lib,
  pkgs,
  ...
}:
let
  agentTools = import ../../packages/agent-tools.nix { inherit pkgs; };
  merger = "${agentTools.agentSettings}/bin/agent-settings";
  profileDirectory = config.home.profileDirectory or "${config.home.homeDirectory}/.nix-profile";

  retire = pkgs.writeScriptBin "retire-t3" (
    "#!${pkgs.python3}/bin/python3\n" + builtins.readFile ../../scripts/retire-t3
  );

  settingsRemoval = pkgs.writeText "t3-retired-settings.json" (
    builtins.toJSON {
      remove = [
        "addProjectBaseDirectory"
        "autoResumeLimitedThreads"
        "branchNamingMode"
        "defaultAutoPull"
        "defaultModelSelection"
        "defaultRuntimeMode"
        "defaultThreadEnvMode"
        "enableAgentDeviceAccess"
        "enableDeviceSupport"
        "fallbackModelSelection"
        "ghqCloneLayout"
        "linkedEnvironmentsEnabled"
        "promptSuggestionsEnabled"
        "sidebarAutoSettleAfterDays"
        "sidebarAutoSettleKeepPullRequests"
        "sidebarAutoSettleOnMerge"
        "snoozeLimitedThreads"
        "textGenerationModelSelection"
        "threadTitleInstructions"
      ];
      removePaths = [
        {
          path = [ "sourceControlWritingStyle" ];
          key = "customInstructions";
          value = "";
          prune = true;
        }
        {
          path = [ "sourceControlWritingStyle" ];
          key = "mode";
          value = "conventional_commits";
          prune = true;
        }
        {
          path = [ "storageCleanup" ];
          key = "browserArtifactsAfterDays";
          value = 8;
          prune = true;
        }
        {
          path = [ "storageCleanup" ];
          key = "logsAfterDays";
          value = 8;
          prune = true;
        }
        {
          path = [ "storageCleanup" ];
          key = "worktreeAfterDays";
          value = 5;
          prune = true;
        }
        {
          path = [ "storageCleanup" ];
          key = "worktreeOnDelete";
          value = true;
          prune = true;
        }
        {
          path = [ "storageCleanup" ];
          key = "worktreeOnMerge";
          value = true;
          prune = true;
        }
        {
          path = [ "storageCleanup" ];
          key = "worktreeSettledAfterDays";
          value = 1;
          prune = true;
        }
        {
          path = [ "storageCleanup" ];
          key = "worktreeUnchanged";
          value = true;
          prune = true;
        }
        {
          path = [
            "providerInstances"
            "claudeAgent"
          ];
          key = "driver";
          value = "claudeAgent";
          prune = true;
        }
        {
          path = [
            "providerInstances"
            "claudeAgent"
          ];
          key = "enabled";
          value = true;
          prune = true;
        }
        {
          path = [
            "providerInstances"
            "claudeAgent"
            "config"
          ];
          key = "idleCompaction";
          value = "beforeCacheExpires";
          prune = true;
        }
        {
          path = [
            "providerInstances"
            "grok"
          ];
          key = "driver";
          value = "grok";
          prune = true;
        }
        {
          path = [
            "providerInstances"
            "grok"
          ];
          key = "enabled";
          value = false;
          prune = true;
        }
        {
          path = [
            "providerInstances"
            "opencode"
          ];
          key = "driver";
          value = "opencode";
          prune = true;
        }
        {
          path = [
            "providerInstances"
            "opencode"
          ];
          key = "enabled";
          value = true;
          prune = true;
        }
        {
          path = [
            "providerInstances"
            "opencode"
            "config"
          ];
          key = "enabled";
          value = true;
          prune = true;
        }
        {
          path = [
            "providerInstances"
            "opencode"
            "config"
          ];
          key = "binaryPath";
          value = "${profileDirectory}/bin/opencode";
          prune = true;
        }
        {
          path = [
            "providerInstances"
            "pi"
          ];
          key = "driver";
          value = "pi";
          prune = true;
        }
        {
          path = [
            "providerInstances"
            "pi"
          ];
          key = "enabled";
          value = true;
          prune = true;
        }
        {
          path = [
            "providerInstances"
            "pi"
            "config"
          ];
          key = "enabled";
          value = true;
          prune = true;
        }
        {
          path = [
            "providerInstances"
            "pi"
            "config"
          ];
          key = "binaryPath";
          value = "${profileDirectory}/bin/pi";
          prune = true;
        }
      ];
      removeEntries = [
        {
          path = [
            "providerInstances"
            "opencode"
            "environment"
          ];
          key = "name";
          values = [ "OPENCODE_CONFIG_CONTENT" ];
        }
      ];
    }
  );

  clientRemoval = pkgs.writeText "t3-retired-client-settings.json" (
    builtins.toJSON {
      remove = [
        "fontFamilyCode"
        "fontFamilySans"
        "fontFamilyTerminal"
        "inAppNotificationsEnabled"
        "notificationMode"
        "sidebarWorkingShelfEnabled"
        "snapShotEnabled"
      ];
    }
  );

  hiddenModels = import ./agents/pi-hidden-models.nix;
in
{
  home.activation.t3Retirement = lib.hm.dag.entryAfter [ "installPackages" ] ''
    if [[ ! -v DRY_RUN ]]; then
      ${retire}/bin/retire-t3 \
        --home ${lib.escapeShellArg config.home.homeDirectory} \
        --merger ${lib.escapeShellArg merger} \
        --settings-declaration ${settingsRemoval} \
        --client-declaration ${clientRemoval} \
        ${lib.concatMapStrings (model: "--hidden-model ${lib.escapeShellArg model} ") hiddenModels}
    fi
  '';
}
