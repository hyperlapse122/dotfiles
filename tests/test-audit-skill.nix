# Checks the adapted test-audit reference, its support files, attribution, and delivery under engineering-lenses in the three harness roots.
{
  pkgs,
  self,
}:
let
  inherit (pkgs) lib;

  esc = value: lib.escapeShellArg (toString value);

  name = "test-audit";

  roots = [
    ".claude/skills"
    ".config/opencode/skills"
    ".pi/agent/skills"
  ];

  upstream = "openclaw/openclaw";
  upstreamPath = ".agents/skills/test-audit";
  rev = "3195fba90643c3897c538f2f6891c405331bee9c";

  attribution = "Adapted from `${upstream}` (MIT), `${upstreamPath}` at revision `${rev}`; license in `LICENSE`.";

  markdownFiles = [
    "test-audit.md"
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

  source = ../home/h82/agents/skills/engineering-lenses/references/test-audit;

  configurations = import ./lib/configurations.nix { inherit pkgs self; };

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
      target = "${root}/engineering-lenses/references/${name}";
    in
    ''
      dir=${homeFiles}/${target}
      if [ -L "$dir/test-audit.md" ]; then
        echo ${esc "the test-audit.md of ~/${target} on ${label} is a symlink in home-files; link the skill directory, not its files"} >&2
        failed=1
      fi
      if [ ! -f "$dir/test-audit.md" ]; then
        echo ${esc "~/${target} on ${label} holds no test-audit.md in home-files"} >&2
        failed=1
      else
        actual=${frontmatter "name" ''"$dir/test-audit.md"''}
        if [ "$actual" != ${esc name} ]; then
          echo ${esc "the test-audit.md of ~/${target} on ${label} must declare name ${name}, got:"} "'$actual'" >&2
          failed=1
        fi
        description=${frontmatter "description" ''"$dir/test-audit.md"''}
        description=$(printf '%s' "$description" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//; s/^"(.*)"$/\1/; s/^'"'"'(.*)'"'"'$/\1/; s/^[[:space:]]+//; s/[[:space:]]+$//')
        case "$description" in
          "" | null | Null | NULL | "~") description= ;;
        esac
        if [ -z "$description" ]; then
          echo ${esc "the test-audit.md of ~/${target} on ${label} declares no description"} >&2
          failed=1
        fi
      fi
      if ! grep -qF '(test-audit.md)' "$dir/CAMPAIGN.md" || ! grep -qF '(../test-audit.md#authoring-gate)' "$dir/references/audit.md"; then
        echo ${esc "~/${target} on ${label} has broken links to its entry"} >&2
        failed=1
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
        echo ${esc "~/${target} on ${label} differs from home/h82/agents/skills/engineering-lenses/references/test-audit"} >&2
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
    lib.concatMapStrings (root: homeFile label userConfig "${root}/engineering-lenses") roots
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
  ${configurations.guard}
  failed=0

  for file in ${lib.escapeShellArgs markdownFiles}; do
    if [ ! -f ${source}/"$file" ]; then
      echo "home/h82/agents/skills/engineering-lenses/references/test-audit holds no $file" >&2
      failed=1
      continue
    fi
    for token in ${lib.escapeShellArgs forbiddenTokens}; do
      status=0
      grep -qiF -- "$token" ${source}/"$file" || status=$?
      if [ "$status" = 0 ]; then
        echo "home/h82/agents/skills/engineering-lenses/references/test-audit/$file names '$token', which belongs to OpenClaw's own tooling" >&2
        failed=1
      elif [ "$status" != 1 ]; then
        echo "could not search home/h82/agents/skills/engineering-lenses/references/test-audit/$file for '$token'" >&2
        failed=1
      fi
    done
  done

  if [ ! -f ${source}/test-audit.md ] || [ "$(tail -n 1 ${source}/test-audit.md)" != ${esc attribution} ]; then
    echo ${esc "the last line of home/h82/agents/skills/engineering-lenses/references/test-audit/test-audit.md must be: ${attribution}"} >&2
    failed=1
  fi

  ${lib.concatMapStringsSep "\n" assertEntry configurations.userEntries}

  if [ "$failed" != "0" ]; then
    exit 1
  fi

  touch $out
''
