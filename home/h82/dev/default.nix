{ lib, hostKind, ... }:
{
  imports = [
    ./android.nix
    ./containers.nix
    ./cpp.nix
    ./decide.nix
    ./dotnet.nix
    ./flutter.nix
    ./ghq.nix
    ./git.nix
    ./kubernetes.nix
    ./rust.nix
    ./swift.nix
    ./tool-environment.nix
    ./vscodium.nix
  ]
  # iOS Simulators and Android Virtual Devices are created on macOS only.
  ++ lib.optionals (hostKind == "darwin") [
    ./mobile-devices.nix
    ./ollama-darwin.nix
  ];
}
