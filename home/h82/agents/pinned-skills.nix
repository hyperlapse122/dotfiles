{
  pkgs,
  lib,
  inputs,
  ...
}:
let
  registry = import ./pinned-skills-pin.nix;
  esc = lib.escapeShellArg;

  # One store directory per skill holding upstream's files unchanged, plus the
  # upstream license when it sits outside the skill directory. An upstream with
  # no license file gets a LICENSE-SOURCE note naming where it declares one.
  skillTree =
    upstream: skill:
    let
      src = "${inputs.${upstream.input}}";
      dir = "${src}/${skill.path}";
      licenseInside = skill.license != null && lib.hasPrefix "${skill.path}/" skill.license;
      copyFiles =
        if skill ? files then
          lib.concatMapStringsSep "\n" (
            file: "cp -r --no-preserve=mode ${esc "${dir}/${file}"} $out/"
          ) skill.files
        else
          "cp -r --no-preserve=mode ${esc dir}/. $out";
    in
    pkgs.runCommand "pinned-skill-${skill.name}" { } ''
      mkdir -p $out
      ${copyFiles}
      ${lib.optionalString (skill.license != null && !licenseInside) ''
        cp --no-preserve=mode ${esc "${src}/${skill.license}"} $out/${esc (baseNameOf skill.license)}
      ''}
      ${lib.optionalString (skill.license == null) ''
        printf '%s\n' ${esc "${upstream.licenseSource}. Source: github:${upstream.input} at ${upstream.expectedRev}."} > $out/LICENSE-SOURCE
      ''}
    '';

  impeccable = registry.impeccable;
  impeccableSrc = "${inputs.${impeccable.input}}";

  designLenses = pkgs.runCommand "design-lenses" { } ''
    mkdir -p $out/references
    cp --no-preserve=mode ${./skills/design-lenses/SKILL.md} $out/SKILL.md
    ${lib.concatMapStringsSep "\n" (
      file:
      "cp --no-preserve=mode ${esc "${impeccableSrc}/${impeccable.referencePath}/${file}"} $out/references/"
    ) impeccable.references}
    cp --no-preserve=mode ${esc "${impeccableSrc}/${impeccable.license}"} $out/LICENSE
    cp --no-preserve=mode ${esc "${impeccableSrc}/${impeccable.notice}"} $out/NOTICE.md
  '';

  # listToAttrs keeps one of two entries with the same name, so a duplicate
  # would silently drop an upstream skill.
  names = lib.concatMap (upstream: map (skill: skill.name) upstream.skills) registry.upstreams ++ [
    "design-lenses"
  ];
  duplicates = lib.unique (lib.filter (name: lib.count (other: other == name) names > 1) names);
in
{
  my.agentSkills =
    lib.throwIf (duplicates != [ ])
      "pinned-skills: the skill name(s) ${lib.concatStringsSep ", " duplicates} appear more than once"
      (
        lib.listToAttrs (
          lib.concatMap (
            upstream: map (skill: lib.nameValuePair skill.name (skillTree upstream skill)) upstream.skills
          ) registry.upstreams
        )
        // {
          design-lenses = designLenses;
        }
      );
}
