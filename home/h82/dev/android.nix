{
  config,
  lib,
  pkgs,
  ...
}:
let
  androidSdk = import ../../../packages/android-sdk.nix { inherit pkgs; };
  isDarwin = config.my.kind == "darwin";
  # A stable path in front of the store SDK, so ANDROID_HOME, ~/.androidrc,
  # and the sdk.dir an IDE writes into local.properties survive a pin bump.
  # On macOS it is the path T3 Code's device hub falls back to when an app
  # started from the Dock has no ANDROID_HOME.
  sdkRoot =
    if isDarwin then
      "${config.home.homeDirectory}/Library/Android/sdk"
    else
      "${config.xdg.dataHome}/android-sdk";
  # androidenv installs cmdline-tools at its repository path, the pinned
  # version, rather than at the cmdline-tools/latest an sdkmanager install uses.
  cmdlineTools = "${sdkRoot}/cmdline-tools/${androidSdk.repo.latest.cmdline-tools}";
  androidSessionVariables = {
    ANDROID_HOME = sdkRoot;
    ANDROID_SDK_ROOT = sdkRoot;
    # Gradle finds the NDK by the project's ndkVersion under ndk/; cargo-ndk,
    # gomobile, and CMake toolchain files read this variable instead.
    ANDROID_NDK_HOME = "${sdkRoot}/ndk/${androidSdk.repo.latest.ndk}";
  };
in
# The SDK's Linux tools are x86_64 binaries even though the SDK evaluates on
# aarch64, so the module is inert on aarch64 Linux. macOS gets arm64 builds.
lib.mkIf (pkgs.stdenv.hostPlatform.isx86_64 || isDarwin) (
  lib.mkMerge [
    (lib.mkIf (!isDarwin) {
      xdg.dataFile."android-sdk".source = androidSdk.sdkRoot;

      systemd.user.sessionVariables = androidSessionVariables;
    })

    (lib.mkIf isDarwin {
      home.file."Library/Android/sdk".source = androidSdk.darwinSdkRoot;
    })

    {
      home.sessionVariables = androidSessionVariables;

      # Appended rather than prepended through home.sessionPath: platform-tools
      # also ships sqlite3 and mke2fs, which must not shadow the system's.
      # The agent-device CLI looks for emulator beside adb on PATH.
      home.sessionVariablesExtra = ''
        export PATH="''${PATH:+$PATH:}${cmdlineTools}/bin:${sdkRoot}/platform-tools${lib.optionalString isDarwin ":${sdkRoot}/emulator"}"
      '';

      # The Android CLI reads its default flags from this file.
      home.file.".androidrc".text = ''
        --sdk=${sdkRoot}
      '';

      # Gradle and the Android Gradle Plugin need a JDK; this also sets JAVA_HOME.
      programs.java.enable = true;
    }
  ]
)
