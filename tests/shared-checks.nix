{ pkgs, inputs }:
let
  inherit (inputs) self;
  darwinFixtures = import ./lib/darwin-fixtures.nix { inherit inputs; };
in
{
  agent-check =
    pkgs.runCommand "agent-check-tests" (import ../packages/agent-check.nix { inherit pkgs; })
      ''
        export HOME="$TMPDIR/home"
        mkdir -p "$HOME" scripts
        cp ${../scripts/agent-check} scripts/agent-check
        cp ${../scripts/agent-check-inspect.py} scripts/agent-check-inspect.py
        cp ${../scripts/check-changed-files} scripts/check-changed-files
        cp ${../scripts/lint-staged-markdown} scripts/lint-staged-markdown
        chmod u+w scripts/*
        patchShebangs scripts/agent-check
        python3 ${./agent-check.py} "$PWD/scripts/agent-check"
        touch "$out"
      '';
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
