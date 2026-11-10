# TanStack Intent's CLI, which finds the agent skills TanStack packages ship in
# a project's node_modules and loads the one an agent asks for. The npm
# tarball bundles its dependencies into dist/, so it installs as-is with no
# dependency fetch; the pin in tanstack-intent-release.json moves by hand.
{ pkgs }:

let
  inherit (pkgs) lib;
  source = builtins.fromJSON (builtins.readFile ./tanstack-intent-release.json);
in
pkgs.stdenvNoCC.mkDerivation {
  pname = "tanstack-intent";
  inherit (source) version;
  src = pkgs.fetchurl { inherit (source) url hash; };

  nativeBuildInputs = [ pkgs.makeWrapper ];

  installPhase = ''
    runHook preInstall
    mkdir -p $out/lib/tanstack-intent
    cp -r . $out/lib/tanstack-intent
    makeWrapper ${lib.getExe pkgs.nodejs_24} $out/bin/intent \
      --add-flags $out/lib/tanstack-intent/dist/cli.mjs
    runHook postInstall
  '';

  doInstallCheck = true;
  nativeInstallCheckInputs = [ pkgs.versionCheckHook ];
  versionCheckProgramArg = "--version";

  meta = {
    description = "CLI that loads the agent skills TanStack packages ship";
    homepage = "https://github.com/TanStack/intent";
    license = lib.licenses.mit;
    platforms = [
      "x86_64-linux"
      "aarch64-linux"
      "aarch64-darwin"
    ];
    mainProgram = "intent";
  };
}
