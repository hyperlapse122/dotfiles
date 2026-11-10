# What the macOS checks expect from the Android SDK pin, read from
# packages/android-sdk-repo.json rather than taken from the modules, so a
# module that picks the wrong platforms or API fails the checks. androidenv
# silently drops an ABI the pin lacks, so every pinned platform must still
# carry its arm64 image.
{ lib }:
let
  pin = lib.importJSON ../../packages/android-sdk-repo.json;
in
{
  platforms = lib.attrNames pin.packages.platforms;

  # The newest pinned API level with an arm64-v8a Google APIs image. Keys mix
  # "36" and "37.0", hence compareVersions.
  newestArm64Api =
    lib.foldl'
      (newest: api: if newest == null || builtins.compareVersions api newest > 0 then api else newest)
      null
      (lib.attrNames (lib.filterAttrs (_: image: (image.google_apis or { }) ? arm64-v8a) pin.images));

  # The `--device <platform>:<model>[:<version>]` argument a my.mobileDevices
  # entry renders to on the mobile-devices helper's command line.
  deviceArg =
    device:
    "--device ${
      lib.escapeShellArg (
        "${device.platform}:${device.model}"
        + lib.optionalString (device.version != null) ":${device.version}"
      )
    }";
}
