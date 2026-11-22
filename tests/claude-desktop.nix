{ pkgs, self }:
let
  inherit (import ./lib/host-check-helpers.nix { inherit pkgs self; })
    forEveryConfiguration
    assertUserPackage
    ;
  assertConfiguration =
    entry:
    let
      hasKvmGroup = builtins.elem "kvm" entry.config.users.users.${entry.config.my.user.name}.extraGroups;
      hasVhostVsock = builtins.elem "vhost_vsock" entry.config.boot.kernelModules;
    in
    ''
      ${assertUserPackage {
        pname = "claude-desktop";
        executables = [ "claude-desktop" ];
        desktopEntries = [ "com.anthropic.Claude.desktop" ];
      } entry}
      ${pkgs.lib.optionalString (!hasKvmGroup) ''
        echo 'user ${entry.config.my.user.name} missing kvm group on ${entry.name}' >&2
        fail=1
      ''}
      ${pkgs.lib.optionalString (!hasVhostVsock) ''
        echo 'missing vhost_vsock kernel module on ${entry.name}' >&2
        fail=1
      ''}
    '';
in
pkgs.runCommand "claude-desktop-tests" { } ''
  set -x
  ${forEveryConfiguration assertConfiguration}
  touch $out
''
