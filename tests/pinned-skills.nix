/*
  Check interface:

    import ./tests/pinned-skills.nix { inherit pkgs self fixtures; }

  Asserts that the published design and stack skills, the local design-lenses
  wrapper with impeccable's lens references, and the local ux-flows skill reach
  every harness for user `h82` on every Home Manager user environment this
  flake builds (`userEntries` from tests/lib/configurations.nix), unchanged:

    Claude Code               ~/.claude/skills/<name>
    Antigravity CLI, and T3 Code's Antigravity instances
                              ~/.gemini/antigravity-cli/skills/<name>
    OMP                       ~/.omp/agent/skills/<name>
    Codex                     ~/.codex/skills/<name>

  Verifies, per Home Manager user:
  - each delivery outside OMP has exactly one enabled home.file per skill, and
    OMP has its one whole-root entry; tests/korean-skills.nix owns each root's
    exact population.
  - each materialized skill holds a SKILL.md that is not a symlink, whose
    frontmatter `name` equals the directory name and whose `description` is
    not empty.
  - each published skill holds exactly the entries its registry entry selects
    plus its license, each byte-identical to the pinned input: the whole
    skill directory, or only the listed `files` of a repository whose root
    holds other things too. A license outside the skill directory matches the
    input's license file; an upstream with no license file carries a
    non-empty LICENSE-SOURCE note instead.
  - design-lenses holds the in-tree wrapper SKILL.md, impeccable's LICENSE and
    NOTICE.md, and under references/ exactly the lens references named here,
    each byte-identical to the rendered plugin tree of the pinned input, so
    no impeccable workflow reference ships.
  - ux-flows matches its in-tree source byte for byte.

  The pin assertions compare `flake.lock`, which Nix writes, with the registry
  in home/h82/agents/pinned-skills-pin.nix, which a person writes: each
  upstream's expected revision must equal the locked revision and its ref the
  ref the lock recorded, so a moved tag turns this red instead of arriving as
  a lock diff. The registry's skill names must equal the names written here.

  Expected names, roots, and lens references are written here, not read from
  the module, so a mutation of the module turns this red. Every lookup carries
  an `or` fallback and each store path is interpolated only inside its present
  branch, so a removed declaration fails inside the builder rather than during
  evaluation. See
  .compound-engineering/artifacts/solutions/best-practices/unguarded-derivation-interpolation-defeats-nix-check-mutation-testing.md
  and
  .compound-engineering/artifacts/solutions/best-practices/nix-check-reads-option-value-not-materialized-output.md

  Globs are never expanded in the builder: stdenv's nullglob would make an
  `ls <glob>` assertion succeed on no match. See
  .compound-engineering/artifacts/solutions/logic-errors/stdenv-nullglob-makes-ls-glob-assertions-vacuous.md
*/
{
  pkgs,
  self,
  fixtures,
}:
let
  inherit (pkgs) lib;

  esc = value: lib.escapeShellArg (toString value);
  sorted = lib.sort lib.lessThan;

  publishedNames = [
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
  ];

  lensReferences = [
    "adapt.md"
    "adapt.native.md"
    "android.md"
    "animate.md"
    "audit.md"
    "audit.native.md"
    "bolder.md"
    "clarify.md"
    "colorize.md"
    "craft-floor.md"
    "delight.md"
    "distill.md"
    "harden.md"
    "ios.md"
    "layout.md"
    "mode-operate.md"
    "mode-persuade.md"
    "mode-read.md"
    "onboard.md"
    "operate.md"
    "optimize.md"
    "polish.md"
    "quieter.md"
    "typeset.md"
  ];

  # A skill whose repository root holds more than the skill installs only the
  # entries upstream packages as the skill (ux-writing's build-skill.sh).
  selectedFiles = {
    ux-writing = [
      "SKILL.md"
      "docs"
      "examples"
      "references"
      "templates"
    ];
  };

  allNames = publishedNames ++ [
    "design-lenses"
    "ux-flows"
  ];

  roots = [
    ".claude/skills"
    ".gemini/antigravity-cli/skills"
    ".omp/agent/skills"
    ".codex/skills"
  ];

  registry = import ../home/h82/agents/pinned-skills-pin.nix;
  upstreams = registry.upstreams or [ ];
  impeccable = registry.impeccable or { };
  pinned = upstreams ++ lib.optional (impeccable != { }) impeccable;

  lock = builtins.fromJSON (builtins.readFile ../flake.lock);

  configurations = import ./lib/configurations.nix { inherit pkgs self fixtures; };

  # The registry entry and upstream of each published skill, by name.
  registered = lib.listToAttrs (
    lib.concatMap (
      upstream:
      map (skill: lib.nameValuePair (skill.name or "") { inherit upstream skill; }) (
        upstream.skills or [ ]
      )
    ) upstreams
  );

  inputOf = name: self.inputs.${name} or null;

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

  # entries <dir> <expected...>: the directory's top-level entries are exactly
  # the expected names.
  entriesCheck = what: dir: expected: ''
    actual=$(ls -A ${dir} 2>/dev/null | sort | tr '\n' ' ')
    if [ "$actual" != ${esc (lib.concatMapStrings (name: "${name} ") (sorted expected))} ]; then
      echo ${esc "${what} must hold exactly ${lib.concatStringsSep ", " (sorted expected)}, got:"} "$actual" >&2
      failed=1
    fi
  '';

  frontmatter = target: label: name: ''
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
      description=$(printf '%s' "$description" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//; s/^"(.*)"$/\1/; s/^'"'"'(.*)'"'"'$/\1/; s/^[[:space:]]+//; s/[[:space:]]+$//')
      case "$description" in
        "" | ">" | ">-" | "|" | "|-" | null | Null | NULL | "~")
          # A block scalar, or a plain scalar that starts on the next line,
          # keeps its text on the following indented lines.
          description=$(awk '
            NR == 1 && $0 != "---" { exit }
            NR > 1 && $0 == "---" { exit }
            found && /^[[:space:]]+[^[:space:]]/ { print; exit }
            found { exit }
            NR > 1 && /^description:[[:space:]]*([>|]-?)?[[:space:]]*$/ { found = 1 }
          ' "$dir/SKILL.md")
          ;;
      esac
      if [ -z "$description" ]; then
        echo ${esc "the SKILL.md of ~/${target} on ${label} declares no description"} >&2
        failed=1
      fi
    fi
  '';

  published =
    target: label: name:
    let
      entry = registered.${name} or null;
      upstream = if entry == null then { } else entry.upstream;
      skill = if entry == null then { } else entry.skill;
      src = inputOf (upstream.input or "");
      path = skill.path or "";
      license = skill.license or null;
      licenseInside = license != null && lib.hasPrefix "${path}/" license;
      licenseName = if license == null then "LICENSE-SOURCE" else baseNameOf license;
    in
    if entry == null || src == null then
      ''
        echo ${esc "no registry entry or flake input to compare ~/${target} on ${label} against"} >&2
        failed=1
      ''
    else if (skill ? files) || selectedFiles ? ${name} then
      let
        files = selectedFiles.${name} or [ ];
      in
      lib.optionalString (sorted (skill.files or [ ]) != sorted files) ''
        echo ${esc "the registry must select exactly ${lib.concatStringsSep ", " (sorted files)} for ${name}, got: ${lib.concatStringsSep ", " (sorted (skill.files or [ ]))}"} >&2
        failed=1
      ''
      + entriesCheck "~/${target} on ${label}" "$dir" (files ++ [ licenseName ])
      + lib.concatMapStrings (file: ''
        if ! diff -r "$dir"/${esc file} ${src}/${esc "${path}/${file}"} >&2; then
          echo ${esc "~/${target}/${file} on ${label} differs from ${path}/${file} of the pinned ${upstream.input} input"} >&2
          failed=1
        fi
      '') files
      + licenseCheck target label src license licenseName upstream
    else
      ''
        if ! diff -r ${
          lib.optionalString (!licenseInside) "--exclude=${esc licenseName}"
        } "$dir" ${src}/${esc path} >&2; then
          echo ${esc "~/${target} on ${label} differs from ${path} of the pinned ${upstream.input} input"} >&2
          failed=1
        fi
      ''
      + licenseCheck target label src license licenseName upstream;

  licenseCheck =
    target: label: src: license: licenseName: upstream:
    if license == null then
      ''
        if ! grep -q 'MIT' "$dir/LICENSE-SOURCE" 2>/dev/null \
          || ! grep -qF ${esc (upstream.expectedRev or "missing")} "$dir/LICENSE-SOURCE"; then
          echo ${esc "~/${target} on ${label} has no license file upstream, so its LICENSE-SOURCE must name the MIT license and the pinned revision"} >&2
          failed=1
        fi
      ''
    else
      ''
        if ! cmp -s "$dir"/${esc licenseName} ${src}/${esc license}; then
          echo ${esc "the ${licenseName} of ~/${target} on ${label} differs from ${license} of its pinned input"} >&2
          failed=1
        fi
      '';

  designLenses =
    target: label:
    let
      src = inputOf (impeccable.input or "");
      refDir = impeccable.referencePath or "";
    in
    entriesCheck "~/${target} on ${label}" "$dir" [
      "LICENSE"
      "NOTICE.md"
      "SKILL.md"
      "references"
    ]
    + entriesCheck "~/${target}/references on ${label}" "$dir/references" lensReferences
    + ''
      if ! cmp -s "$dir/SKILL.md" ${../home/h82/agents/skills/design-lenses/SKILL.md}; then
        echo ${esc "the SKILL.md of ~/${target} on ${label} differs from the in-tree design-lenses wrapper"} >&2
        failed=1
      fi
    ''
    + (
      if src == null then
        ''
          echo ${esc "no impeccable flake input to compare ~/${target} on ${label} against"} >&2
          failed=1
        ''
      else
        lib.concatMapStrings (file: ''
          if ! cmp -s "$dir/references"/${esc file} ${src}/${esc "${refDir}/${file}"}; then
            echo ${esc "~/${target}/references/${file} on ${label} differs from the pinned impeccable input"} >&2
            failed=1
          fi
        '') lensReferences
        + ''
          if ! cmp -s "$dir/LICENSE" ${src}/LICENSE || ! cmp -s "$dir/NOTICE.md" ${src}/NOTICE.md; then
            echo ${esc "the LICENSE or NOTICE.md of ~/${target} on ${label} differs from the pinned impeccable input"} >&2
            failed=1
          fi
        ''
    );

  materialized =
    label: homeFiles: root: name:
    let
      target = "${root}/${name}";
    in
    ''
      dir=${homeFiles}/${target}
    ''
    + frontmatter target label name
    + (
      if name == "design-lenses" then
        designLenses target label
      else if name == "ux-flows" then
        ''
          if ! diff -r "$dir" ${../home/h82/agents/skills/ux-flows} >&2; then
            echo ${esc "~/${target} on ${label} differs from the in-tree ux-flows skill"} >&2
            failed=1
          fi
        ''
      else
        published target label name
    );

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
        lib.concatMapStrings (name: homeFile label userConfig "${root}/${name}") allNames
    ) roots
    + lib.optionalString (homeFiles == null) ''
      echo ${esc "no materialized home-files on ${label}"} >&2
      failed=1
    ''
    + lib.optionalString (homeFiles != null) (
      lib.concatMapStrings (
        root: lib.concatMapStrings (name: materialized label homeFiles root name) allNames
      ) roots
    );

  pinCheck =
    upstream:
    let
      input = upstream.input or "";
      node = lock.nodes.${input} or { };
      lockedRev = node.locked.rev or "";
      originalRef = node.original.ref or node.original.rev or "";
    in
    ''
      if [ -z ${esc lockedRev} ] || [ ${esc (upstream.expectedRev or "")} != ${esc lockedRev} ]; then
        echo ${esc "the pinned ${input} revision drifted: the registry expects '${upstream.expectedRev or ""}', flake.lock resolved '${lockedRev}'"} >&2
        failed=1
      fi
      if [ ${esc (upstream.ref or "")} != ${esc originalRef} ]; then
        echo ${esc "the registry ref '${upstream.ref or ""}' of ${input} does not match the ref '${originalRef}' flake.lock recorded"} >&2
        failed=1
      fi
    '';
in
pkgs.runCommand "pinned-skills-tests" { } ''
  ${configurations.userGuard}
  failed=0

  ${lib.concatMapStrings pinCheck pinned}

  if [ ${esc (lib.concatStringsSep " " (sorted (lib.attrNames registered)))} != ${esc (lib.concatStringsSep " " (sorted publishedNames))} ]; then
    echo ${esc "the registry's skills must be exactly ${lib.concatStringsSep ", " (sorted publishedNames)}"} >&2
    failed=1
  fi

  ${lib.concatMapStringsSep "\n" assertEntry configurations.userEntries}

  if [ "$failed" != "0" ]; then
    exit 1
  fi

  touch $out
''
