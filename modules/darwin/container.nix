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
  # nix-homebrew leaves the prefix root-owned and omits libexec. Homebrew's
  # post-install sandbox can populate it only after root creates these paths.
  system.activationScripts.setup-homebrew.text = lib.mkAfter ''
    /usr/bin/install -d -o ${lib.escapeShellArg config.my.user.name} -g admin -m 0755 ${config.homebrew.prefix}/libexec ${config.homebrew.prefix}/libexec/container-plugins
  '';

  # Explicit system activation, never a workload or cluster watchdog. It runs
  # in the user's launchd context so the login service can register in
  # gui/<uid>.
  system.activationScripts.postActivation.text = lib.mkBefore ''
    /bin/launchctl asuser "$(id -u -- ${lib.escapeShellArg config.my.user.name})" /usr/bin/sudo --user=${lib.escapeShellArg config.my.user.name} --set-home /usr/bin/env HOMEBREW_PREFIX="${config.homebrew.prefix}" PATH="${config.homebrew.prefix}/bin:${lib.makeBinPath [ pkgs.jq ]}:/usr/bin:/bin" /bin/sh ${scripts}/macos-container.sh
  '';
}
