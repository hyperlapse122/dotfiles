/*
  Check interface:

    import ./tests/ghq.nix { inherit pkgs self fixtures; }

  Asserts that ghq organizes repositories under ~/src for user `h82` on every
  Home Manager user `tests/lib/configurations.nix` yields (NixOS and non-NixOS
  hosts, bootstrap outputs included). The bootstrap outputs import the same
  Home Manager profile and ghq
  is meant to reach them too, so they are checked rather than assumed
  identical: a change that gates the profile on `my.bootstrap` fails here.

  ghq reads its root with `git config --path ghq.root`, so this check runs the
  packaged binary against the rendered Git config rather than matching config
  text. Per configuration:

  - home.path carries bin/ghq.
  - with the materialized home-files/.config/git/config installed at
    $XDG_CONFIG_HOME/git/config,
    `ghq root` prints $HOME/src, not ghq's ~/ghq default.
  - `ghq create github.com/example/project` initializes the repository at
    $HOME/src/github.com/example/project, and `ghq list --full-path` reports it.

  Every lookup carries an `or` fallback so a mutation that removes a declaration
  reaches the builder as a failing assertion rather than an evaluation error.
  See
  .compound-engineering/artifacts/solutions/best-practices/unguarded-derivation-interpolation-defeats-nix-check-mutation-testing.md

  Each configuration runs in a subshell and records failures in a file, so one
  red build names every broken assertion across every configuration. The
  helper's guard runs first, so an empty configuration list fails the build
  instead of passing it.
*/
{
  pkgs,
  self,
  fixtures ? [ ],
}:
let
  inherit (pkgs) lib;

  configurations = import ./lib/configurations.nix { inherit pkgs self fixtures; };

  esc = value: lib.escapeShellArg (toString value);

  assertEntry =
    entry:
    let
      homePath = entry.user.home.path or "";
      gitConfig =
        if (entry.user.home-files or null) != null then
          "${entry.user.home-files}/.config/git/config"
        else
          "";
    in
    ''
      checkHost ${esc entry.name} ${esc homePath} ${esc gitConfig}
    '';
in
pkgs.runCommand "ghq-tests" { nativeBuildInputs = [ pkgs.git ]; } ''
  ${configurations.userGuard}
  failures=$PWD/failures
  : > "$failures"

  checkHost() (
    host=$1 homePath=$2 gitConfig=$3
    fail() { echo "$host: $*" >> "$failures"; }

    ghq=$homePath/bin/ghq
    if [ -z "$homePath" ] || [ ! -x "$ghq" ]; then
      fail "ghq is not in home.path"
      exit
    fi
    if [ -z "$gitConfig" ] || [ ! -f "$gitConfig" ]; then
      fail "home-manager renders no git/config"
      exit
    fi

    work=$(mktemp -d)
    export HOME=$work/home
    export XDG_CONFIG_HOME=$HOME/.config
    unset GHQ_ROOT
    mkdir -p "$XDG_CONFIG_HOME/git"
    cp "$gitConfig" "$XDG_CONFIG_HOME/git/config"

    root=$("$ghq" root) || fail "ghq root exited non-zero"
    [ "$root" = "$HOME/src" ] || fail "ghq root is '$root', expected '$HOME/src'"

    project=$HOME/src/github.com/example/project
    "$ghq" create github.com/example/project > /dev/null 2>&1 || fail "ghq create exited non-zero"
    [ -d "$project/.git" ] || fail "ghq create did not initialize $project"
    listed=$("$ghq" list --full-path || true)
    [ "$listed" = "$project" ] || fail "ghq list reports '$listed', expected '$project'"
  )

  ${lib.concatMapStringsSep "\n" assertEntry configurations.userEntries}

  if [ -s "$failures" ]; then
    cat "$failures" >&2
    exit 1
  fi

  touch $out
''
