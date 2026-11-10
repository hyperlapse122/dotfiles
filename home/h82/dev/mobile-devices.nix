{
  config,
  lib,
  pkgs,
  ...
}:
let
  helper = import ../../../packages/mobile-devices.nix { inherit pkgs; };
  inherit (import ../../../packages/android-sdk.nix { inherit pkgs; }) repo;

  # The newest pinned API level with an image a Mac runs, compared as versions
  # because the pin's keys mix "36" and "37.0".
  androidApi = lib.last (
    lib.sort (a: b: builtins.compareVersions a b < 0) (
      lib.attrNames (lib.filterAttrs (_: image: image.google_apis ? arm64-v8a) repo.images)
    )
  );

  deviceArgs = lib.concatMapStringsSep " " (
    device:
    "--device ${
      lib.escapeShellArg (
        "${device.platform}:${device.model}"
        + lib.optionalString (device.version != null) ":${device.version}"
      )
    }"
  ) config.my.mobileDevices;
in
{
  options.my.mobileDevices = lib.mkOption {
    type = lib.types.listOf (
      lib.types.submodule {
        options = {
          platform = lib.mkOption {
            type = lib.types.enum [
              "ios"
              "android"
            ];
            description = "Whether the device is an iOS Simulator or an Android Virtual Device.";
          };
          model = lib.mkOption {
            type = lib.types.nonEmptyStr;
            description = ''
              For iOS, a device type name from `xcrun simctl list devicetypes`;
              for Android, a device id from `avdmanager list device -c`.
            '';
          };
          version = lib.mkOption {
            type = lib.types.nullOr lib.types.nonEmptyStr;
            default = null;
            description = ''
              The iOS version or pinned Android API key (such as `37.0`); null
              means the newest installed iOS runtime that supports the model,
              or the newest API level the SDK pin offers.
            '';
          };
        };
      }
    );
    default = [
      {
        platform = "android";
        model = "pixel_10_pro";
      }
    ];
    description = ''
      iOS Simulators and Android Virtual Devices that every apply creates when
      missing. A device dropped from the list is left in place.
    '';
  };

  # Home Manager on nix-darwin activates on every apply, so an App Store
  # Xcode upgrade with no Nix change still gets devices for its new runtime.
  # The helper reports its own failures and exits 0; a usage error or a
  # crash still exits non-zero, which the `if !` guard turns into one line,
  # because activation runs under `set -e` and must never stop here.
  config.home.activation.mobileDevices = lib.hm.dag.entryAfter [ "linkGeneration" ] ''
    if [[ -v DRY_RUN ]]; then
      echo "Creating the missing declared iOS Simulators and Android Virtual Devices"
    elif ! ${lib.getExe helper} --xcrun /usr/bin/xcrun --sdk-root ${lib.escapeShellArg config.home.sessionVariables.ANDROID_HOME} --java-home ${lib.escapeShellArg config.programs.java.package.home} --android-api ${lib.escapeShellArg androidApi} ${deviceArgs}; then
      echo "mobileDevices: the mobile-devices helper failed, so some declared devices may be missing; apply again after fixing the error above" >&2
    fi
  '';
}
