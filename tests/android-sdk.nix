/*
  Check interface:

    import ./tests/android-sdk.nix { inherit pkgs self; }

  Asserts that every host configuration gives h82 the Android SDK the pin file
  packages/android-sdk-repo.json names, reading the files the Home Manager
  generation materializes rather than the options they come from. The expected
  versions are read from the pin file here, independently of the module, so a
  module that stops deriving its versions from the pin fails.

  Verifies, on every configuration `tests/lib/configurations.nix` yields,
  production and bootstrap alike:
  - the h82 Home Manager generation exists; its store paths are interpolated
    only when it does, so a removed user fails inside the builder rather than
    during evaluation.
  - ~/.local/share/android-sdk is a link into a store SDK that carries every
    pinned package's and x86_64 system image's package.xml at its repository
    path, and the accepted android-sdk-license. The pin's arm64-v8a images
    are for macOS hosts, which tests/darwin-outputs.nix checks.
  - the SDK holds the platform (with its android.jar), Google APIs x86_64
    system image (with its system.img), and build-tools of every API level
    in requiredApiLevels. The list is fixed here rather than read from the
    pin, so dropping a level from the pin fails the check instead of
    dropping its assertions with it.
  - the SDK's adb runs in the sandbox and reports the pinned platform-tools
    version, and aapt2 from each pinned build-tools runs. Both prove
    androidenv patched them for NixOS rather than leaving them to nix-ld.
  - the pinned cmdline-tools directory ships an executable sdkmanager.
  - each pinned NDK's source.properties names its version, which is what
    Gradle matches ndkVersion against, and its clang runs, proving the
    toolchain was patched for NixOS.
  - each pinned CMake's cmake and ninja run and cmake reports its version,
    which Gradle's externalNativeBuild matches its cmake version against.
  - emulator/emulator runs and reports the pinned emulator version.
  - hm-session-vars.sh exports ANDROID_HOME and ANDROID_SDK_ROOT as the link
    and ANDROID_NDK_HOME as the newest pinned NDK under it,
    appends the cmdline-tools bin and platform-tools directories to PATH on
    the only line that names platform-tools (its sqlite3 and mke2fs must not
    shadow the system's), and exports a JAVA_HOME that holds a java
    executable.
  - environment.d/10-home-manager.conf carries the SDK and NDK variables, so
    apps the systemd user manager starts see them too.
  - ~/.androidrc holds exactly the --sdk flag for the link.

  The builder collects every failure before it exits, so one red build names
  every affected configuration.
*/
{ pkgs, self }:
let
  inherit (pkgs.lib)
    attrNames
    attrValues
    concatMap
    concatMapStrings
    escapeShellArg
    concatMapStringsSep
    optional
    ;

  configurations = import ./lib/configurations.nix { inherit pkgs self; };

  repo = builtins.fromJSON (builtins.readFile ../packages/android-sdk-repo.json);
  # images nest api -> tag -> abi -> entry, one level deeper than packages.
  # The pin also carries the arm64-v8a images macOS hosts use; a NixOS SDK
  # builds only x86_64 (packages/android-sdk.nix abiVersions).
  linuxAbi = "x86_64";
  pinned =
    concatMap attrValues (attrValues repo.packages)
    ++ concatMap (
      tags: concatMap (abis: optional (abis ? ${linuxAbi}) abis.${linuxAbi}) (attrValues tags)
    ) (attrValues repo.images);
  platformTools = repo.latest.platform-tools;
  emulator = repo.latest.emulator;
  cmdlineTools = repo.latest.cmdline-tools;
  ndk = repo.latest.ndk;

  # compileSdk 37 resolves to the android-37.0 package; upstream publishes no
  # android-37. build-tools are exact because a project that sets no
  # buildToolsVersion gets AGP's default, which the read-only SDK cannot fetch.
  requiredApiLevels = [
    {
      platform = "36";
      buildTools = "36.0.0";
    }
    {
      platform = "37.0";
      buildTools = "37.0.0";
    }
  ];

  sdkRoot = "/home/h82/.local/share/android-sdk";

  shellLines = [
    ''export ANDROID_HOME="${sdkRoot}"''
    ''export ANDROID_NDK_HOME="${sdkRoot}/ndk/${ndk}"''
    ''export ANDROID_SDK_ROOT="${sdkRoot}"''
    ''export PATH="''${PATH:+$PATH:}${sdkRoot}/cmdline-tools/${cmdlineTools}/bin:${sdkRoot}/platform-tools"''
  ];

  environmentLines = [
    "ANDROID_HOME=${sdkRoot}"
    "ANDROID_NDK_HOME=${sdkRoot}/ndk/${ndk}"
    "ANDROID_SDK_ROOT=${sdkRoot}"
  ];

  assertEntry =
    entry:
    if entry.user ? home-files then
      assertPresent entry
    else
      ''
        fail ${escapeShellArg "${entry.name}: the h82 Home Manager generation is missing"}
      '';

  assertPresent =
    entry:
    let
      hm = entry.user;
      files = "${hm.home-files}";
      shellFile = "${hm.home.sessionVariablesPackage}/etc/profile.d/hm-session-vars.sh";
      host' = escapeShellArg entry.name;
    in
    ''
      check_file ${host'} ${escapeShellArg shellFile}
      check_file ${host'} ${files}/.config/environment.d/10-home-manager.conf
      check_file ${host'} ${files}/.androidrc

      sdk=${files}/.local/share/android-sdk
      if [ ! -L "$sdk" ] || [ ! -d "$sdk" ]; then
        fail ${host'}": .local/share/android-sdk is not a link to a directory"
      else
        sdk=$(readlink -f "$sdk")
        case "$sdk" in
          /nix/store/*) ;;
          *) fail ${host'}": .local/share/android-sdk resolves outside the store: $sdk" ;;
        esac
        check_file ${host'} "$sdk/licenses/android-sdk-license"
    ''
    + concatMapStrings (package: ''
      check_line_in ${host'} "$sdk/${package.path}/package.xml" ${escapeShellArg ''path="${builtins.replaceStrings [ "/" ] [ ";" ] package.path}"''}
    '') pinned
    + concatMapStrings (level: ''
      for file in platforms/android-${level.platform}/package.xml platforms/android-${level.platform}/android.jar system-images/android-${level.platform}/google_apis/x86_64/package.xml system-images/android-${level.platform}/google_apis/x86_64/system.img build-tools/${level.buildTools}/package.xml; do
        if [ ! -f "$sdk/$file" ]; then
          fail ${host'}": required API level ${level.platform} is missing $file"
        fi
      done
    '') requiredApiLevels
    + ''
      adb_version=$("$sdk/platform-tools/adb" version 2>&1 | sed -n 's/^Version \([^-]*\)-.*/\1/p' || true)
      if [ "$adb_version" != ${escapeShellArg platformTools} ]; then
        fail ${host'}": adb reports platform-tools '$adb_version', expected the pinned ${platformTools}"
      fi

      # The emulator reports major.minor.micro.build; the pin names the first three.
      emulator_version=$("$sdk/emulator/emulator" -version 2>&1 | sed -n 's/^Android emulator version \([0-9]*\.[0-9]*\.[0-9]*\).*/\1/p' || true)
      if [ "$emulator_version" != ${escapeShellArg emulator} ]; then
        fail ${host'}": emulator reports '$emulator_version', expected the pinned ${emulator}"
      fi
    ''
    + concatMapStrings (version: ''
      if ! "$sdk/build-tools/${version}/aapt2" version >/dev/null 2>&1; then
        fail ${host'}": aapt2 from build-tools ${version} does not run"
      fi
    '') (attrNames repo.packages.build-tools)
    + concatMapStrings (version: ''
      check_file ${host'} "$sdk/ndk/${version}/source.properties"
      check_line ${host'} "$sdk/ndk/${version}/source.properties" ${escapeShellArg "Pkg.Revision = ${version}"}
      if ! "$sdk/ndk/${version}/toolchains/llvm/prebuilt/linux-x86_64/bin/clang" --version >/dev/null 2>&1; then
        fail ${host'}": clang from NDK ${version} does not run"
      fi
    '') (attrNames repo.packages.ndk)
    + concatMapStrings (version: ''
      cmake_version=$("$sdk/cmake/${version}/bin/cmake" --version 2>&1 | sed -n 's/^cmake version \([^-]*\).*/\1/p' || true)
      if [ "$cmake_version" != ${escapeShellArg version} ]; then
        fail ${host'}": cmake/${version} reports '$cmake_version'"
      fi
      if ! "$sdk/cmake/${version}/bin/ninja" --version >/dev/null 2>&1; then
        fail ${host'}": ninja from CMake ${version} does not run"
      fi
    '') (attrNames repo.packages.cmake)
    + ''
        if [ ! -x "$sdk/cmdline-tools/${cmdlineTools}/bin/sdkmanager" ]; then
          fail ${host'}": cmdline-tools/${cmdlineTools} ships no executable sdkmanager"
        fi
      fi
    ''
    + concatMapStrings (line: ''
      check_line ${host'} ${escapeShellArg shellFile} ${escapeShellArg line}
    '') shellLines
    + concatMapStrings (line: ''
      check_line ${host'} ${files}/.config/environment.d/10-home-manager.conf ${escapeShellArg line}
    '') environmentLines
    + ''
      if [ -f ${files}/.androidrc ] && [ "$(cat ${files}/.androidrc)" != ${escapeShellArg "--sdk=${sdkRoot}"} ]; then
        fail ${host'}": .androidrc does not hold exactly --sdk=${sdkRoot}"
      fi

      if [ "$(grep -c platform-tools ${escapeShellArg shellFile})" != 1 ]; then
        fail ${host'}": hm-session-vars.sh names platform-tools on more than the appending PATH line"
      fi

      java_home=$(sed -n 's/^export JAVA_HOME="\(.*\)"$/\1/p' ${escapeShellArg shellFile})
      if [ -z "$java_home" ] || [ ! -x "$java_home/bin/java" ]; then
        fail ${host'}": hm-session-vars.sh exports no JAVA_HOME with bin/java"
      fi
    '';
in
pkgs.runCommand "android-sdk-tests" { } ''
  ${configurations.guard}

  # adb aborts when it cannot create ~/.android, and the sandbox HOME does
  # not exist.
  export HOME=$TMPDIR/home
  mkdir -p "$HOME"

  failed=0
  fail() {
    echo "$1" >&2
    failed=1
  }
  check_file() {
    if [ ! -f "$2" ]; then
      fail "$1: missing $2"
    fi
  }
  check_line() {
    if [ -f "$2" ] && ! grep -Fxq -- "$3" "$2"; then
      fail "$1: $2 is missing the line: $3"
    fi
  }
  # package.xml is one generated document, so its path attribute is matched
  # as a fixed string rather than as a whole line.
  check_line_in() {
    if [ ! -f "$2" ]; then
      fail "$1: missing $2"
    elif ! grep -Fq -- "$3" "$2"; then
      fail "$1: $2 does not declare $3"
    fi
  }

  ${concatMapStringsSep "\n" assertEntry configurations.entries}

  if [ "$failed" != 0 ]; then
    exit 1
  fi
  touch $out
''
