{ pkgs, inputs }:
let
  system = pkgs.stdenv.hostPlatform.system;
  agentTools = import ./agent-tools.nix { inherit pkgs; };
in
{
  agent-browser = import ./agent-browser.nix { inherit pkgs; };
  ctx7 = import ./ctx7.nix { inherit pkgs; };
  decide = import ./decide.nix { inherit pkgs; };
  impeccable = import ./impeccable.nix { inherit pkgs inputs; };
  omp = import ./omp.nix { inherit pkgs; };
}
// pkgs.lib.optionalAttrs pkgs.stdenv.hostPlatform.isLinux {
  disko = inputs.disko.packages.${system}.disko;
  # Exposed so the release-tracking workflow invokes the packaged helper
  # rather than running scripts/ with whatever interpreter the runner has.
  agent-plugin-release = agentTools.agentPluginRelease;
  claude-desktop-release = agentTools.claudeDesktopRelease;
  claude-desktop = import ./claude-desktop.nix { inherit pkgs; };
  claude-code-release = agentTools.claudeCodeRelease;
  claude-code = import ./claude-code.nix { inherit pkgs; };
  ant-release = pkgs.writeScriptBin "ant-release" (
    "#!${pkgs.python3}/bin/python3\n" + builtins.readFile ../scripts/ant-release
  );
  ant = import ./ant.nix { inherit pkgs; };
  mise-release = agentTools.miseRelease;
  prezto-release = agentTools.preztoRelease;
  mise = import ./mise.nix { inherit pkgs; };
  overlay-release = pkgs.writeScriptBin "overlay-release" (
    "#!${pkgs.python3}/bin/python3\n" + builtins.readFile ../scripts/overlay-release
  );
  opencode-release = agentTools.opencodeRelease;
  opencode = import ./opencode.nix { inherit pkgs; };
  omp-release = agentTools.ompRelease;
  npm-release = agentTools.npmRelease;
  acpx = import ./acpx.nix { inherit pkgs; };
  tanstack-intent = import ./tanstack-intent.nix { inherit pkgs; };
  opencode-go-models-watch = agentTools.opencodeGoModelsWatch;
  android-sdk-release = agentTools.androidSdkRelease;
}
