{
  config,
  lib,
  pkgs,
  ...
}:
let
  package = import ../../../packages/wifiman-desktop.nix { inherit pkgs; };
  bundled = "${package}/lib/wifiman-desktop";
  stateDir = "/var/lib/wifiman-desktop";
  helperNames = [
    "wg"
    "wg-quick"
    "wireguard-go"
  ];
  # `path` adds each entry's bin/, which the bundled directory lacks.
  helpers = pkgs.linkFarm "wifiman-desktop-helpers" (
    map (helper: {
      name = "bin/${helper}";
      path = "${bundled}/${helper}";
    }) helperNames
  );
in
{
  # The GUI, which home/h82/default.nix installs under the same trait, talks to
  # this daemon on 127.0.0.1:63150. The upstream .deb registers the same unit
  # from its postinst script.
  config = lib.mkIf config.my.wifiman.enable {
    systemd.services.wifiman-desktop = {
      description = "WiFiman Desktop daemon";
      after = [ "network.target" ];
      wantedBy = [ "multi-user.target" ];

      # It runs `sh -c` pipelines through PATH, `nmcli` for Wi-Fi scans, and
      # wg-quick, which needs the firewall tool for a full tunnel; an
      # ExecStart unit gets no bash on its default path.
      path = [
        helpers
        pkgs.bash
        pkgs.gawk
        pkgs.iw
        pkgs.iproute2
        pkgs.nettools
        pkgs.procps
        config.networking.networkmanager.package
        config.networking.resolvconf.package
        config.networking.firewall.package
      ];

      # The daemon reads .env and writes service.json, utun.conf, and its log
      # under $BASE, which defaults to its own read-only store directory. The
      # helpers it runs from there are linked in, except wg_report.sh: the
      # daemon chmods it before running it, which a link into the store fails.
      environment.BASE = stateDir;
      preStart = ''
        for helper in .env ${lib.escapeShellArgs helperNames}; do
          ln -sfn ${bundled}/$helper ${stateDir}/$helper
        done
        install -m 0755 ${bundled}/wg_report.sh ${stateDir}/wg_report.sh
      '';

      serviceConfig = {
        ExecStart = "${bundled}/wifiman-desktopd";
        StateDirectory = "wifiman-desktop";
        # utun.conf holds the Teleport tunnel's private key.
        StateDirectoryMode = "0700";
        Restart = "always";
        RestartSec = 30;
      };
    };
  };
}
