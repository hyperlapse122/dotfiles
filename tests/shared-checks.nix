{ pkgs, inputs }:
let
  inherit (inputs) self;
  darwinFixtures = import ./lib/darwin-fixtures.nix { inherit inputs; };
in
{
  agent-check =
    pkgs.runCommand "agent-check-tests"
      {
        nativeBuildInputs = import ../packages/agent-check.nix { inherit pkgs; };
      }
      ''
        export HOME="$TMPDIR/home"
        mkdir -p "$HOME"
        cp -r ${../scripts} scripts
        chmod -R u+w scripts
        patchShebangs scripts/agent-check
        python3 ${./agent-check.py} "$PWD/scripts/agent-check"
        touch "$out"
      '';
  agent-hooks = import ./agent-hooks.nix { inherit pkgs; };
  project-skills =
    let
      module = import ../home/h82/agents/tanstack-intent.nix { inherit pkgs; };
    in
    pkgs.runCommand "project-skills-tests" { nativeBuildInputs = [ pkgs.python3 ]; } ''
      python3 ${./project-skills.py} ${module.my.agentSkills.project-skills}/SKILL.md
      touch "$out"
    '';
  pinentry-keyring = import ../packages/pinentry-keyring.nix { inherit pkgs; };
  decide = import ./decide.nix { inherit pkgs self darwinFixtures; };
  darwin-provisioning =
    pkgs.runCommand "darwin-provisioning-tests"
      {
        nativeBuildInputs = [
          pkgs.python3
          pkgs.bash
          pkgs.jq
        ];
      }
      ''
        python3 ${./test_darwin_provisioning.py} ${../scripts/macos-xcode.py} ${../scripts/macos-container.sh} ${../scripts/macos-container-state.sh}
        touch "$out"
      '';

  darwin-config = import ./darwin-config.nix {
    inherit
      pkgs
      self
      darwinFixtures
      ;
  };
}
