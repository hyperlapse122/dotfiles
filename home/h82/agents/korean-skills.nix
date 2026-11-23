{
  pkgs,
  lib,
  inputs,
  ...
}:
let
  registry = import ./korean-skills-pin.nix;

  # One skill directory per name, with the upstream license beside it: the
  # repository keeps a single LICENSE at its root, and an installed skill is
  # copied away from there.
  skillTree = pkgs.runCommand "korean-skills-${registry.tag}" { } ''
    ${lib.concatMapStringsSep "\n" (name: ''
      mkdir -p $out/${name}
      cp -r --no-preserve=mode ${inputs.korean-skills}/skills/${name}/. $out/${name}
      cp --no-preserve=mode ${inputs.korean-skills}/LICENSE $out/${name}/LICENSE
    '') registry.skills}
    sed -i 's@\.\./\.\./\.\./style-guide/references/tone-consistency\.md@../../style-guide/references/tone-consistency.md@g' \
      "$out/humanizer/references/structure-patterns.md"
  '';
in
{
  my.agentSkillReferences.writing-lenses = lib.genAttrs registry.skills (
    name: "${skillTree}/${name}"
  );
}
