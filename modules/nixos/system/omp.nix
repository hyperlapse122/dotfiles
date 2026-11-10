{
  config,
  lib,
  pkgs,
  ...
}:
let
  user = config.my.user.name;
  home = config.my.user.home;
  declared = config.home-manager.users.${user}.my.omp.declaration;
  tools = import ../../../packages/agent-tools.nix { inherit pkgs; };
in
{
  # System activation runs on unchanged-generation switches too. Run with the
  # account's uid/HOME, never root ownership or an activation shell's profile.
  system.activationScripts.ompSettings = {
    deps = [ "users" ];
    text = ''
      if ! ${pkgs.util-linux}/bin/runuser -u ${lib.escapeShellArg user} -- \
        ${pkgs.coreutils}/bin/env HOME=${lib.escapeShellArg home} \
        ${tools.ompConfigReconcile}/bin/omp-config-reconcile \
        --agent-dir ${lib.escapeShellArg "${home}/.omp/agent"} \
        --declared ${declared}; then
        echo 'OMP common configuration restoration failed' >&2
        exit 1
      fi
    '';
  };
}
