/*
  Check interface:

    import ./tests/test-audit-skill.nix { inherit pkgs self fixtures; }

  Asserts that the vendored test-audit skill reaches every harness for user
  `h82` on every host this flake declares, and that its text stays
  generalized and attributed:

    Claude Code               ~/.claude/skills/test-audit
    Antigravity CLI, and T3 Code's Antigravity instances
                              ~/.gemini/antigravity-cli/skills/test-audit
    OMP                       ~/.omp/agent/skills/test-audit
    Codex                     ~/.codex/skills/test-audit

  The user list is `userEntries` from `tests/lib/configurations.nix`, so the
  NixOS and non-NixOS Linux user environments are both covered, and the
  helper's guard fails the build when that list is empty. The exact population
  of each root, test-audit included, is tests/korean-skills.nix's to check.

  Verifies, per Home Manager user:
  - each delivery has one enabled Home Manager entry found by resolved target;
    OMP owns its whole root while other harnesses link the skill separately.
  - each target exists in the materialized `home-files`, holds a SKILL.md
    whose frontmatter `name` is test-audit and whose `description` is not
    empty, a CAMPAIGN.md, a references/audit.md, and a LICENSE that starts with
    "MIT License", and matches the in-tree source
    home/h82/agents/skills/test-audit byte for byte. See
    .compound-engineering/artifacts/solutions/best-practices/nix-check-reads-option-value-not-materialized-output.md
  - each target's SKILL.md in `home-files` is not a symlink, because Codex
    skips a SKILL.md symlink.

  Once, over the in-tree source:
  - none of the three Markdown files contains a token of OpenClaw's own
    tooling, matched case-insensitively anywhere, so a negated sentence that
    names one still fails. See
    .compound-engineering/artifacts/solutions/best-practices/substring-sentence-check-passes-a-negated-instruction.md
    The source holds no store path, so no store hash can spell a token.
  - the last line of SKILL.md is the attribution line naming the upstream,
    its path, and the revision written here.

  The expected values are written here, not read from the module, so a
  mutation of the module turns this red. Every lookup carries an `or`
  fallback and each store path is interpolated only inside its present
  branch, so a removed declaration fails inside the builder rather than
  during evaluation. Globs are never expanded in the builder, because of
  stdenv's nullglob. The builder collects every failure instead of exiting at
  the first.
*/
{
  pkgs,
  self,
  fixtures,
}:
let
  inherit (pkgs) lib;

  esc = value: lib.escapeShellArg (toString value);

  name = "test-audit";

  roots = [
    ".claude/skills"
    ".gemini/antigravity-cli/skills"
    ".omp/agent/skills"
    ".codex/skills"
  ];

  upstream = "openclaw/openclaw";
  upstreamPath = ".agents/skills/test-audit";
  rev = "3195fba90643c3897c538f2f6891c405331bee9c";

  attribution = "Adapted from `${upstream}` (MIT), `${upstreamPath}` at revision `${rev}`; license in `LICENSE`.";

  markdownFiles = [
    "SKILL.md"
    "CAMPAIGN.md"
    "references/audit.md"
  ];

  # OpenClaw's own tooling, which the generalized text must not name.
  forbiddenTokens = [
    "openclaw-testing"
    "docs/help/testing"
    "check-changed.mjs"
    "pnpm deadcode"
    "Vitest"
    "Telegram"
    "autoreview"
    "native maintainer workflow"
  ];

  source = ../home/h82/agents/skills/test-audit;

  configurations = import ./lib/configurations.nix { inherit pkgs self fixtures; };

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

  frontmatter = field: file: ''
    $(awk '
      NR == 1 && $0 != "---" { exit }
      NR > 1 && $0 == "---" { exit }
      NR > 1 && /^${field}:/ { sub(/^${field}:[ ]*/, ""); print; exit }
    ' ${file})'';

  materialized =
    label: homeFiles: root:
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
        actual=${frontmatter "name" ''"$dir/SKILL.md"''}
        if [ "$actual" != ${esc name} ]; then
          echo ${esc "the SKILL.md of ~/${target} on ${label} must declare name ${name}, got:"} "'$actual'" >&2
          failed=1
        fi
        description=${frontmatter "description" ''"$dir/SKILL.md"''}
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
      for file in CAMPAIGN.md references/audit.md; do
        if [ ! -f "$dir/$file" ]; then
          echo ${esc "~/${target} on ${label} holds no"} "$file in home-files" >&2
          failed=1
        fi
      done
      if [ ! -f "$dir/LICENSE" ]; then
        echo ${esc "~/${target} on ${label} holds no LICENSE in home-files"} >&2
        failed=1
      elif [ "$(head -c 11 "$dir/LICENSE")" != "MIT License" ]; then
        echo ${esc "the LICENSE of ~/${target} on ${label} must start with MIT License"} >&2
        failed=1
      fi
      if ! diff -r "$dir" ${source} >&2; then
        echo ${esc "~/${target} on ${label} differs from home/h82/agents/skills/test-audit"} >&2
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
      root: homeFile label userConfig (if root == ".omp/agent/skills" then root else "${root}/${name}")
    ) roots
    + lib.optionalString (homeFiles == null) ''
      echo ${esc "no materialized home-files on ${label}"} >&2
      failed=1
    ''
    + lib.optionalString (homeFiles != null) (
      lib.concatMapStrings (root: materialized label homeFiles root) roots
    );
in
pkgs.runCommand "test-audit-skill-tests" { } ''
  set -x
  ${configurations.userGuard}
  failed=0

  for file in ${lib.escapeShellArgs markdownFiles}; do
    if [ ! -f ${source}/"$file" ]; then
      echo "home/h82/agents/skills/test-audit holds no $file" >&2
      failed=1
      continue
    fi
    for token in ${lib.escapeShellArgs forbiddenTokens}; do
      status=0
      grep -qiF -- "$token" ${source}/"$file" || status=$?
      if [ "$status" = 0 ]; then
        echo "home/h82/agents/skills/test-audit/$file names '$token', which belongs to OpenClaw's own tooling" >&2
        failed=1
      elif [ "$status" != 1 ]; then
        echo "could not search home/h82/agents/skills/test-audit/$file for '$token'" >&2
        failed=1
      fi
    done
  done

  if [ ! -f ${source}/SKILL.md ] || [ "$(tail -n 1 ${source}/SKILL.md)" != ${esc attribution} ]; then
    echo ${esc "the last line of home/h82/agents/skills/test-audit/SKILL.md must be: ${attribution}"} >&2
    failed=1
  fi

  ${lib.concatMapStringsSep "\n" assertEntry configurations.userEntries}

  if [ "$failed" != "0" ]; then
    exit 1
  fi

  touch $out
''
