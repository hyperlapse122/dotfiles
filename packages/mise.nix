{ pkgs }:

let
  inherit (pkgs) lib;
  source = builtins.fromJSON (builtins.readFile ./mise-release.json);
  system = pkgs.stdenv.hostPlatform.system;
  asset =
    source.systems.${system} or (throw "packages/mise-release.json pins no mise asset for ${system}");
in
pkgs.stdenvNoCC.mkDerivation (finalAttrs: {
  pname = "mise";
  inherit (source) version;

  # The Linux musl build is statically linked, so it runs on NixOS unpatched.
  src = pkgs.fetchurl {
    url = "https://github.com/jdx/mise/releases/download/v${finalAttrs.version}/mise-v${finalAttrs.version}-${asset.asset}.tar.gz";
    inherit (asset) hash;
  };

  nativeBuildInputs = [
    pkgs.installShellFiles
    pkgs.writableTmpDirAsHomeHook
  ];

  # The tarball also ships bin/mise.d, a Cargo dependency file, and a fish
  # activation snippet that Home Manager's own integration replaces.
  installPhase = ''
    runHook preInstall

    install -Dm755 bin/mise $out/bin/mise
    installManPage man/man1/mise.1
    installShellCompletion --cmd mise \
      --bash <($out/bin/mise completion bash) \
      --fish <($out/bin/mise completion fish) \
      --zsh <($out/bin/mise completion zsh)

    # mise refuses `mise self-update` when this marker sits beside it, as the
    # nixpkgs package does for its read-only store path.
    mkdir -p $out/lib/mise
    touch $out/lib/mise/.disable-self-update

    runHook postInstall
  '';

  doInstallCheck = true;
  nativeInstallCheckInputs = [ pkgs.versionCheckHook ];
  versionCheckKeepEnvironment = [ "HOME" ];

  meta = {
    description = "Front-end to your dev env";
    homepage = "https://mise.jdx.dev";
    license = lib.licenses.mit;
    sourceProvenance = [ lib.sourceTypes.binaryNativeCode ];
    platforms = builtins.attrNames source.systems;
    mainProgram = "mise";
  };
})
