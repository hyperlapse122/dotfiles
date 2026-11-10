{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.hardware.nvidia;
in
{
  # patchelf 0.19 leaves nvidia-smi, nvidia-powerd, and
  # nvidia-cuda-mps-control segfaulting on start (NixOS/nixpkgs#576412). The
  # driver's builder patches them with the first patchelf on PATH.
  config = lib.mkIf (lib.elem "nvidia" config.services.xserver.videoDrivers) {
    hardware.nvidia.package = lib.mkDefault (
      config.boot.kernelPackages.nvidiaPackages.${cfg.branch}.overrideAttrs (old: {
        nativeBuildInputs = [
          (import ../../../packages/patchelf-0-16.nix { inherit pkgs; })
        ]
        ++ old.nativeBuildInputs;
      })
    );
  };
}
