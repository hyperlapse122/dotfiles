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
      baselineHash = "79863ccd27cb6a5ac17cb89058eb87391375553541b180b40e2319bffb4e6cf0";
    }) users
  )
)
