/*
  Check interface:

    import ./tests/codex.nix { inherit pkgs self; }

  Runs the pinned Codex package this flake builds and asserts what its wrapper
  and pin promise, from the built binary's own output rather than from the
  wrapper's text:

  - `codex --version` exits 0 and prints the pinned version. The version
    attribute is compared with the pin file for the reason given on the
    claude-code check: versionCheckHook already proves the binary reports that
    attribute.
  - under two different `CODEX_HOME`s, one standing for a home a T3 Code
    instance would get only by declaring one, whose config.toml never
    receives the declared keys, `codex features list` reports `apps`,
    `in_app_updates`, `daemon_auto_start`, and `computer_use` as false even if
    config enables apps and Computer Use. The unwrapped binary beside it reports
    the first three as true, so the assertion cannot pass on a default that
    already is false; Computer Use relies on the config enabling it instead,
    because its default on Linux is not established.
  - the wrapper carries `check_for_update_on_startup=false`, which has no
    feature listing to read, so its text is the only place to see it.
  - the bundled model catalog lists `gpt-6.1-sol`, the model the cross-model
    review peer runs.
  - `codex debug prompt-input`, offline and with no login, lists a skill
    directory linked into `$CODEX_HOME/skills` exactly once, and lists it
    once again when the same directory is also linked into
    `~/.agents/skills`. A pin that stops reading `$CODEX_HOME/skills`, the
    root home/h82/agents/skills.nix links into and Codex calls deprecated,
    lists it zero times; one that stops deduplicating by the resolved
    SKILL.md lists it twice.
  - the wrapper execs a binary beside which a runnable `codex-code-mode-host`
    lives.
  - a fresh app-server thread discovers and calls an ordinary local MCP tool
    with apps disabled, offline and without credentials. This does not prove
    authenticated connector absence or live T3 behavior.
  - every NixOS configuration installs `codex` in user packages with an
    executable `bin/codex`, the pinned version, the wrapper flags, and a
    runnable sibling `codex-code-mode-host`.

  The builder collects every failure instead of exiting at the first.
*/
{ pkgs, self }:
let
  inherit (pkgs) lib;
  codex = self.packages.${pkgs.stdenv.hostPlatform.system}.codex;
  pinnedVersion = (builtins.fromJSON (builtins.readFile ../packages/codex-release.json)).version;
  configurations = import ./lib/configurations.nix { inherit pkgs self; };
  wrapperFlags = [
    "-c check_for_update_on_startup=false"
    "--disable in_app_updates"
    "--disable daemon_auto_start"
    "--disable computer_use"
  ];
  userPackageOf =
    pname: entry:
    lib.lists.findFirst (p: (p.pname or "") == pname) null (entry.user.home.packages or [ ]);
  assertConfiguration =
    entry:
    let
      codexPkg = userPackageOf "codex" entry;
    in
    ''
      ${lib.optionalString (codexPkg == null) ''
        echo 'missing codex in user packages on ${entry.name}' >&2
        fail=1
      ''}
      ${lib.optionalString (codexPkg != null) ''
        if [ ! -x ${codexPkg}/bin/codex ]; then
          echo 'codex package ships no bin/codex executable on ${entry.name}' >&2
          fail=1
        fi
        if [ ${codexPkg} != ${codex} ]; then
          echo "codex on ${entry.name} is ${codexPkg}, expected ${codex}" >&2
          fail=1
        fi
      ''}
      ${lib.optionalString (codexPkg != null && codexPkg.version != pinnedVersion) ''
        echo "codex on ${entry.name} is built from version '${codexPkg.version}', expected pin ${pinnedVersion}" >&2
        fail=1
      ''}
    '';
