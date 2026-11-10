{ ... }:
{
  # Puts `ykman` on the system path and enables the smart-card daemon, which
  # `base.nix` already sets to the same value.
  #
  # The module also installs yubikey-personalization's udev rules. Those are not
  # what lets the FIDO application be read: systemd's own 60-fido-id.rules tags
  # any hidraw device declaring the FIDO usage page, and 70-uaccess.rules hands
  # that device to the seat's logged-in user. The vendor rules set the same
  # variable only for a fixed USB product-id list, and that list omits the
  # FIDO-plus-smart-card combination. Treat them as something the module owns,
  # never as the mechanism behind device access here. `tests/yubikey-fido.nix`
  # asserts all three rules so that a change to the two load-bearing ones fails
  # a build rather than a card.
  programs.yubikey-manager.enable = true;
}
