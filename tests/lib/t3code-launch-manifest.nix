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
        "t3codeRetireAntigravity"
        "t3codeSettings"
        "t3codeClientSettings"
        "t3codeInstructions"
      ];
      helper = ../../scripts/agent-instructions;
      template = ../../home/h82/agents/instructions/instructions.md.tmpl;
      renderer = "${renderer}/bin/text-template";
      baselineHash = "32ce19ad264121665936d01a83c7383c5a50a3e722b3f9331a545495561fe002";
    }) users
  )
)
