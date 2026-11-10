{ lib, hostKind, ... }:
{
  imports = [
    ./android.nix
    ./containers.nix
    ./cpp.nix
    ./ghq.nix
    ./git.nix
    ./kubernetes.nix
    ./rust.nix
    ./swift.nix
    ./tool-environment.nix
  ]
  # VSCodium is a desktop application; non-NixOS Linux hosts get no desktop.
  ++ lib.optionals (hostKind != "linux") [ ./vscodium.nix ]
  # iOS Simulators and Android Virtual Devices are created on macOS only.
  ++ lib.optionals (hostKind == "darwin") [ ./mobile-devices.nix ];
}
