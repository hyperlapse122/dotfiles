# Checks the pinned Korean writing references, their licenses, and the exact shared domain targets in the three materialized harness roots.
{
  entries ? null,
  pkgs,
  self,
}:
let
  inherit (pkgs) lib;

  esc = value: lib.escapeShellArg (toString value);

  skillNames = [
    "humanizer"
    "grammar-checker"
    "style-guide"
  ];

  # Every other skill the roots hold. Only the root population below counts
  # these; tests/test-audit-skill.nix and tests/pinned-skills.nix check their
  # content.
  otherSkillNames = [
    "web-lenses"
    "engineering-lenses"
    "writing-lenses"
    "design-lenses"
    "mobile-lenses"
    "service-lenses"
    "platform-lenses"
    "toolchain-lenses"
    "project-skills"
  ];

  roots = [
    ".claude/skills"
    ".pi/agent/skills"
    ".config/opencode/skills"
  ];

  forbiddenRoots = [
    ".agents/skills"
    ".codex/skills"
  ];

  registry = import ../home/h82/agents/korean-skills-pin.nix;

  lock = builtins.fromJSON (builtins.readFile ../flake.lock);
  lockNode = lock.nodes.korean-skills or { };
  lockedRev = lockNode.locked.rev or "";
  originalRef = lockNode.original.ref or "";

  configurations = import ./lib/configurations.nix { inherit pkgs self; };

  sorted = lib.sort lib.lessThan;

  upstream = self.inputs.korean-skills or null;

  # Every enabled target at or under `root`.
  targetsUnder =
    userConfig: root:
    sorted (
      map (file: file.target) (
        lib.filter (
          file:
          (file.enable or false)
          && ((file.target or "") == root || lib.hasPrefix "${root}/" (file.target or ""))
        ) (lib.attrValues (userConfig.home.file or { }))
      )
    );

  homeFile =
    label: userConfig: target:
    let
      entries = lib.filter (file: (file.target or "") == target) (
        lib.attrValues (userConfig.home.file or { })
      );
      entry = if lib.length entries == 1 then lib.head entries else null;
    in
    lib.optionalString (lib.length entries != 1) ''
      echo ${esc "expected 1 home.file for ~/${target} on ${label}, found ${toString (lib.length entries)}"} >&2
      failed=1
    ''
    + lib.optionalString (entry != null) ''
      if [ ${esc (lib.boolToString (entry.enable or false))} != "true" ]; then
        echo ${esc "home.file for ~/${target} on ${label} is not enabled"} >&2
        failed=1
      fi
    '';

  materialized =
    label: homeFiles: root: name:
    let
      target = "${root}/writing-lenses/references/${name}";
    in
    ''
      dir=${homeFiles}/${target}
      if [ -L "$dir/${name}.md" ]; then
        echo ${esc "the SKILL.md of ~/${target} on ${label} is a symlink in home-files; link the skill directory, not its files"} >&2
        failed=1
      fi
      if [ ! -f "$dir/${name}.md" ]; then
        echo ${esc "~/${target} on ${label} holds no SKILL.md in home-files"} >&2
        failed=1
      else
        actual=$(awk '
          NR == 1 && $0 != "---" { exit }
          NR > 1 && $0 == "---" { exit }
          NR > 1 && /^name:/ { sub(/^name:[ ]*/, ""); print; exit }
        ' "$dir/${name}.md")
        if [ "$actual" != ${esc name} ]; then
          echo ${esc "the SKILL.md of ~/${target} on ${label} must declare name ${name}, got:"} "'$actual'" >&2
          failed=1
        fi
        description=$(awk '
          NR == 1 && $0 != "---" { exit }
          NR > 1 && $0 == "---" { exit }
          NR > 1 && /^description:/ { sub(/^description:[ ]*/, ""); print; exit }
        ' "$dir/${name}.md")
        description=$(printf '%s' "$description" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//; s/^"(.*)"$/\1/; s/^'"'"'(.*)'"'"'$/\1/; s/^[[:space:]]+//; s/[[:space:]]+$//')
        case "$description" in
          "" | null | Null | NULL | "~") description= ;;
        esac
        if [ -z "$description" ]; then
          echo ${esc "the SKILL.md of ~/${target} on ${label} declares no description"} >&2
          failed=1
        fi
      fi
      if [ ! -f "$dir/LICENSE" ]; then
        echo ${esc "~/${target} on ${label} holds no LICENSE in home-files"} >&2
        failed=1
      elif [ "$(head -c 11 "$dir/LICENSE")" != "MIT License" ]; then
        echo ${esc "the LICENSE of ~/${target} on ${label} must start with MIT License"} >&2
        failed=1
      fi
    ''
    + lib.optionalString (upstream == null) ''
      echo ${esc "no korean-skills flake input to compare ~/${target} against"} >&2
      failed=1
    ''
    + lib.optionalString (upstream != null) ''
      comparison="$dir"
      ${lib.optionalString (name == "humanizer") ''
        comparison=$(mktemp -d)
        cp -r --no-preserve=mode "$dir"/. "$comparison"/
        if ! sed 's@\.\./\.\./\.\./style-guide/references/tone-consistency\.md@../../style-guide/references/tone-consistency.md@g' ${upstream}/skills/humanizer/references/structure-patterns.md | cmp -s - "$dir/references/structure-patterns.md" \
          || ! grep -Fq '](../../style-guide/references/tone-consistency.md)' "$dir/references/structure-patterns.md" \
          || [ ! -f "$dir/references/../../style-guide/references/tone-consistency.md" ]; then
          echo ${esc "the style-guide reference in ~/${target} on ${label} must resolve to the installed guide"} >&2
          failed=1
        fi
        cp --no-preserve=mode ${upstream}/skills/humanizer/references/structure-patterns.md "$comparison/references/structure-patterns.md"
      ''}
      if ! cmp -s "$dir/${name}.md" ${upstream}/skills/${name}/SKILL.md || ! diff -r --exclude=LICENSE --exclude=SKILL.md --exclude=${name}.md "$comparison" ${upstream}/skills/${name} >&2; then
        echo ${esc "~/${target} on ${label} differs from skills/${name} of the pinned input"} >&2
        failed=1
      fi
      ${lib.optionalString (name == "humanizer") ''rm -rf "$comparison"''}
      if [ -f "$dir/LICENSE" ] && ! cmp -s "$dir/LICENSE" ${upstream}/LICENSE; then
        echo ${esc "the LICENSE of ~/${target} on ${label} differs from the pinned input's LICENSE"} >&2
        failed=1
      fi
    '';

  assertEntry =
    entry:
    let
      label = entry.name;
      userConfig = entry.user;
      homeFiles = userConfig.home-files or null;
    in
    lib.concatMapStrings (
      root:
      let
        found = targetsUnder userConfig root;
        expected = sorted (map (name: "${root}/${name}") otherSkillNames);
      in
      lib.optionalString (found != expected) ''
        echo ${esc "~/${root} on ${label} must hold exactly ${lib.concatStringsSep ", " expected}, got: ${lib.concatStringsSep ", " found}"} >&2
        failed=1
      ''
    ) roots
    + lib.optionalString (homeFiles == null) ''
      echo ${esc "no materialized home-files on ${label}"} >&2
      failed=1
    ''
    + lib.optionalString (homeFiles != null) (
      lib.concatMapStrings (
        root: lib.concatMapStrings (name: materialized label homeFiles root name) skillNames
      ) roots
      + lib.concatMapStrings (root: ''
        if [ -e ${homeFiles}/${root} ] || [ -L ${homeFiles}/${root} ]; then
          echo ${esc "~/${root} must not exist on ${label}"} >&2
          failed=1
        fi
      '') forbiddenRoots
    );
  userEntries = if entries == null then configurations.userEntries else entries;

in
pkgs.runCommand "korean-skills-tests" { } ''
  set -x
  ${lib.optionalString (entries == null) configurations.guard}
  failed=0

  if [ -z ${esc lockedRev} ]; then
    echo 'flake.lock records no revision for the korean-skills input' >&2
    failed=1
  fi

  if [ -z ${esc originalRef} ]; then
    echo 'flake.lock records no tag for the korean-skills input; the pin must name a release tag, not a branch' >&2
    failed=1
  fi

  if [ ${esc (registry.expectedRev or "")} != ${esc lockedRev} ]; then
    echo ${esc "the pinned korean-skills revision drifted: pin expects '${registry.expectedRev or ""}', flake.lock resolved '${lockedRev}'"} >&2
    failed=1
  fi
  if [ ${esc (registry.tag or "")} != ${esc originalRef} ]; then
    echo ${esc "the pin's tag '${registry.tag or ""}' does not match the tag '${originalRef}' flake.lock recorded"} >&2
    failed=1
  fi
  if [ ${
    esc (lib.concatStringsSep " " (sorted (registry.skills or [ ])))
  } != ${esc (lib.concatStringsSep " " (sorted skillNames))} ]; then
    echo ${esc "the pin's skills must be exactly ${lib.concatStringsSep ", " (sorted skillNames)}"} >&2
    failed=1
  fi

  ${lib.concatMapStringsSep "\n" assertEntry userEntries}

  if [ "$failed" != "0" ]; then
    exit 1
  fi

  touch $out
''
