{ pkgs, self }:
let
  inherit (pkgs) lib;
  configurations = import ./lib/configurations.nix { inherit pkgs self; };
  package = import ../packages/desktop-ssh.nix { inherit pkgs; };
  python = pkgs.python3.withPackages (ps: [
    ps.cryptography
    ps.bcrypt
    ps.dbus-python
    ps.pyyaml
  ]);
  entries = map (entry: {
    inherit (entry) name kind bootstrap;
    files = toString (entry.user.home-files or "");
    sshConfig = toString (entry.user.my.ssh.configFile or "");
    sshActivation = entry.user.home.activation.sshConfig.data or "";
    sshAfter = entry.user.home.activation.sshConfig.after or [ ];
    path = toString (entry.user.home.path or "");
    home = entry.user.home.homeDirectory or "";
    user = entry.user.home.username or "";
    hostName = entry.user.my.hostName or "";
    legacyKey = entry.user.my.secrets.sshKey or "";
    package = toString package;
    fallbackConfig = builtins.readFile ../config/1password/agent.toml;
    systemUnit =
      if entry.kind == "nixos" then
        toString (
          self.nixosConfigurations.${entry.name}.config.environment.etc."systemd/system".source or ""
        )
      else
        "";
  }) configurations.userEntries;
in
pkgs.runCommand "desktop-ssh-tests"
  {
    nativeBuildInputs = [
      python
      pkgs.openssh
    ];
  }
  ''
    ${configurations.userGuard}
    python ${./check_desktop_ssh_config.py} --root ${../.} --entries ${pkgs.writeText "desktop-ssh-entries.json" (builtins.toJSON entries)}
    export DESKTOP_SSH_SCRIPT=${package}/bin/desktop-ssh
    python ${./test_desktop_ssh.py}
    touch $out
  ''
