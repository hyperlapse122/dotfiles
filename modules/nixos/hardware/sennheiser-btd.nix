{ ... }:
{
  # Unlike the `uaccess` rules in nuphy-gem80.nix, these must stay in
  # `services.udev.extraRules`. `MODE` is decided by the last assignment across
  # all rule files, and systemd's 50-udev-default.rules sets `0664` on every USB
  # device node, so a file numbered before it would silently lose. 99-local.rules,
  # where `extraRules` lands, sorts after it.
  #
  # `0666` lets any local account write to the dongle. It is deliberate, copied
  # from the rule the dongle's control utility ships, and narrowing it to the
  # seat user needs hardware confirmation that the utility works without it.
  services.udev.extraRules = ''
    # Sennheiser BTD 600
    SUBSYSTEM=="usb", ATTR{idVendor}=="3542", ATTR{idProduct}=="3000", MODE="0666"
    SUBSYSTEM=="hidraw", ATTRS{idVendor}=="3542", ATTRS{idProduct}=="3000", MODE="0666"

    # Sennheiser BTD 700
    SUBSYSTEM=="usb", ATTR{idVendor}=="3542", ATTR{idProduct}=="3001", MODE="0666"
    SUBSYSTEM=="hidraw", ATTRS{idVendor}=="3542", ATTRS{idProduct}=="3001", MODE="0666"
  '';
}
