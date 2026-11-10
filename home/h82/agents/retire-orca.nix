{
  config,
  pkgs,
  lib,
  ...
}:
let
  retireOrca = lib.getExe (import ../../../packages/agent-tools.nix { inherit pkgs; }).retireOrca;
in
{
  # Orca, which this repository stopped installing, left hooks in the agents'
  # settings files (one of them a PermissionRequest hook that voids Claude
  # Code's dangerous-rm waiver), a Claude status line, and its state
  # directories. Kept while any home may still hold them. It runs only when a
  # rebuild produces a new Home Manager generation (and on every non-NixOS or
  # macOS apply), costs nothing once the leftovers are gone, and never fails
  # the rebuild. Ordered after every merge that writes the same files, so the
  # two never race and the merge's result is what gets cleaned.
  home.activation.retireOrca =
    lib.hm.dag.entryAfter
      [
        "installPackages"
        "agentPlugins"
        "claudeSettings"
        "claudeGlobalConfig"
        "codexSettings"
        "antigravitySettings"
      ]
      ''
        if [[ ! -v DRY_RUN ]]; then
          ${retireOrca} --home "$HOME" ${lib.optionalString (config.my.kind == "darwin") "--macos"} || true
        fi
      '';
}
