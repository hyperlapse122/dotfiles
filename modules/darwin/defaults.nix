{
  # macOS system defaults for every macOS host: Finder, trackpad, appearance,
  # and keyboard settings belong here, under system.defaults. The Dock has
  # its own module, dock.nix.
  # Appearance follows the time of day (System Settings > Appearance > Auto);
  # AppleInterfaceStyle stays unset because macOS writes it while switching.
  system.defaults.NSGlobalDomain.AppleInterfaceStyleSwitchesAutomatically = true;
}
