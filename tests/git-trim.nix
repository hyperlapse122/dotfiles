/*
  Check interface:

    import ./tests/git-trim.nix { inherit pkgs self fixtures; }

  Asserts that `git trim` only deletes local branches, and never rewrites a
  checkout's HEAD, for user `h82` on every Home Manager user
  `tests/lib/configurations.nix` yields (NixOS and non-NixOS hosts, bootstrap
  outputs included). The bootstrap outputs import the same Home Manager profile
  and git-trim is meant
  to reach them too, so they are checked rather than assumed identical: a
  change that gates the profile on `my.bootstrap` fails here.

  Upstream git-trim defaults to `--delete merged:origin`, which also deletes
  merged branches on origin, and to detaching a checkout whose merged branch it
  deletes. The profile sets `merged-local` and `detach = false`, and this check
  proves both by running the packaged binary against a fixture rather than
  matching config text. Per configuration:

  - home.path carries bin/git-trim.
  - the materialized home-files/.config/git/config does not turn off git-trim's
    deletion prompt.
  - with that config installed at $XDG_CONFIG_HOME/git/config and git trim run
    from a linked worktree whose branch is merged, a merged tracking branch is
    deleted locally but survives on the bare origin, an unmerged tracking branch
    survives in both places, and the worktree keeps its branch checked out.

  git-trim reads trim.* through a vendored libgit2 that only finds global
  config at ~/.gitconfig and $XDG_CONFIG_HOME/git/config; it ignores
  GIT_CONFIG_GLOBAL. The fixture therefore installs the file where Home Manager
  puts it on the hosts, and never passes --delete, which would bypass the
  config under test.

  Every lookup carries an `or` fallback so a mutation that removes a declaration
  reaches the builder as a failing assertion rather than an evaluation error.
  See
  .compound-engineering/artifacts/solutions/best-practices/unguarded-derivation-interpolation-defeats-nix-check-mutation-testing.md

  Each configuration runs in a subshell and records failures in a file, so one
  red build names every broken assertion across every configuration. A failed
  fixture step aborts the build under errexit instead. The helper's guard runs
  first, so an empty configuration list fails the build instead of passing it.
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
pkgs.runCommand "git-trim-tests" { nativeBuildInputs = [ pkgs.git ]; } ''
  ${configurations.userGuard}
  failures=$PWD/failures
  : > "$failures"

  checkHost() (
    host=$1 homePath=$2 gitConfig=$3
    fail() { echo "$host: $*" >> "$failures"; }

    trim=$homePath/bin/git-trim
    if [ -z "$homePath" ] || [ ! -x "$trim" ]; then
      fail "git-trim is not in home.path"
      exit
    fi
    if [ -z "$gitConfig" ] || [ ! -f "$gitConfig" ]; then
      fail "home-manager renders no git/config"
      exit
    fi

    work=$(mktemp -d)
    export HOME=$work/home
    export XDG_CONFIG_HOME=$HOME/.config
    mkdir -p "$XDG_CONFIG_HOME/git"
    cp "$gitConfig" "$XDG_CONFIG_HOME/git/config"
    # The rendered config signs every commit; the sandbox has no key.
    export GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=commit.gpgSign GIT_CONFIG_VALUE_0=false

    confirm=$(git config --file "$XDG_CONFIG_HOME/git/config" --type=bool --get trim.confirm || true)
    [ "$confirm" = false ] && fail "trim.confirm turns off the deletion prompt"

    git init -q --bare "$work/origin.git"
    git clone -q "$work/origin.git" "$work/clone" 2>/dev/null
    cd "$work/clone"
    git commit -q --allow-empty -m base
    git push -q -u origin main
    git remote set-head origin main

    git switch -q -c feature
    git commit -q --allow-empty -m feature
    git push -q -u origin feature
    git switch -q main
    git merge -q --no-ff -m "merge feature" feature
    git push -q origin main

    git switch -q -c current
    git commit -q --allow-empty -m current
    git push -q -u origin current
    git switch -q main
    git merge -q --no-ff -m "merge current" current
    git push -q origin main

    git switch -q -c wip
    git commit -q --allow-empty -m wip
    git push -q -u origin wip
    git switch -q main

    git worktree add -q "$work/linked" current
    if ! (cd "$work/linked" && "$trim" --no-confirm); then
      fail "git trim exited non-zero"
    fi

    head=$(git -C "$work/linked" symbolic-ref -q HEAD || true)
    [ "$head" = refs/heads/current ] || fail "linked worktree HEAD was rewritten to '$head'"

    local_has() { git show-ref --verify --quiet "refs/heads/$1"; }
    origin_has() { git --git-dir="$work/origin.git" show-ref --verify --quiet "refs/heads/$1"; }

    local_has feature && fail "merged local branch 'feature' was not deleted"
    origin_has feature || fail "merged branch 'feature' was deleted on origin"
    local_has wip || fail "unmerged local branch 'wip' was deleted"
    origin_has wip || fail "unmerged branch 'wip' was deleted on origin"
    local_has current || fail "worktree branch 'current' was deleted"
    origin_has main || fail "'main' was deleted on origin"
  )

  ${lib.concatMapStringsSep "\n" assertEntry configurations.userEntries}

  if [ -s "$failures" ]; then
    cat "$failures" >&2
    exit 1
  fi

  touch $out
''
