{ config, lib, ... }:
{
  nixpkgs.hostPlatform = lib.mkDefault "x86_64-linux";
  boot.initrd.availableKernelModules = [
    "xhci_pci"
    "ahci"
    "nvme"
    "usbhid"
    "usb_storage"
    "sd_mod"
  ];
  boot.initrd.kernelModules = lib.mkIf (!config.my.bootstrap) [
    "nvidia"
    "nvidia_modeset"
    "nvidia_drm"
  ];
  boot.kernelModules = [ "kvm-intel" ];
  hardware.cpu.intel.updateMicrocode = true;
  hardware.enableRedistributableFirmware = true;
  hardware.graphics.enable = true;
  hardware.bluetooth.enable = true;
  services.fstrim.enable = true;
  zramSwap.enable = false;

  # The desktop's RTX 3060 needs only the Ampere SM 8.6 kernels.
  nixpkgs.overlays = [
    (_: prev: {
      ollama-cuda = prev.ollama-cuda.override { cudaArches = [ "sm_86" ]; };
    })
  ];
  services.xserver.videoDrivers = [ "nvidia" ];
  hardware.nvidia = {
    modesetting.enable = true;
    open = false;
    powerManagement.enable = false;
  };
  hardware.nvidia-container-toolkit.enable = true;
}
