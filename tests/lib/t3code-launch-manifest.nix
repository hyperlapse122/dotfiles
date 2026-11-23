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
      baselineHash = "64fac3b08118044a8d47c1bc091631dedaada38f0264d5d830ec575a0a3bc586";
    }) users
  )
)
