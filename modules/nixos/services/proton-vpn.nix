{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.my.protonVpn;
in
{
  options.my.protonVpn = {
    enable = lib.mkEnableOption "the official Proton VPN app alongside Tailscale";
  };

  config = lib.mkIf cfg.enable {
    environment.systemPackages = [ pkgs.proton-vpn ];

    # nixpkgs ships no NetworkManager VPN plugins by default; without this the
    # app's OpenVPN protocol fails and only WireGuard connects.
    networking.networkmanager.plugins = [ pkgs.networkmanager-openvpn ];

    # Split DNS so MagicDNS names keep resolving on tailscale0 while the Proton
    # connection holds the default DNS route. Enabling resolved also switches
    # NetworkManager to its systemd-resolved backend. It lives here rather than
    # in base.nix so bootstrap configurations keep their current DNS.
    services.resolved.enable = true;
    # resolved answers and sends LLMNR by default, which these hosts never did
    # under resolvconf; keep single-label lookups off untrusted local networks.
    services.resolved.settings.Resolve.LLMNR = "false";
  };
}
