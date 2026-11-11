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
  config = lib.mkMerge [
    (lib.mkIf (lib.elem "nvidia" config.services.xserver.videoDrivers) {
      # patchelf 0.19 leaves nvidia-smi, nvidia-powerd, and
      # nvidia-cuda-mps-control segfaulting on start (NixOS/nixpkgs#576412). The
      # driver's builder patches them with the first patchelf on PATH.
      hardware.nvidia.package = lib.mkDefault (
        config.boot.kernelPackages.nvidiaPackages.${cfg.branch}.overrideAttrs (old: {
          nativeBuildInputs = [
            (import ../../../packages/patchelf-0-16.nix { inherit pkgs; })
          ]
          ++ old.nativeBuildInputs;
        })
      );
    })
    (lib.mkIf config.hardware.nvidia-container-toolkit.enable {
      # A switch replaces the userspace libraries but cannot replace a loaded
      # NVIDIA module. Defer CDI until reboot rather than fail the switch.
      systemd.services.nvidia-container-toolkit-cdi-generator.serviceConfig.ExecCondition =
        pkgs.writeShellScript "nvidia-cdi-driver-ready" ''
          if [ -r /sys/module/nvidia/version ]; then
            loaded=$(cat /sys/module/nvidia/version)
            if [ "$loaded" != ${lib.escapeShellArg cfg.package.version} ]; then
              echo "Deferring NVIDIA CDI generation: loaded driver $loaded differs from configured driver ${cfg.package.version}; reboot to use the new driver." >&2
              exit 1
            fi
          fi
        '';
    })
  ];
}
