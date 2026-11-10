{ ... }:
{
  imports = [
    ./hardware.nix
    ./disko.nix
  ];
  my.t3.cli.enable = true;
  my.t3.desktop.enable = true;
  my.sshServer.enable = true;
  # Windows on the same PC runs the relay to its Gpg4win agent, listening only
  # on its address in the isolated host-only VMware network.
  my.gpgAgentRelay = {
    enable = true;
    endpoint = "192.168.250.1:4321";
  };
  my.printing.enable = false;
  my.tailscale.enable = false;
  my.protonVpn.enable = false;
  my.wifiman.enable = false;
}
