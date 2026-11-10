/*
  Check interface:

    import ./tests/mise-settings.nix { inherit pkgs self fixtures; }

  Asserts that mise uses precompiled runtime binaries from an immutable,
  Nix-managed global config for user `h82` on every Home Manager user
  `tests/lib/configurations.nix` yields (NixOS and non-NixOS hosts, bootstrap
  outputs included). The bootstrap outputs import the same Home Manager profile
  and the setting is meant to reach them too, so they are checked rather than
  assumed identical: a change that gates the profile on `my.bootstrap` fails
  here.

  On NixOS, mise defaults all_compile to true and builds runtimes from source.
  The build sandbox may not look like NixOS to mise, so comparing the value
  alone could pass without the declaration. The check therefore asks the
  packaged mise which file supplied the setting. Per user:

  - home.path carries bin/mise, and it resolves to the upstream release
    packages/mise.nix pins rather than to nixpkgs' mise. The package's own
    versionCheckHook already proves that binary reports the pinned version,
    so the check compares the materialized path instead of re-running it.
  - the generation's home-files carries .config/mise/config.toml and no
    .config/mise/conf.d/50-home-manager.toml, so the global file is the
    read-only store link rather than a writable file for `mise use --global`.
    Reading home-files rather than option text means a disabled or retargeted
    entry fails here.
  - the home.file entry targeting .config/mise/config.toml is forced, so
    activation replaces the writable config.toml an earlier generation left
    instead of aborting on the collision.
  - with that file installed under a sandboxed $XDG_CONFIG_HOME,
    `mise settings ls --json-extended` reports all_compile as false, sourced
    from mise/config.toml.
  - the miseReplaceWritableConfig activation entry runs after writeBoundary
    and before linkGeneration, removes a regular config.toml identical to the
    generated one (which Home Manager's linker would otherwise leave
    writable), and keeps the store link. The check runs the entry's own
    script against the sandboxed $XDG_CONFIG_HOME.
  - the Home Manager warnings name no programs.mise option, so a deprecated
    option name such as enableMutableConfig cannot come back.

  Every lookup carries an `or` fallback, and store paths are interpolated only
  when the user generation exists, so a mutation that removes a declaration
  reaches the builder as a failing assertion rather than an evaluation error.
  See
  .compound-engineering/artifacts/solutions/best-practices/unguarded-derivation-interpolation-defeats-nix-check-mutation-testing.md

  Each user runs in a subshell and records failures in a file, so one red
  build names every broken assertion across every user. The helper's guard
  runs first, so an empty user list fails the build instead of passing it.
*/
{
  pkgs,
  self,
  fixtures,
}:
let
  inherit (pkgs) lib;

  configurations = import ./lib/configurations.nix { inherit pkgs self fixtures; };

  pinnedMise = "${import ../packages/mise.nix { inherit pkgs; }}/bin/mise";

  esc = value: lib.escapeShellArg (toString value);

  assertEntry =
    entry:
    let
      homeFiles = entry.user.home-files or "";
      homePath = entry.user.home.path or "";
      forced = lib.any (
        file: (file.target or "") == ".config/mise/config.toml" && (file.force or false)
      ) (lib.attrValues (entry.user.home.file or { }));
      forcedFlag = if forced then "1" else "0";
      miseWarnings = lib.concatStringsSep "\n" (
        lib.filter (lib.hasInfix "programs.mise") (entry.user.warnings or [ ])
      );
      replace = entry.user.home.activation.miseReplaceWritableConfig or { };
      replaceOrdered =
        if
          lib.elem "writeBoundary" (replace.after or [ ]) && lib.elem "linkGeneration" (replace.before or [ ])
        then
          "1"
        else
          "0";
    in
    ''
      checkHost ${esc entry.name} ${esc homeFiles} ${esc homePath} ${esc forcedFlag} ${esc miseWarnings} ${esc pinnedMise} ${esc (replace.data or "")} ${esc replaceOrdered} ${
        esc (entry.user.xdg.configHome or "")
      }
    '';
