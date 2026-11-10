{
  config,
  lib,
  pkgs,
  ...
}:
let
  prepare = pkgs.writeTextDir "macos-container.sh" (
    builtins.readFile ../../scripts/macos-container.sh
  );
  state = pkgs.writeTextDir "macos-container-state.sh" (
    builtins.readFile ../../scripts/macos-container-state.sh
  );
  scripts = pkgs.symlinkJoin {
    name = "macos-container-setup";
    paths = [
      prepare
      state
    ];
  };
in
{
  # Explicit system activation, never a workload or cluster watchdog.
  system.activationScripts.postActivation.text = lib.mkBefore ''
    /usr/bin/sudo --user=${lib.escapeShellArg config.my.user.name} --set-home /usr/bin/env PATH="${config.homebrew.prefix}/bin:${lib.makeBinPath [ pkgs.jq ]}:/usr/bin:/bin" /bin/sh ${scripts}/macos-container.sh
  '';
}
