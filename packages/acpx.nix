{ pkgs }:

let
  inherit (pkgs) lib;
  npmRelease = import ./npm-release-package.nix {
    inherit pkgs;
    pname = "acpx";
    release = ./acpx-release.json;
    lockDirectory = ./acpx;
  };
in
pkgs.buildNpmPackage (
  npmRelease.attrs
  // {
    # acpx needs Node 22.13 or newer.
    nodejs = pkgs.nodejs_24;

    postPatch = npmRelease.attrs.postPatch + ''

      substituteInPlace dist/cli.js \
        --replace-fail 'readConfigFile(projectPath),' '{ config: void 0, exists: false },'
    '';

    doInstallCheck = true;
    nativeInstallCheckInputs = [
      pkgs.versionCheckHook
      pkgs.jq
    ];
    versionCheckProgramArg = "--version";
    postInstallCheck = ''
      bash ${../tests/acpx-config.sh} "$out/bin/acpx"
    '';

    meta = {
      description = "Headless command-line client for the Agent Client Protocol";
      homepage = "https://github.com/openclaw/acpx";
      license = lib.licenses.mit;
      platforms = [
        "x86_64-linux"
        "aarch64-linux"
        "aarch64-darwin"
      ];
      mainProgram = "acpx";
    };
  }
)
