/*
  Check interface:

    import ./tests/antigravity-skills.nix { inherit pkgs self fixtures; }

  Asserts that the pinned Compound Engineering skills reach the Antigravity
  CLI and T3 Code's Antigravity instances through
  ~/.gemini/antigravity-cli/skills, and that the step retiring the old
  plugin install works, for user `h82` on every Home Manager user
  environment `tests/lib/configurations.nix` yields.

  Verifies, per user environment:
  - every directory under `skills/` of the pinned compound-engineering-plugin
    input that holds a SKILL.md is materialized in `home-files` at
    ~/.gemini/antigravity-cli/skills/<name> and matches the input byte for
    byte. The names come from the pinned input, not from the module.
    tests/korean-skills.nix owns the root's exact population.
  - home.activation.antigravitySkillsRetire runs before checkLinkTargets and,
    executed in a scratch HOME by tests/antigravity-skills-retire.py with a
    stub in place of the packaged agy: removes a link into
    ~/.gemini/config/plugins/ whose name the generation declares, keeps and
    reports a link elsewhere and a regular file, keeps a store link silently,
    calls `agy plugin uninstall compound-engineering` once when the retired
    plugin copy exists and never otherwise, finishes when the uninstall
    fails, and changes nothing on a dry run.

  Every lookup carries an `or` fallback so a removed declaration fails inside
  the builder rather than during evaluation. The builder collects every
  failure instead of exiting at the first.
*/
{
  pkgs,
  self,
  fixtures,
}:
let
  inherit (pkgs) lib;

  esc = value: lib.escapeShellArg (toString value);

  root = ".gemini/antigravity-cli/skills";

  upstream = self.inputs.compound-engineering-plugin;
  upstreamSkills = "${upstream}/skills";
  ceSkillNames = lib.attrNames (
    lib.filterAttrs (
      name: type: type == "directory" && builtins.pathExists "${upstreamSkills}/${name}/SKILL.md"
    ) (builtins.readDir upstreamSkills)
  );

  configurations = import ./lib/configurations.nix { inherit pkgs self fixtures; };

  assertEntry =
    entry:
    let
      label = entry.name;
      userConfig = entry.user;
      homeFiles = userConfig.home-files or null;
      step = userConfig.home.activation.antigravitySkillsRetire or null;
      beforeCheck = lib.elem "checkLinkTargets" (if step == null then [ ] else step.before or [ ]);
    in
    lib.optionalString (homeFiles == null) ''
      echo ${esc "no materialized home-files on ${label}"} >&2
      failed=1
    ''
    + lib.optionalString (homeFiles != null) (
      lib.concatMapStrings (name: ''
        if ! diff -r ${homeFiles}/${root}/${name} ${upstreamSkills}/${name} >&2; then
          echo ${esc "~/${root}/${name} on ${label} is missing or differs from skills/${name} of the pinned input"} >&2
          failed=1
        fi
      '') ceSkillNames
    )
    + lib.optionalString (step == null) ''
      echo ${esc "missing home.activation.antigravitySkillsRetire on ${label}"} >&2
      failed=1
    ''
    + lib.optionalString (step != null && homeFiles != null) ''
      if [ ${esc (lib.boolToString beforeCheck)} != true ]; then
        echo ${esc "home.activation.antigravitySkillsRetire must run before checkLinkTargets on ${label}"} >&2
        failed=1
      fi
      if ! ${pkgs.python3}/bin/python3 ${./antigravity-skills-retire.py} \
        ${pkgs.writeText "antigravity-skills-retire.sh" (step.data or "")} \
        ${esc (userConfig.home.homeDirectory or "")} ${homeFiles} ${pkgs.bash}/bin/bash; then
        echo ${esc "home.activation.antigravitySkillsRetire on ${label} failed its runtime contract"} >&2
        failed=1
      fi
    '';
in
pkgs.runCommand "antigravity-skills-tests" { nativeBuildInputs = [ pkgs.diffutils ]; } ''
  set -x
  ${configurations.userGuard}
  failed=0

  if [ ${esc (lib.length ceSkillNames)} = 0 ]; then
    echo 'the pinned compound-engineering-plugin input holds no skill' >&2
    failed=1
  fi

  ${lib.concatMapStringsSep "\n" assertEntry configurations.userEntries}

  if [ "$failed" != "0" ]; then
    exit 1
  fi

  touch $out
''
