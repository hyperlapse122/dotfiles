{ pkgs }:

let
  npmRelease = import ./npm-release-package.nix {
    inherit pkgs;
    pname = "claude-agent-sdk";
    release = ./claude-agent-sdk-release.json;
    lockDirectory = ./claude-agent-sdk;
  };
in
pkgs.buildNpmPackage (
  npmRelease.attrs
  // {
    nodejs = pkgs.nodejs_24;

    # agent-usage uses the separately pinned Claude CLI through the SDK's
    # pathToClaudeCodeExecutable; no bundled platform binary is needed.
    npmFlags = npmRelease.attrs.npmFlags ++ [ "--omit=optional" ];
    doInstallCheck = true;
    installCheckPhase = ''
      runHook preInstallCheck
      node --input-type=module -e '
        const sdk = await import(process.argv[1]);
        if (typeof sdk.query !== "function") process.exit(1);
      ' "$out/lib/node_modules/@anthropic-ai/claude-agent-sdk/sdk.mjs"
      runHook postInstallCheck
    '';

    meta = {
      description = "Pinned Claude Agent SDK for subscription usage queries";
      homepage = "https://github.com/anthropics/claude-agent-sdk-typescript";
      license = pkgs.lib.licenses.unfree;
      platforms = [
        "x86_64-linux"
        "aarch64-linux"
        "aarch64-darwin"
      ];
    };
  }
)
