{ pkgs, self }:
let
  inherit (pkgs) lib;

  generator = import ../packages/flake-inputs.nix { inherit pkgs; };
  registry = "${self}/flake-inputs.json";
  lock = "${self}/flake.lock";
  flake = "${self}/flake.nix";

  agentPins = import "${self}/home/h82/agents/agent-plugin-pins.nix";
  koreanPins = import "${self}/home/h82/agents/korean-skills-pin.nix";
  pinnedSkills = import "${self}/home/h82/agents/pinned-skills-pin.nix";
  ompRelease = builtins.fromJSON (builtins.readFile "${self}/packages/omp-release.json");

  # Expectations come from the pin files, never from the registry or the lock.
  present =
    what: value:
    if value == null || value == "" then
      throw "flake-inputs expectations: ${what} is missing from its pin file"
    else
      value;
  upstreams = present "pinned-skills-pin.nix upstreams" (pinnedSkills.upstreams or null);
  expectations = pkgs.writeText "flake-input-expectations.json" (
    builtins.toJSON {
      pins = {
        omp.ref = "v${present "packages/omp-release.json version" (ompRelease.version or null)}";
        compound-engineering-plugin.ref = present "agent-plugin-pins.nix compound-engineering.tag" (
          agentPins.compound-engineering.tag or null
        );
        korean-skills.ref = present "korean-skills-pin.nix tag" (koreanPins.tag or null);
      }
      // lib.listToAttrs (
        map (
          upstream:
          if upstream ? input then
            lib.nameValuePair upstream.input { inherit (upstream) ref; }
          else
            throw "pinned-skills pin '${upstream.name or "unnamed"}' names no flake input"
        ) (upstreams ++ lib.optional (pinnedSkills ? impeccable) pinnedSkills.impeccable)
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
