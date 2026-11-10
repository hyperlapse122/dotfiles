{ pkgs }:

let
  inherit (pkgs) lib;
  source = builtins.fromJSON (builtins.readFile ./codex-release.json);
  system = pkgs.stdenv.hostPlatform.system;
  platform =
    source.platforms.${system}
      or (throw "packages/codex-release.json pins no codex asset for ${system}");
  fetchAsset =
    version: pin:
    pkgs.fetchurl {
      url = "https://github.com/openai/codex/releases/download/rust-v${version}/${pin.asset}";
      inherit (pin) hash;
    };
  binaryOf = pin: lib.removeSuffix ".tar.gz" pin.asset;
in
pkgs.stdenvNoCC.mkDerivation (finalAttrs: {
  pname = "codex";
  inherit (source) version;

  # The Linux musl builds are statically linked, so they run on NixOS and
  # other distributions unpatched.
  srcs = [
    (fetchAsset finalAttrs.version platform.codex)
    (fetchAsset finalAttrs.version platform.codeModeHost)
  ];

  # Each tarball holds one bare binary with no top-level directory.
  sourceRoot = ".";

  nativeBuildInputs = [
    pkgs.makeWrapper
    pkgs.writableTmpDirAsHomeHook
  ];

  # The app, Computer Use, and update flags hold under any CODEX_HOME, including
  # a home a T3 Code instance gets when it declares one, whose config.toml never
  # receives the declared settings.
  # daemon_auto_start would install and update a background copy of Codex
  # outside the store; nixpkgs patches it off, which a prebuilt pin cannot.
  # Codex spawns codex-code-mode-host from beside its own executable, never
  # from PATH, so the host sits next to the real binary, not in bin/.
  # bubblewrap is Codex's Linux sandbox; on macOS it uses Seatbelt instead.
  installPhase = ''
    runHook preInstall

    install -Dm755 ${binaryOf platform.codex} $out/libexec/codex/codex
    install -Dm755 ${binaryOf platform.codeModeHost} $out/libexec/codex/codex-code-mode-host
    makeWrapper $out/libexec/codex/codex $out/bin/codex \
      --prefix PATH : ${
        lib.makeBinPath ([ pkgs.ripgrep ] ++ lib.optional pkgs.stdenv.hostPlatform.isLinux pkgs.bubblewrap)
      } \
      --add-flags "-c check_for_update_on_startup=false --disable in_app_updates --disable daemon_auto_start --disable apps --disable computer_use"

    runHook postInstall
  '';

  doInstallCheck = true;
  nativeInstallCheckInputs = [ pkgs.versionCheckHook ];
  versionCheckKeepEnvironment = [ "HOME" ];
  # versionCheckHook runs only the CLI; run the host too, on every system the
  # package builds for, so a broken host fails the build rather than Code Mode.
  postInstallCheck = ''
    target=$(sed -nE 's/^exec (-a "\$0" )?"([^"]+)".*/\2/p' "$out/bin/codex")
    if [ -z "$target" ] || ! "$(dirname "$target")/codex-code-mode-host" --help > /dev/null; then
      echo "codex: missing or broken codex-code-mode-host beside '$target'" >&2
      exit 1
    fi
  '';

  meta = {
    description = "Lightweight coding agent that runs in your terminal";
    homepage = "https://github.com/openai/codex";
    license = lib.licenses.asl20;
    sourceProvenance = [ lib.sourceTypes.binaryNativeCode ];
    platforms = lib.attrNames source.platforms;
    mainProgram = "codex";
  };
})
