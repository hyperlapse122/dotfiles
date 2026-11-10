{
  # MikroTik router administration. openFirewall opens the UDP ports WinBox
  # needs for neighbor discovery and MAC-address connections.
  programs.winbox = {
    enable = true;
    openFirewall = true;
  };
}
