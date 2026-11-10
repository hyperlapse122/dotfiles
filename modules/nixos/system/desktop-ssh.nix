{
  config,
  lib,
  pkgs,
  ...
}:
let
  enabled = !config.my.bootstrap && config.my.kind == "nixos";
  user = config.my.user.name;
  home = config.my.user.home;
  source = config.my.desktopSSH.sopsFile;
  publicKey = config.my.desktopSSH.publicKey;
  helper = import ../../../packages/desktop-ssh-session-active.nix { inherit pkgs; };
  tool = import ../../../packages/desktop-ssh.nix { inherit pkgs; };
  gate = lib.escapeShellArgs [
    "${helper}/bin/desktop-ssh-session-active"
    user
  ];
in
{
  options.my.desktopSSH = {
    sopsFile = lib.mkOption {
      type = lib.types.path;
      default = ../../../secrets/hosts + "/${config.my.hostName}/ssh.yaml";
      description = "Host-only encrypted recovery source for the desktop SSH key.";
    };
  };
  config = lib.mkIf enabled {
    my.desktopSSH.publicKey = lib.mkDefault (../../../secrets/hosts + "/${config.my.hostName}/ssh.pub");
    sops.secrets.desktop-ssh-source = {
      sopsFile = source;
      key = "ssh_private_key";
      owner = "root";
      mode = "0400";
    };
    systemd.tmpfiles.rules = [ "d ${home}/.ssh 0700 ${user} users - -" ];
    systemd.services.desktop-ssh-provision = {
      description = "Protect the host SSH key with its KWallet password";
      serviceConfig = {
        Type = "oneshot";
        User = user;
        UMask = "0077";
        LimitCORE = 0;
        TimeoutStartSec = 90;
        ExecCondition = gate;
        LoadCredential = "source:${config.sops.secrets.desktop-ssh-source.path}";
        ExecStart = lib.escapeShellArgs [
          "${tool}/bin/desktop-ssh"
          "provision"
          "--source"
          "%d/source"
          "--public-key"
          "${publicKey}"
          "--key-file"
          "${home}/.ssh/id_ed25519_nix_config"
        ];
      };
    };
    security.polkit.extraConfig = ''
      polkit.addRule(function(action, subject) {
        if (action.id == "org.freedesktop.systemd1.manage-units" &&
            action.lookup("unit") == "desktop-ssh-provision.service") {
          if (subject.user != ${builtins.toJSON user}) return polkit.Result.NO;
          if (action.lookup("verb") == "stop") return polkit.Result.YES;
          if (action.lookup("verb") != "start") return polkit.Result.NO;
          try {
            polkit.spawn(["${helper}/bin/desktop-ssh-session-active", ${builtins.toJSON user}]);
            return polkit.Result.YES;
          } catch (error) { return polkit.Result.NO; }
        }
      });
    '';
  };
}
