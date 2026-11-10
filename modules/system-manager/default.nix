{
  config,
  lib,
  pkgs,
  ...
}:
let
  # The reader drivers pcscd loads, as the NixOS services.pcscd module
  # provides them. Without ccid, pcscd sees no YubiKey reader at all, and the
  # user's scdaemon (disable-ccid, pcsc-shared) depends entirely on pcscd.
  pcscPlugins = pkgs.buildEnv {
    name = "pcscd-plugins";
    paths = [ "${pkgs.ccid}/pcsc/drivers" ];
  };

  # An empty reader.conf keeps pcscd from scanning its whole config directory;
  # see https://github.com/NixOS/nixpkgs/issues/121088.
  readerConf = pkgs.writeText "reader.conf" "";
in
{
  imports = [
    ../shared/nix-settings.nix
  ];

  # nixpkgs moved the default service PATH into config.systemd.defaultPath,
  # which nixos/lib/systemd-lib.nix reads on every service before
  # system-manager declares it (numtide/system-manager#587). Leave type,
  # default, and description unset on the option and set the fallback below
  # mkOptionDefault (1500) so any upstream default or definition wins cleanly
  # without duplicate list entries once merged.
  options.systemd.defaultPath = lib.mkOption { };

  config = {
    systemd.defaultPath = lib.mkOverride 1600 [
      pkgs.coreutils
      pkgs.findutils
      pkgs.gnugrep
      pkgs.gnused
      config.systemd.package
    ];

    # The distribution owns its user database; system-manager must never write
    # /etc/passwd, /etc/group, or /etc/shadow on a host it does not own.
    services.userborn.enable = false;

    # Read by the non-NixOS `nr` to learn which host and variant it applies,
    # instead of guessing the host from `uname -n`, which the distribution owns.
    environment.etc."nix-config-host".text = ''
      host=${config.my.hostName}
      variant=${if config.my.bootstrap then "bootstrap" else "production"}
    '';

    # nix.conf is the flake's to own, as it is on NixOS: this replaces the
    # installer's copy and keeps it as nix.conf.system-manager-backup. The
    # upstream module drops the installer's build-users-group, so it is set here
    # to keep builds running as the unprivileged nixbld users.
    nix.enable = true;
    nix.settings.build-users-group = "nixbld";

    # pcscd runs as root with no socket-activation dependency on a distribution
    # package: the unit and socket are written here, and the preflight in `nr`
    # refuses to run while a distribution pcscd unit exists alongside them.
    # This pcsclite has no polkit, so the socket itself is the access boundary:
    # only the host account's private group reaches the card, as a desktop
    # session's polkit rule would allow on the distribution or on NixOS. The
    # preflight in `nr` checks that the group exists.
    systemd.sockets.pcscd = {
      description = "PC/SC Smart Card Daemon Activation Socket";
      wantedBy = [ "multi-user.target" ];
      socketConfig = {
        ListenStream = "/run/pcscd/pcscd.comm";
        SocketMode = "0660";
        SocketUser = "root";
        SocketGroup = config.my.user.name;
        RemoveOnStop = true;
      };
    };
    systemd.services.pcscd = {
      description = "PC/SC Smart Card Daemon";
      requires = [ "pcscd.socket" ];
      after = [ "pcscd.socket" ];
      environment.PCSCLITE_HP_DROPDIR = pcscPlugins;
      serviceConfig.ExecStart = "${lib.getExe pkgs.pcsclite} -f -x -c ${readerConf}";
    };
  };
}