in
pkgs.runCommand "mise-settings-tests" { nativeBuildInputs = [ pkgs.jq ]; } ''
  ${configurations.userGuard}
  failures=$PWD/failures
  : > "$failures"

  checkHost() (
    host=$1 homeFiles=$2 homePath=$3 forced=$4 miseWarnings=$5 pinnedMise=$6
    replaceScript=$7 replaceOrdered=$8 configHome=$9
    fail() { echo "$host: $*" >> "$failures"; }

    if [ -n "$miseWarnings" ]; then
      fail "home-manager warns about programs.mise: $miseWarnings"
    fi
    [ "$forced" = 1 ] || fail "home.file for .config/mise/config.toml is not forced"

    mise=$homePath/bin/mise
    if [ -z "$homePath" ] || [ ! -x "$mise" ]; then
      fail "mise is not in home.path"
      exit
    fi
    resolved=$(readlink -f "$mise")
    [ "$resolved" = "$pinnedMise" ] || fail "bin/mise is '$resolved', expected the pinned upstream release '$pinnedMise'"

    if [ -z "$homeFiles" ]; then
      fail "the h82 Home Manager generation is missing"
      exit
    fi
    fragment=$homeFiles/.config/mise/conf.d/50-home-manager.toml
    if [ -e "$fragment" ] || [ -L "$fragment" ]; then
      fail "home-files carries .config/mise/conf.d/50-home-manager.toml; the global config must be mise/config.toml"
    fi
    global=$homeFiles/.config/mise/config.toml
    if [ ! -f "$global" ]; then
      fail "home-files carries no .config/mise/config.toml"
      exit
    fi

    work=$(mktemp -d)
    export HOME=$work/home
    export XDG_CONFIG_HOME=$HOME/.config
    unset MISE_CONFIG_DIR MISE_GLOBAL_CONFIG_FILE MISE_ALL_COMPILE
    installed=$XDG_CONFIG_HOME/mise/config.toml
    mkdir -p "$(dirname "$installed")" "$HOME/project"
    cp "$global" "$installed"
    cd "$HOME/project"

    settings=$("$mise" settings ls --json-extended 2> /dev/null) || {
      fail "mise settings ls exited non-zero"
      exit
    }
    # jq's // treats false as missing, so test for null explicitly.
    value=$(jq -r '.all_compile.value | if . == null then "unset" else tostring end' <<< "$settings")
    source=$(jq -r '.all_compile.source // "unset"' <<< "$settings")
    [ "$value" = false ] || fail "all_compile is '$value', expected 'false'"
    [ "$source" = "$installed" ] || fail "all_compile comes from '$source', expected '$installed'"

    # The installed copy is a regular file identical to the generated one: the
    # state Home Manager's linker would leave writable.
    if [ -z "$replaceScript" ] || [ -z "$configHome" ]; then
      fail "home.activation.miseReplaceWritableConfig is missing"
      exit
    fi
    [ "$replaceOrdered" = 1 ] || fail "miseReplaceWritableConfig does not run after writeBoundary and before linkGeneration"
    runReplace() (
      run() { "$@"; }
      VERBOSE_ARG=
      eval "''${replaceScript//"$configHome"/"$XDG_CONFIG_HOME"}"
    )
    runReplace
    if [ -e "$installed" ] || [ -L "$installed" ]; then
      fail "miseReplaceWritableConfig left a regular mise/config.toml identical to the generated one"
      exit
    fi
    ln -s "$global" "$installed"
    runReplace
    [ -L "$installed" ] || fail "miseReplaceWritableConfig removed the mise/config.toml store link"
  )

  ${lib.concatMapStringsSep "\n" assertEntry configurations.userEntries}

  if [ -s "$failures" ]; then
    cat "$failures" >&2
    exit 1
  fi

  touch $out
''
