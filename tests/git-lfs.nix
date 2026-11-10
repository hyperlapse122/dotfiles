/*
  Check interface:

    import ./tests/git-lfs.nix { inherit pkgs self fixtures; }

  Asserts that Git LFS works for user `h82` on every Home Manager user
  `tests/lib/configurations.nix` yields (NixOS and non-NixOS hosts, bootstrap
  outputs included), without a
  mutable ~/.gitconfig or a manual `git lfs install`. The profile enables
  Home Manager's programs.git.lfs, which installs git-lfs and renders the
  filter.lfs driver into git/config. Per configuration:

  - home.path carries bin/git-lfs.
  - with the materialized home-files/.config/git/config installed at
    $XDG_CONFIG_HOME/git/config and no ~/.gitconfig, committing a file that
    .gitattributes routes through
    filter=lfs stores an LFS pointer carrying the content's sha256, not the
    content itself.
  - deleting that file and checking it out again restores the content, not the
    pointer text. This also guards the skipSmudge = false default: a --skip
    smudge restores the pointer.

  The fixture exercises the filter rather than matching config text, so a
  driver that is declared but never reaches the rendered file fails here. See
  .compound-engineering/artifacts/solutions/best-practices/nix-check-reads-option-value-not-materialized-output.md

  A missing git-lfs binary records a failure but does not end the host's
  subshell: the filter commands in the rendered config use absolute store
  paths, so the fixture still runs and each broken property reports its own
  failure.

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
pkgs.runCommand "git-lfs-tests" { nativeBuildInputs = [ pkgs.git ]; } ''
  ${configurations.userGuard}
  failures=$PWD/failures
  : > "$failures"

  checkHost() (
    host=$1 homePath=$2 gitConfig=$3
    fail() { echo "$host: $*" >> "$failures"; }

    if [ -z "$homePath" ] || [ ! -x "$homePath/bin/git-lfs" ]; then
      fail "git-lfs is not in home.path"
    fi
    if [ -z "$gitConfig" ] || [ ! -f "$gitConfig" ]; then
      fail "home-manager renders no git/config"
      exit
    fi

    work=$(mktemp -d)
    export HOME=$work/home
    export XDG_CONFIG_HOME=$HOME/.config
    export PATH=$homePath/bin:$PATH
    mkdir -p "$XDG_CONFIG_HOME/git"
    cp "$gitConfig" "$XDG_CONFIG_HOME/git/config"
    # The rendered config signs every commit; the sandbox has no key.
    export GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=commit.gpgSign GIT_CONFIG_VALUE_0=false

    git init -q "$work/repo"
    cd "$work/repo"
    echo '*.bin filter=lfs diff=lfs merge=lfs -text' > .gitattributes
    printf 'large asset %s\n' "$host" > "$work/content"
    cp "$work/content" data.bin
    oid=$(sha256sum "$work/content" | cut -d' ' -f1)
    git add .gitattributes data.bin
    git commit -q -m "add asset"

    blob=$(git cat-file -p HEAD:data.bin)
    case $blob in
      "version https://git-lfs.github.com/spec/v1"*"oid sha256:$oid"*) ;;
      *) fail "committed data.bin is not an LFS pointer to its content" ;;
    esac

    rm data.bin
    git checkout -q -- data.bin
    cmp -s data.bin "$work/content" || fail "checkout did not restore data.bin content"
  )

  ${lib.concatMapStringsSep "\n" assertEntry configurations.userEntries}

  if [ -s "$failures" ]; then
    cat "$failures" >&2
    exit 1
  fi

  touch $out
''
