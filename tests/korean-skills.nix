/*
  Check interface:

    import ./tests/korean-skills.nix { inherit pkgs self fixtures; }

  Asserts that the three korean-skills skills reach every harness for user
  `h82` on every host this flake declares, and that their pin still names the
  revision this repository expects:

    Claude Code               ~/.claude/skills/<name>
    Antigravity CLI, and T3 Code's Antigravity instances
                              ~/.gemini/antigravity-cli/skills/<name>
    OMP                       ~/.omp/agent/skills/<name>
    Codex                     ~/.codex/skills/<name>

  The user list is `userEntries` from `tests/lib/configurations.nix`, so the
  NixOS and non-NixOS Linux user environments are both covered, and the
  helper's guard fails the build when that list is empty.

  Verifies, per Home Manager user:
  - each delivery has an enabled Home Manager entry found by resolved target:
    OMP owns its whole contributed root, and the other harnesses link each
    skill separately.
  - each target exists in the materialized `home-files`, holds a SKILL.md whose
    frontmatter `name` equals the directory name and whose `description` is
    not empty, holds a LICENSE that starts with "MIT License", and matches the
    pinned input byte for byte: the skill directory without LICENSE against
    `skills/<name>` (so `references/` and `examples/` are there too), and
    LICENSE against the input's root LICENSE. See
    .compound-engineering/artifacts/solutions/best-practices/nix-check-reads-option-value-not-materialized-output.md
  - each target's SKILL.md in `home-files` is not a symlink, because Codex
    skips a SKILL.md symlink: home/h82/agents/skills.nix links the skill
    directory itself, never its files with `recursive = true`.
  - no enabled target is ~/.codex/skills/.system or under it, which Codex
    owns.
  - the other roots declare exactly the three skill directories plus test-audit
    and the skills tests/pinned-skills.nix checks,
    and ~/.gemini/antigravity-cli/skills also every skill of the pinned
    compound-engineering-plugin input (its `skills/<name>` directories that
    hold a SKILL.md; tests/antigravity-skills.nix checks their content);
    OMP declares only its whole root. Content checks below cover all four
    delivered skill trees; native OMP checks also exercise discovery.
  - nothing exists at ~/.agents/skills or ~/.gemini/config/skills in the
    materialized `home-files`: the Antigravity CLI lists skills under
    ~/.gemini/config/skills twice, and ~/.agents/skills is no harness's root
    here.

  The pin assertion compares two genuinely separate sources: `flake.lock`,
  which Nix writes, and the pin file in home/h82/agents/korean-skills-pin.nix,
  which a person writes. A tag is mutable and a relock re-resolves the ref, so the
  tag alone is not a pin -- if upstream moves it, the lock's revision changes
  and this assertion goes red instead of the change arriving as a lock diff.
  The registry's tag must equal the ref the lock recorded, and its skill list
  must equal the list written here.

  The expected names and roots are written here, not read from the module, so
  a mutation of the module turns this red. Every lookup carries an `or`
  fallback and each store path is interpolated only inside its present branch,
  so a removed declaration fails inside the builder rather than during
  evaluation. See
  .compound-engineering/artifacts/solutions/best-practices/unguarded-derivation-interpolation-defeats-nix-check-mutation-testing.md

  Globs are never expanded in the builder: stdenv's nullglob would make an
  `ls <glob>` assertion succeed on no match. See
  .compound-engineering/artifacts/solutions/logic-errors/stdenv-nullglob-makes-ls-glob-assertions-vacuous.md

  The builder collects every failure instead of exiting at the first, so one
  red build names every broken assertion across every configuration.
*/
{
  pkgs,
  self,
  fixtures,
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
    "test-audit"
    "frontend-design"
    "web-design-guidelines"
    "vercel-react-best-practices"
    "vercel-composition-patterns"
    "vercel-react-native-skills"
    "expo-native-ui"
    "expo-upgrade"
    "expo-ui"
    "expo-animation"
    "expo-router"
    "expo-data-fetching"
    "playwright-best-practices"
    "ux-writing"
    "cli-design"
    "design-lenses"
    "ux-flows"
  ];

  # Antigravity loads no plugins, so its root also holds the pinned Compound
  # Engineering skills, named by the pinned input rather than the module.
  ceRoot = ".gemini/antigravity-cli/skills";
  ceSkillsDir = "${self.inputs.compound-engineering-plugin}/skills";
  ceSkillNames = lib.attrNames (
    lib.filterAttrs (
      name: type: type == "directory" && builtins.pathExists "${ceSkillsDir}/${name}/SKILL.md"
    ) (builtins.readDir ceSkillsDir)
  );

  roots = [
    ".claude/skills"
    ".gemini/antigravity-cli/skills"
    ".omp/agent/skills"
    ".codex/skills"
  ];

  # Codex keeps its bundled skills here; no declared skill may land on it.
  codexSystemDir = ".codex/skills/.system";

  forbiddenRoots = [
    ".agents/skills"
    ".gemini/config/skills"
  ];

  registry = import ../home/h82/agents/korean-skills-pin.nix;

  lock = builtins.fromJSON (builtins.readFile ../flake.lock);
  lockNode = lock.nodes.korean-skills or { };
  lockedRev = lockNode.locked.rev or "";
  originalRef = lockNode.original.ref or "";

  configurations = import ./lib/configurations.nix { inherit pkgs self fixtures; };

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
      target = "${root}/${name}";
    in
    ''
      dir=${homeFiles}/${target}
      if [ -L "$dir/SKILL.md" ]; then
        echo ${esc "the SKILL.md of ~/${target} on ${label} is a symlink in home-files; link the skill directory, not its files"} >&2
        failed=1
      fi
      if [ ! -f "$dir/SKILL.md" ]; then
        echo ${esc "~/${target} on ${label} holds no SKILL.md in home-files"} >&2
        failed=1
      else
        actual=$(awk '
          NR == 1 && $0 != "---" { exit }
          NR > 1 && $0 == "---" { exit }
          NR > 1 && /^name:/ { sub(/^name:[ ]*/, ""); print; exit }
        ' "$dir/SKILL.md")
        if [ "$actual" != ${esc name} ]; then
          echo ${esc "the SKILL.md of ~/${target} on ${label} must declare name ${name}, got:"} "'$actual'" >&2
          failed=1
        fi
        description=$(awk '
          NR == 1 && $0 != "---" { exit }
          NR > 1 && $0 == "---" { exit }
          NR > 1 && /^description:/ { sub(/^description:[ ]*/, ""); print; exit }
        ' "$dir/SKILL.md")
        # A YAML value that parses to nothing (quotes around nothing or only
        # whitespace, null, ~) is empty too: Codex drops such a skill.
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
      if ! diff -r --exclude=LICENSE "$dir" ${upstream}/skills/${name} >&2; then
        echo ${esc "~/${target} on ${label} differs from skills/${name} of the pinned input"} >&2
        failed=1
      fi
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
      if root == ".omp/agent/skills" then
        homeFile label userConfig root
      else
        lib.concatMapStrings (name: homeFile label userConfig "${root}/${name}") skillNames
    ) roots
    + lib.concatMapStrings (
      root:
      let
        found = targetsUnder userConfig root;
        expected =
          if root == ".omp/agent/skills" then
            [ root ]
          else
            sorted (
              map (name: "${root}/${name}") (
                skillNames ++ otherSkillNames ++ lib.optionals (root == ceRoot) ceSkillNames
              )
            );
      in
      lib.optionalString (found != expected) ''
        echo ${esc "~/${root} on ${label} must hold exactly ${lib.concatStringsSep ", " expected}, got: ${lib.concatStringsSep ", " found}"} >&2
        failed=1
      ''
    ) roots
    + (
      let
        found = targetsUnder userConfig codexSystemDir;
      in
      lib.optionalString (found != [ ]) ''
        echo ${esc "~/${codexSystemDir} on ${label} belongs to Codex, but these targets are declared there: ${lib.concatStringsSep ", " found}"} >&2
        failed=1
      ''
    )
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
in
pkgs.runCommand "korean-skills-tests" { } ''
  set -x
  ${configurations.userGuard}
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

  ${lib.concatMapStringsSep "\n" assertEntry configurations.userEntries}

  if [ "$failed" != "0" ]; then
    exit 1
  fi

  touch $out
''
