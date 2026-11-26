{ pkgs, self }:
let
  inherit (pkgs) lib;

  # The generator owns the span; the check only reads and compares.
  generator = import ../packages/flake-inputs.nix { inherit pkgs; };
  registry = "${self}/flake-inputs.json";
  lock = "${self}/flake.lock";
  flake = "${self}/flake.nix";

  agentPins = import "${self}/home/h82/agents/agent-plugin-pins.nix";
  koreanPins = import "${self}/home/h82/agents/korean-skills-pin.nix";
  pinnedSkills = import "${self}/home/h82/agents/pinned-skills-pin.nix";
  ompRelease = builtins.fromJSON (builtins.readFile "${self}/packages/omp-release.json");

  # Expectations come from the pin files, never from the registry or the lock.
  expectations = pkgs.writeText "flake-input-expectations.json" (
    builtins.toJSON {
      pins = {
        omp = {
          ref = "v${ompRelease.version}";
          rev = ompRelease.rev;
        };
        compound-engineering-plugin = {
          ref = agentPins.compound-engineering.tag;
          rev = agentPins.compound-engineering.expectedRev;
        };
        korean-skills = {
          ref = koreanPins.tag;
          rev = koreanPins.expectedRev;
        };
      }
      // lib.listToAttrs (
        map (
          upstream:
          lib.nameValuePair upstream.input {
            inherit (upstream) ref;
            rev = upstream.expectedRev or null;
          }
        ) (lib.filter (upstream: upstream ? input) pinnedSkills.upstreams)
      );
    }
  );
in
pkgs.runCommand "flake-inputs-tests" { nativeBuildInputs = [ pkgs.python3 ]; } ''
  python3 ${./flake-inputs.py} ${generator}/bin/flake-inputs ${./flake-input-consistency.py}
  ${generator}/bin/flake-inputs generate --check --registry ${registry} --flake ${flake}
  python3 ${./flake-input-consistency.py} ${registry} ${lock} ${expectations}
  touch $out
''
