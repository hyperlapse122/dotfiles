{ pkgs, ... }:
let
  # nixpkgs' libirecovery (2026-08-23) predates the iPhone 18 Pro and Pro Max
  # (iPhone19,x, CPID 0x8160), so idevicerestore stops at "Unable to discover
  # device type". Upstream added them in 93c117c. idevicerestore 68e5dc9 means
  # to send the YonkersIR1 updater through the generic path, as JasmineIR1
  # already is, but hands the `Yonkers` path a NULL device info instead, so the
  # restore stops at "Could not determine Yonkers firmware component". The patch
  # routes it through the generic path, which forwards the request the device
  # generated, and dumps the updater arguments to the debug log. Drop the
  # overrides once nixpkgs reaches these revisions and upstream fixes the path.
  libirecovery = pkgs.libirecovery.overrideAttrs {
    version = "1.3.1-unstable-2026-09-15";
    src = pkgs.fetchFromGitHub {
      owner = "libimobiledevice";
      repo = "libirecovery";
      rev = "93c117c29b1f6669bc4ceca8b84e1df06449fe33";
      hash = "sha256-tNKNceZHMAWwhngt3n4XXbY1w6CeWhYbvWHBuODEvV4=";
    };
  };

  idevicerestore = (pkgs.idevicerestore.override { inherit libirecovery; }).overrideAttrs {
    version = "1.0.0-unstable-2026-10-03";
    src = pkgs.fetchFromGitHub {
      owner = "libimobiledevice";
      repo = "idevicerestore";
      rev = "68e5dc907efcbca70747f9ce2cc5975f8ae8b72d";
      hash = "sha256-AyqfID8TuTcSjpxelZL1JvbBhWhhYlhoin+OyJ/l8Fo=";
    };
    patches = [ ./idevicerestore-yonkers-ir1-generic.patch ];
  };
in
{
  # Restores an iPhone or iPad in DFU or recovery mode from an IPSW file with
  # `idevicerestore`, run as the logged-in user. `docs/recovery.md` has the
  # procedure.
  #
  # In DFU and recovery mode the device is driven over raw USB through
  # libirecovery, so the user needs the device node itself. libirecovery's own
  # udev rule hands it to a placeholder group nixpkgs leaves unset, so it is not
  # installed. The rule below tags it `uaccess` instead, from a file that sorts
  # before systemd's 73-seat-late.rules: a tag set from 99-local.rules, where
  # `services.udev.extraRules` lands, builds cleanly and grants nothing.
  # `tests/udev-device-access.nix` reads the built rules directory to keep it
  # that way. 05ac:1227 is DFU, 05ac:1222 is legacy WTF, and 05ac:1280-1283
  # are recovery mode.
  #
  # Once the restore ramdisk boots, the device re-enumerates in restore mode
  # and idevicerestore reaches it through usbmuxd, which runs as its own user
  # and owns Apple devices through the module's group rule.
  services.udev.packages = [
    (pkgs.writeTextDir "etc/udev/rules.d/60-apple-recovery.rules" ''
      # Apple iOS devices in DFU, legacy WTF, and recovery mode.
      SUBSYSTEM=="usb", ATTR{idVendor}=="05ac", ATTR{idProduct}=="122[27]|128[0-3]", TAG+="uaccess"
    '')
  ];

  services.usbmuxd.enable = true;

  environment.systemPackages = [
    idevicerestore
    # `irecovery -q` shows whether a device is in DFU or recovery mode.
    libirecovery
    pkgs.libimobiledevice
  ];
}
