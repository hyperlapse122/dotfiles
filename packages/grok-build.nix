{ pkgs }:

let
  inherit (pkgs) lib;
  source = builtins.fromJSON (builtins.readFile ./grok-build-release.json);
  system = pkgs.stdenv.hostPlatform.system;
  platform =
    source.platforms.${system}
      or (throw "packages/grok-build-release.json pins no grok release for ${system}");
in
pkgs.stdenvNoCC.mkDerivation (finalAttrs: {
  pname = "grok-build";
  inherit (source) version;

  src = pkgs.fetchurl { inherit (platform) url hash; };
  dontUnpack = true;
  dontBuild = true;
  # Stripping would invalidate the macOS binary's code signature.
  dontStrip = true;

  nativeBuildInputs = [
    pkgs.installShellFiles
    pkgs.makeWrapper
    pkgs.writableTmpDirAsHomeHook
  ]
  ++ lib.optional pkgs.stdenv.hostPlatform.isElf pkgs.autoPatchelfHook;

  # GROK_DISABLE_AUTOUPDATER holds under any HOME, including the per-provider
  # homes T3 Code sets. grok treats an empty or falsy value as unset.
  # GROK_CLAUDE_AGENTS_ENABLED is false so grok does not scan ~/.claude/ named
  # instruction files; a project's CLAUDE.md and AGENTS.md still load. Every
  # launch in scope goes through this wrapper, --set overrides a caller's
  # value, and the environment outranks config.toml. nixpkgs' package also
  # links bin/agent to grok; it is left out because Cursor's CLI installs an
  # `agent` as well.
  installPhase = ''
    runHook preInstall

    install -Dm755 "$src" $out/libexec/grok-build/grok
    makeWrapper $out/libexec/grok-build/grok $out/bin/grok \
      --set GROK_DISABLE_AUTOUPDATER 1 \
      --set GROK_CLAUDE_AGENTS_ENABLED false

    ${lib.optionalString (pkgs.stdenv.buildPlatform.canExecute pkgs.stdenv.hostPlatform) ''
      installShellCompletion --cmd grok \
        --bash <($out/libexec/grok-build/grok completions bash) \
        --fish <($out/libexec/grok-build/grok completions fish) \
        --zsh <($out/libexec/grok-build/grok completions zsh)
    ''}

    runHook postInstall
  '';

  doInstallCheck = true;
  nativeInstallCheckInputs = [ pkgs.versionCheckHook ];
  postInstallCheck = ''
    grep -qxF "export GROK_DISABLE_AUTOUPDATER='1'" $out/bin/grok
    grep -qxF "export GROK_CLAUDE_AGENTS_ENABLED='false'" $out/bin/grok
  '';
  versionCheckProgramArg = "--version";
  versionCheckKeepEnvironment = [ "HOME" ];

  meta = {
    description = "Command-line coding agent by xAI";
    homepage = "https://docs.x.ai/build/overview";
    downloadPage = "https://x.ai/cli/stable";
    license = lib.licenses.unfreeRedistributable;
    sourceProvenance = [ lib.sourceTypes.binaryNativeCode ];
    platforms = lib.attrNames source.platforms;
    mainProgram = "grok";
  };
})