in
pkgs.runCommand "codex-tests" { } ''
  ${configurations.guard}
  fail=0
  export HOME="$PWD/home"
  mkdir -p "$HOME"
  wrapper=${codex}/bin/codex
  binary=${codex}/libexec/codex/codex

  if ! version=$("$wrapper" --version 2>/dev/null); then
    echo "codex --version did not exit 0" >&2
    fail=1
  fi
  if [ "$version" != "codex-cli ${pinnedVersion}" ]; then
    echo "codex --version printed '$version', expected 'codex-cli ${pinnedVersion}'" >&2
    fail=1
  fi

  for home in "$HOME/.codex" "$PWD/provider-home"; do
    mkdir -p "$home"
    printf '[features]\napps = true\ncomputer_use = true\n' > "$home/config.toml"
    if [ "$home" = "$HOME/.codex" ]; then
      listing=$(env -u CODEX_HOME "$wrapper" features list 2>/dev/null) || fail=1
    else
      listing=$(CODEX_HOME="$home" "$wrapper" features list 2>/dev/null) || fail=1
    fi
    if [ -z "$listing" ]; then
      echo "codex features list failed under $home" >&2
      fail=1
    fi
    for feature in apps in_app_updates daemon_auto_start computer_use; do
      if ! grep -Eq "^$feature +[a-z ]*false$" <<< "$listing"; then
        echo "the wrapper leaves $feature enabled under CODEX_HOME=$home" >&2
        fail=1
      fi
    done
  done

  mkdir -p default-home
  raw=$(CODEX_HOME="$PWD/default-home" "$binary" features list 2>/dev/null) || true
  for feature in apps in_app_updates daemon_auto_start; do
    if ! grep -Eq "^$feature +[a-z ]*true$" <<< "$raw"; then
      echo "the unwrapped binary does not enable $feature, so the wrapper assertion proves nothing" >&2
      fail=1
    fi
  done

  for flag in ${lib.escapeShellArgs wrapperFlags}; do
    if ! grep -qF -- "$flag" "$wrapper"; then
      echo "the codex wrapper lacks $flag" >&2
      fail=1
    fi
  done

  target=$(sed -nE 's/^exec (-a "\$0" )?"([^"]+)".*/\2/p' "$wrapper")
  if [ -z "$target" ]; then
    echo "the codex wrapper execs no binary this check can find" >&2
    fail=1
  elif ! "$(dirname "$target")/codex-code-mode-host" --help > /dev/null 2>&1; then
    echo "codex has no runnable codex-code-mode-host beside $target" >&2
    fail=1
  fi

  models=$(CODEX_HOME="$PWD/default-home" "$wrapper" debug models 2>/dev/null) || {
    echo "codex debug models failed" >&2
    fail=1
  }
  if ! grep -qF '"slug":"gpt-6.1-sol"' <<< "$models"; then
    echo "the codex model catalog does not list gpt-6.1-sol" >&2
    fail=1
  fi

  # Sets $count to how many times the prompt Codex would send offers the probe
  # skill, with $1 as HOME and $2 as CODEX_HOME. Runs offline, with no login.
  # Codex prints one `- <name>: <description>` line per skill.
  skillCount() {
    if ! (cd skill-work && HOME=$1 CODEX_HOME=$2 "$wrapper" debug prompt-input hello) \
      > prompt-input.json 2> prompt-input.log; then
      echo "codex debug prompt-input failed under CODEX_HOME=$2:" >&2
      cat prompt-input.log >&2
      fail=1
    fi
    count=$({ grep -oF -- '- probe-skill: A probe skill for the listing check.' prompt-input.json || true; } | wc -l)
  }

  # home/h82/agents/skills.nix links each skill directory into
  # ~/.codex/skills, the root Codex calls deprecated, and on some hosts Codex
  # also reaches it through ~/.agents/skills. Every link resolves to one store
  # directory, so Codex must list it once from ~/.codex/skills alone and once
  # from both roots.
  mkdir -p skill-store/probe-skill skill-work \
    only-codex/home only-codex/codex/skills \
    both-roots/home/.agents/skills both-roots/codex/skills
  cat > skill-store/probe-skill/SKILL.md <<'EOF'
  ---
  name: probe-skill
  description: A probe skill for the listing check.
  ---
  Probe.
  EOF
  ln -s "$PWD/skill-store/probe-skill" only-codex/codex/skills/probe-skill
  ln -s "$PWD/skill-store/probe-skill" both-roots/codex/skills/probe-skill
  ln -s "$PWD/skill-store/probe-skill" both-roots/home/.agents/skills/probe-skill

  skillCount "$PWD/only-codex/home" "$PWD/only-codex/codex"
  if [ "$count" -ne 1 ]; then
    echo "codex lists a skill linked into \$CODEX_HOME/skills $count times, expected once" >&2
    fail=1
  fi
  skillCount "$PWD/both-roots/home" "$PWD/both-roots/codex"
  if [ "$count" -ne 1 ]; then
    echo "codex lists a skill reached through \$CODEX_HOME/skills and ~/.agents/skills $count times, expected once" >&2
    fail=1
  fi

  ${lib.concatMapStrings assertConfiguration configurations.entries}

  ${pkgs.python3}/bin/python ${./codex-apps.py} "$wrapper"

  [ "$fail" -eq 0 ] || exit 1
  touch $out
''
