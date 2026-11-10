{ pkgs }:

let
  inherit (pkgs) lib;

  # The pin file scripts/android-sdk-release writes. It is androidenv's own
  # repo.json format trimmed to the packages below, so every version and
  # archive checksum comes from this repository rather than from nixpkgs.
  repoJson = ./android-sdk-repo.json;
  repo = lib.importJSON repoJson;

  # Accepting here, not through nixpkgs.config, keeps the acceptance next to
  # the one SDK it applies to. androidenv refuses to build without it.
  # patchelf 0.19 leaves the ninja in CMake 3.22.1 segfaulting on start, so
  # every androidenv package runs autoPatchelf with 0.16.1. androidenv builds
  # its packages through pkgs.callPackage, so a scope that swaps
  # autoPatchelfHook reaches them and nothing else; pkgs.extend would also
  # rebuild every package in the closure that uses the hook, rustc among them.
  androidScope = lib.makeScope pkgs.newScope (_: {
    autoPatchelfHook = pkgs.autoPatchelfHook.overrideAttrs (old: {
      propagatedBuildInputs = [
        (import ./patchelf-0-16.nix { inherit pkgs; })
      ]
      ++ old.propagatedBuildInputs;
    });
  });
  androidenv = pkgs.androidenv.override {
    licenseAccepted = true;
    pkgs = pkgs // {
      inherit (androidScope) callPackage;
    };
  };

  isDarwin = pkgs.stdenv.hostPlatform.isDarwin;

  composition = androidenv.composeAndroidPackages {
    inherit repoJson;
    # The legacy tools package is superseded by cmdline-tools and absent here.
    toolsVersion = null;
    cmdLineToolsVersion = repo.latest.cmdline-tools;
    platformToolsVersion = repo.latest.platform-tools;
    buildToolsVersions = builtins.attrNames repo.packages.build-tools;
    platformVersions = builtins.attrNames repo.packages.platforms;
    # The emulator runs AVDs, and an AVD needs a system image the read-only
    # SDK cannot download later.
    # platformVersions selects the images' API levels.
    includeEmulator = true;
    emulatorVersion = repo.latest.emulator;
    includeSystemImages = true;
    systemImageTypes = [ "google_apis" ];
    # A Mac runs arm64 images natively; androidenv silently drops an ABI the
    # pin lacks, which tests/darwin-outputs.nix catches.
    abiVersions = if isDarwin then [ "arm64-v8a" ] else [ "x86_64" ];
    includeSources = false;
    includeNDK = true;
    ndkVersions = builtins.attrNames repo.packages.ndk;
    # Gradle's externalNativeBuild looks for the CMake it names under cmake/.
    # Explicit because androidenv only defaults it on for x86_64 and Darwin.
    includeCmake = true;
    cmakeVersions = builtins.attrNames repo.packages.cmake;
  };
  sdkRoot = "${composition.androidsdk}/libexec/android-sdk";
  cmdlineToolsVersion = repo.latest.cmdline-tools;

  # The emulator infers the SDK root from its own store path when neither
  # variable is set, as for an app started from the Dock, and that root has
  # no platforms/, so no AVD boots.
  emulatorWrapper = pkgs.writeShellScript "emulator" ''
    export ANDROID_HOME="''${ANDROID_HOME:-$HOME/Library/Android/sdk}"
    export ANDROID_SDK_ROOT="''${ANDROID_SDK_ROOT:-$HOME/Library/Android/sdk}"
    exec ${sdkRoot}/emulator/emulator "$@"
  '';
in
{
  inherit repo sdkRoot;
  inherit (composition) androidsdk;

  # The SDK root on macOS, in the layout T3 Code's device hub requires:
  # cmdline-tools/latest beside the pinned version androidenv installs, and an
  # emulator/emulator that finds the SDK without the session variables.
  darwinSdkRoot =
    pkgs.runCommand "android-sdk-darwin"
      {
        passthru.systemImages = composition.system-images;
      }
      ''
        mkdir -p $out/cmdline-tools $out/emulator
        for entry in ${sdkRoot}/*; do
          case ''${entry##*/} in
            cmdline-tools | emulator) ;;
            *) ln -s "$entry" "$out/''${entry##*/}" ;;
          esac
        done
        ln -s ${sdkRoot}/cmdline-tools/${cmdlineToolsVersion} $out/cmdline-tools/${cmdlineToolsVersion}
        ln -s ${cmdlineToolsVersion} $out/cmdline-tools/latest
        for entry in ${sdkRoot}/emulator/*; do
          [ "''${entry##*/}" = emulator ] || ln -s "$entry" "$out/emulator/''${entry##*/}"
        done
        ln -s ${emulatorWrapper} $out/emulator/emulator
      '';
}
