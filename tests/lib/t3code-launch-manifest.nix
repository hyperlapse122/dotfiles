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
      baselineHash = "7ff57613d415c7f44fa19e048a6fa528e07c6435cc39f48b7bd59ffb6198b6b1";
    }) users
  )
)
