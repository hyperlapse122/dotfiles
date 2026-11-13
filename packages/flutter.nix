{
  pkgs,
  androidSdk,
  javaHome,
  chromeExecutable,
}:
let
  inherit (pkgs) lib;
  release = lib.importJSON ./flutter-release.json;

  # The pinned nixpkgs release predates GHSA-frr6-h895-5pxp. Reuse its
  # builders and patches until its stable SDK catches up with this hotfix.
  sdk =
    if lib.versionAtLeast pkgs.flutter.version release.version then
      pkgs.flutter
    else
      pkgs.flutterPackages.wrapFlutter (
        pkgs.flutterPackages.mkFlutter (
          release
          // {
            patches = pkgs.flutter.unwrapped.patches;
          }
        )
      );
in
assert lib.assertMsg (
  lib.versionAtLeast sdk.version "3.47.8" && lib.versionAtLeast sdk.dart.version "3.13.7"
) "Flutter must include the fix for GHSA-frr6-h895-5pxp";
sdk.overrideAttrs (old: {
  nativeBuildInputs = (old.nativeBuildInputs or [ ]) ++ [ pkgs.jq ];
  # symlinkJoin uses buildCommand rather than the generic install phases.
  buildCommand = old.buildCommand + ''
    wrapProgram "$out/bin/flutter" \
      --set-default ANDROID_HOME ${lib.escapeShellArg androidSdk.sdkRoot} \
      --set-default ANDROID_SDK_ROOT ${lib.escapeShellArg androidSdk.sdkRoot} \
      --set-default ANDROID_NDK_HOME ${lib.escapeShellArg "${androidSdk.sdkRoot}/ndk/${androidSdk.repo.latest.ndk}"} \
      --set-default JAVA_HOME ${lib.escapeShellArg javaHome} \
      --set-default CHROME_EXECUTABLE ${lib.escapeShellArg chromeExecutable}
    runHook postInstallCheck
  '';
  postInstallCheck = ''
    mkdir -p "$TMPDIR/flutter-home"
    env HOME="$TMPDIR/flutter-home" XDG_CONFIG_HOME="$TMPDIR/flutter-home/.config" FLUTTER_SUPPRESS_ANALYTICS=true \
      "$out/bin/flutter" --version --machine > flutter-version.json
    jq -e --arg flutter ${lib.escapeShellArg sdk.version} \
      --arg dart ${lib.escapeShellArg sdk.dart.version} \
      '.frameworkVersion == $flutter and .dartSdkVersion == $dart' flutter-version.json
    env HOME="$TMPDIR/flutter-home" "$out/bin/dart" --version > dart-version.txt 2>&1
    grep -F ${lib.escapeShellArg "Dart SDK version: ${sdk.dart.version}"} dart-version.txt
  '';
})
