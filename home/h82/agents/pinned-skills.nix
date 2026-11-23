{
  pkgs,
  lib,
  inputs,
  ...
}:
let
  registry = import ./pinned-skills-pin.nix;
  esc = lib.escapeShellArg;

  copySkill =
    upstream: skill: destination:
    let
      src = "${inputs.${upstream.input}}";
      dir = "${src}/${skill.path}";
      licenseInside = skill.license != null && lib.hasPrefix "${skill.path}/" skill.license;
      copyFiles =
        if skill ? files then
          lib.concatMapStringsSep "\n" (
            file: ''cp -r --no-preserve=mode ${esc "${dir}/${file}"} "${destination}/"''
          ) skill.files
        else
          ''cp -r --no-preserve=mode ${esc dir}/. "${destination}"'';
    in
    ''
      mkdir -p "${destination}"
      ${copyFiles}
      ${lib.optionalString (skill.license != null && !licenseInside) ''
        cp --no-preserve=mode ${esc "${src}/${skill.license}"} "${destination}"/${esc (baseNameOf skill.license)}
      ''}
      ${lib.optionalString (skill.license == null) ''
        printf '%s\n' ${esc "${upstream.licenseSource}. Source: github:${upstream.input} at ${upstream.expectedRev}."} > "${destination}/LICENSE-SOURCE"
      ''}
    '';

  ctx7 = lib.getExe (import ../../../packages/ctx7.nix { inherit pkgs; });
  renderSkill =
    upstream: skill: destination:
    copySkill upstream skill destination
    + lib.optionalString (skill.name == "vercel-react-best-practices") ''
      ln -s rules/async-defer-await.md "${destination}/async-defer-await.md"
      ln -s rules/async-cheap-condition-before-await.md "${destination}/async-cheap-condition-before-await.md"
      ln -s rules/server-hoist-static-io.md "${destination}/server-hoist-static-io.md"
    ''
    + lib.optionalString (skill.name == "playwright-best-practices") ''
      ln -s ../debugging/error-testing.md "${destination}/advanced/error-testing.md"
      ln -s ../browser-apis/service-workers.md "${destination}/advanced/service-workers.md"
      ln -s ../debugging/error-testing.md "${destination}/browser-apis/error-testing.md"
      ln -s ../browser-apis/service-workers.md "${destination}/debugging/service-workers.md"
      ln -s ../core/assertions-waiting.md "${destination}/debugging/assertions-waiting.md"
      ln -s ../core/fixtures-hooks.md "${destination}/infrastructure-ci-cd/fixtures-hooks.md"
    ''
    + lib.optionalString (skill.name == "find-docs") ''
      awk -v cmd=${esc ctx7} '
        /^Run commands with / { print "Use the packaged Context7 CLI with public library names and sanitized queries."; next }
        /^Optionally install globally/ { skip=1 }
        /^## Workflow/ { skip=0 }
        /^## Authentication/ {
          print "## Authentication\n\nLookup works anonymously. The owner can run \140ctx7 login\140 or supply \140CONTEXT7_API_KEY\140 for higher limits. On quota exhaustion, use public upstream documentation.\n"
          skip=1
        }
        /^## Common Mistakes/ { skip=0 }
        skip { next }
        /^npx ctx7@latest (library|docs) / { $0=$0 " --json" }
        { gsub(/npx ctx7@latest/, cmd); print }
      ' "${destination}/SKILL.md" > "${destination}/find-docs.md"
      mv "${destination}/find-docs.md" "${destination}/SKILL.md"
    '';

  registered = lib.concatMap (
    upstream: map (skill: { inherit upstream skill; }) upstream.skills
  ) registry.upstreams;
  mobile = entry: entry.skill.mobile or false;
  mobileLenses = pkgs.runCommand "mobile-lenses" { } ''
    mkdir -p "$out"
    cp ${./skills/mobile-lenses/SKILL.md} "$out/SKILL.md"
    ${lib.concatMapStringsSep "\n" (
      { upstream, skill }:
      let
        destination = "$out/references/${skill.name}";
      in
      copySkill upstream skill destination
      + ''
        mv "${destination}/SKILL.md" "${destination}/${skill.name}.md"
      ''
    ) (lib.filter mobile registered)}
  '';

  impeccable = registry.impeccable;
  impeccableSrc = "${inputs.${impeccable.input}}";

  designLenses = pkgs.runCommand "design-lenses" { } ''
    mkdir -p $out/references
    cp --no-preserve=mode ${./skills/design-lenses/SKILL.md} $out/SKILL.md
    cp --no-preserve=mode ${./skills/design-lenses/ux-flows.md} $out/references/ux-flows.md
    ${lib.concatMapStringsSep "\n" (
      file:
      "cp --no-preserve=mode ${esc "${impeccableSrc}/${impeccable.referencePath}/${file}"} $out/references/"
    ) impeccable.references}
    cp --no-preserve=mode ${esc "${impeccableSrc}/${impeccable.license}"} $out/LICENSE
    cp --no-preserve=mode ${esc "${impeccableSrc}/${impeccable.notice}"} $out/NOTICE.md
  '';

  # listToAttrs keeps one of two entries with the same name, so a duplicate
  # would silently drop an upstream skill.
  names = map (entry: entry.skill.name) registered ++ [
    "design-lenses"
    "mobile-lenses"
  ];
  duplicates = lib.unique (lib.filter (name: lib.count (other: other == name) names > 1) names);
in
{
  my.agentSkillReferences =
    lib.throwIf (duplicates != [ ])
      "pinned-skills: the skill name(s) ${lib.concatStringsSep ", " duplicates} appear more than once"
      (
        lib.foldl' (
          groups:
          { upstream, skill }:
          let
            domain =
              if builtins.elem skill.name [ "ux-writing" ] then
                "writing-lenses"
              else if
                builtins.elem skill.name [
                  "find-docs"
                  "cli-design"
                  "untangle-codebase"
                  "prune-tests"
                ]
              then
                "engineering-lenses"
              else
                "web-lenses";
            source = pkgs.runCommand "pinned-skill-${skill.name}" { } (renderSkill upstream skill "$out");
          in
          lib.recursiveUpdate groups { ${domain}.${skill.name} = source; }
        ) { } (lib.filter (entry: !mobile entry) registered)
      );

  my.agentSkills = {
    design-lenses = designLenses;
    mobile-lenses = mobileLenses;
  };
}
