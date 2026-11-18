{ pkgs, users }:
let
  renderer = import ../../packages/text-template.nix { inherit pkgs; };
in
pkgs.writeText "t3code-launch-manifest.json" (
  builtins.toJSON (
    map (user: {
      home = user.home.homeDirectory;
      profile = user.home.profileDirectory or "${user.home.homeDirectory}/.nix-profile";
      scripts = map (name: user.home.activation.${name}.data or "") [
        "t3codeSettings"
        "t3codeClientSettings"
        "t3codeInstructions"
      ];
      helper = ../../scripts/agent-instructions;
      template = ../../home/h82/agents/instructions/instructions.md.tmpl;
      renderer = "${renderer}/bin/text-template";
      baselineHash = "c5e836fe14c7a5e749ca3e902ec07006254eba107c9d40e7a71ee593554beea5";
    }) users
  )
)
