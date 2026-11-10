/*
  Check interface:

    import ./tests/antigravity-acp-path.nix { inherit pkgs; pluginSource = inputs.compound-engineering-plugin; }

  Runs the Linux agy_acp_server.par wrapper from packages/antigravity-acp-path.nix,
  built against a stub runtime whose .par prints what it was started with. The
  real runtime needs network and a Google sign-in, so its behavior through the
  wrapper is verified by hand; this check proves what the wrapper itself does,
  and that every scratch prefix under which the pinned Compound Engineering
  plugin creates an Antigravity run home is one the wrapper links into. The
  build sandbox has no /etc/ssl, so the CA bundle the runtime gets here is the
  nixpkgs fallback.

  Expected values come from the stub and test fixtures, never from the wrapper's
  own Nix expression, so a mutation of the wrapper cannot pass by changing both
  sides. Failures are collected and reported together.
*/
{
  pkgs,
  pluginSource ? null,
}:
let
  inherit (pkgs) lib;
  pluginDir = if pluginSource == null then "" else toString pluginSource;

  # A binary, not a script: the kernel replaces a script's argv[0] with the
  # interpreter, so only a binary can report the argv[0] the wrapper passed.
  stubSource = pkgs.writeText "stub-agy-acp-server.c" ''
    #include <stdio.h>
    #include <stdlib.h>
    #include <unistd.h>

    int main(int argc, char **argv) {
      const char *cert = getenv("SSL_CERT_FILE");
      char line[4096];
      printf("argv0=%s\n", argv[0]);
      printf("pid=%ld\n", (long)getpid());
      printf("cert=%s\n", cert ? cert : "<unset>");
      for (int i = 1; i < argc; i++) printf("arg=%s\n", argv[i]);
      while (fgets(line, sizeof line, stdin)) printf("stdin=%s", line);
      return 0;
    }
  '';

  stubRuntime =
    pkgs.runCommandCC "stub-antigravity-acp"
      {
        version = "0.0.0-stub";
        passthru.pin = {
          executable.name = "agy_acp_server.par";
          harness.name = "localharness_external";
        };
        # The fields packages/antigravity-acp-path.nix copies from the runtime.
        meta = {
          homepage = "https://antigravity.google";
          license = pkgs.lib.licenses.unfree;
          platforms = pkgs.lib.platforms.all;
        };
      }
      ''
        mkdir -p $out/libexec/antigravity-acp
        $CC -o $out/libexec/antigravity-acp/agy_acp_server.par ${stubSource}
        printf 'helper\n' > $out/libexec/antigravity-acp/localharness_external
        chmod 555 $out/libexec/antigravity-acp/localharness_external
      '';

  # The skills the wrapper links. no-such-skill has no source under the fake
  # HOME, so it proves a missing source is skipped.
  skills = [
    "grammar-checker"
    "humanizer"
    "no-such-skill"
    "test-audit"
  ];

  pathPackage = import ../packages/antigravity-acp-path.nix {
    inherit pkgs skills;
    runtime = stubRuntime;
  };
in
pkgs.runCommand "antigravity-acp-path-tests" { } ''
  failures=$PWD/failures
  : > "$failures"
  fail() { echo "$*" >> "$failures"; }

  # The mktemp -d prefixes of Compound Engineering v3.33.1's cross-model
  # scripts that hold a run home or a peer workspace.
  prefixes='ce-work-adapter ce-work-model-check xmodel-cr-scratch xmodel-doc-peer xmodel-doc-scratch xmodel-pov-peer'

  # Every directory the pinned plugin passes to acpx_antigravity_home must be
  # one of them, and the run home must still be its gemini-home.
  pluginDir=${lib.escapeShellArg pluginDir}
  if [ -z "$pluginDir" ] || [ ! -d "$pluginDir/skills" ]; then
    fail "compound-engineering-plugin source not passed to antigravity-acp-path check"
  else
    found=0
    for script in "$pluginDir"/skills/*/scripts/*.sh; do
      grep -qF 'acpx_antigravity_home()' "$script" || continue
      found=$((found + 1))
      grep -qF 'local home="$1/gemini-home"' "$script" \
        || fail "$script: acpx_antigravity_home no longer uses \$1/gemini-home"
      vars=$(sed -n 's/.*acpx_antigravity_home "\$\([A-Za-z0-9_]*\)".*/\1/p' "$script")
      [ -n "$vars" ] || fail "$script: no acpx_antigravity_home \"\$VAR\" call matched"
      for var in $vars; do
        prefix=$(sed -n "s/.*''${var}=\"\$(mktemp -d \"[^\"]*\\/\\([a-z0-9-]*\\)-XXXXXX\")\".*/\\1/p" "$script")
        [ -n "$prefix" ] || fail "$script: could not read the mktemp -d prefix of \$$var"
        case " $prefixes " in
          *" $prefix "*) ;;
          *) fail "$script: the plugin makes Antigravity run homes under $prefix-, which this check does not cover" ;;
        esac
      done
    done
    [ "$found" -ge 4 ] || fail "only $found plugin scripts define acpx_antigravity_home"
  fi

  wrapper=${pathPackage}/bin/agy_acp_server.par
  runtimePar=${stubRuntime}/libexec/antigravity-acp/agy_acp_server.par

  run() {
    case $1 in
      unset) set -- env -i PATH=/no-such-dir ;;
      empty) set -- env -i PATH=/no-such-dir SSL_CERT_FILE= ;;
      *) set -- env -i PATH=/no-such-dir SSL_CERT_FILE="$1" ;;
    esac
    printf 'one line\n' | ${pkgs.bash}/bin/bash -c 'echo "outer=$$"; exec "$@"' run "$@" "$wrapper" --uid= 'a b' 2> stderr
  }

  field() { sed -n "s/^$1=//p" out; }

  for mode in unset empty; do
    run $mode > out || fail "$mode SSL_CERT_FILE: the wrapper exited $?"
    cert=$(field cert)
    if [ -z "$cert" ] || [ "$cert" = '<unset>' ]; then
      fail "$mode SSL_CERT_FILE: the runtime got no CA bundle"
    elif [ ! -f "$cert" ]; then
      fail "$mode SSL_CERT_FILE: the runtime got $cert, which is not a file"
    fi
  done

  preset=$PWD/preset.pem
  printf 'fixture\n' > "$preset"
  run "$preset" > out || fail "preset SSL_CERT_FILE: the wrapper exited $?"
  cert=$(field cert)
  [ "$cert" = "$preset" ] || fail "preset SSL_CERT_FILE became '$cert'"

  outer=$(field outer)
  [ "$(field pid)" = "$outer" ] || fail "the runtime ran as pid $(field pid), not the wrapper's $outer: the wrapper does not exec"
  [ "$(field argv0)" = "$runtimePar" ] || fail "argv[0] is '$(field argv0)', not $runtimePar"

  expected=$(printf 'arg=--uid=\narg=a b\nstdin=one line')
  actual=$(grep -E '^(arg|stdin)=' out || true)
  [ "$actual" = "$expected" ] || fail "arguments or stdin changed on the way: $actual"
  unexpected=$(grep -vE '^(outer|argv0|pid|cert|arg|stdin)=' out || true)
  [ -z "$unexpected" ] || fail "the wrapper wrote to stdout: $unexpected"
  [ ! -s stderr ] || fail "the wrapper wrote to stderr: $(cat stderr)"

  helper=$(readlink -f ${pathPackage}/bin/localharness_external)
  [ "$helper" = ${stubRuntime}/libexec/antigravity-acp/localharness_external ] \
    || fail "bin/localharness_external resolves to '$helper'"

  # Run-home links.
  tmpdir=$PWD/tmp
  mkdir -p "$tmpdir"
  chmod 700 "$tmpdir"

  fakeHome=$PWD/fake-home
  skillsSrc=$fakeHome/.gemini/antigravity-cli/skills
  rulesSrc=$fakeHome/.gemini/config/rules
  mkdir -p "$skillsSrc" "$rulesSrc"
  for skill in grammar-checker humanizer test-audit style-guide; do
    mkdir -p "$skillsSrc/$skill"
  done
  printf 'rule\n' > "$rulesSrc/nix-config-01.md"

  # make_ce_home <dir or mktemp template>: a run home the way the plugin
  # makes one, under a mode-0700 directory.
  make_ce_home() {
    local parent
    case $1 in
      *XXXXXX) parent=$(mktemp -d "$1") ;;
      *) parent=$1; mkdir -p "$parent"; chmod 700 "$parent" ;;
    esac
    mkdir -p -m 700 "$parent/gemini-home/antigravity-acp"
    printf '{"auth":{"type":"oauth-personal"}}\n' > "$parent/gemini-home/antigravity-acp/settings.json"
    printf '%s\n' "$parent/gemini-home"
  }

  run_home() {
    local label=$1
    shift
    printf 'one line\n' | env -i PATH=/no-such-dir "$@" "$wrapper" > out 2> stderr \
      || fail "$label: the wrapper exited $?"
    [ "$(field argv0)" = "$runtimePar" ] || fail "$label: the runtime did not start"
    [ ! -s stderr ] || fail "$label: the wrapper wrote to stderr: $(cat stderr)"
  }

  # assert_linked <label> <home> [home-dir]: the named skills that exist are
  # linked to the fake HOME's, in private directories, and the HOME's rule
  # directory is not linked, because the ACP runtime never reads it.
  assert_linked() {
    local label=$1 home=$2 src=''${3:-$fakeHome}
    for skill in grammar-checker humanizer test-audit; do
      link=$home/antigravity-cli/skills/$skill
      [ -L "$link" ] && [ "$(readlink "$link")" = "$src/.gemini/antigravity-cli/skills/$skill" ] \
        || fail "$label: $skill is not linked to the HOME's skill"
    done
    [ ! -e "$home/antigravity-cli/skills/style-guide" ] || fail "$label: style-guide, which is not named, was linked"
    [ ! -e "$home/antigravity-cli/skills/no-such-skill" ] && [ ! -L "$home/antigravity-cli/skills/no-such-skill" ] \
      || fail "$label: no-such-skill, which has no source, was linked"
    [ ! -e "$home/config" ] && [ ! -L "$home/config" ] || fail "$label: config was created"
    for dir in antigravity-cli antigravity-cli/skills; do
      mode=$(stat -c %a "$home/$dir" 2>/dev/null || echo missing)
      [ "$mode" = 700 ] || fail "$label: $dir has mode $mode, not 700"
    done
  }

  # assert_untouched <label> <home>: nothing was created in the home.
  assert_untouched() {
    [ ! -e "$2/antigravity-cli" ] && [ ! -L "$2/antigravity-cli" ] || fail "$1: antigravity-cli was created"
    [ ! -e "$2/config" ] && [ ! -L "$2/config" ] || fail "$1: config was created"
  }

  for prefix in $prefixes; do
    home=$(make_ce_home "$tmpdir/$prefix-XXXXXX")
    run_home "$prefix" HOME="$fakeHome" GEMINI_HOME="$home"
    assert_linked "$prefix" "$home"
  done

  # Redundant and trailing slashes still name the same run home.
  home=$(make_ce_home "$tmpdir/xmodel-doc-peer-slash")
  run_home "slashes" HOME="$fakeHome" GEMINI_HOME="$tmpdir//xmodel-doc-peer-slash//gemini-home/"
  assert_linked "slashes" "$home"

  # An entry already in the run home stays as it is.
  home=$(make_ce_home "$tmpdir/xmodel-cr-scratch-XXXXXX")
  mkdir -p -m 700 "$home/antigravity-cli/skills/humanizer"
  run_home "existing entries" HOME="$fakeHome" GEMINI_HOME="$home"
  [ ! -L "$home/antigravity-cli/skills/humanizer" ] || fail "existing entries: humanizer was replaced"
  [ -L "$home/antigravity-cli/skills/test-audit" ] || fail "existing entries: test-audit is not linked"

  # A symlink planted at antigravity-cli or config is not followed.
  home=$(make_ce_home "$tmpdir/xmodel-cr-scratch-XXXXXX")
  outside=$tmpdir/outside
  mkdir -p "$outside/cli" "$outside/config"
  ln -s "$outside/cli" "$home/antigravity-cli"
  ln -s "$outside/config" "$home/config"
  run_home "planted symlinks" HOME="$fakeHome" GEMINI_HOME="$home"
  [ -z "$(find "$outside" -mindepth 2)" ] || fail "planted symlinks: the wrapper wrote through them"

  # Homes that are not Compound Engineering run homes get nothing.
  t3Home=$fakeHome/.t3/userdata/providers/antigravity/ac0a3dfd6dddb20962cecff6ee5fe65e19d3923be20e52c5ab52ff877f7e4c32
  mkdir -p -m 700 "$t3Home/antigravity-acp"
  run_home "T3 instance home" HOME="$fakeHome" GEMINI_HOME="$t3Home"
  assert_untouched "T3 instance home" "$t3Home"

  home=$(make_ce_home "$tmpdir/other-parent-XXXXXX")
  run_home "other parent name" HOME="$fakeHome" GEMINI_HOME="$home"
  assert_untouched "other parent name" "$home"

  home=$tmpdir/gemini-homes/xmodel-cr-scratch-leaf
  mkdir -p -m 700 "$home"
  run_home "other leaf name" HOME="$fakeHome" GEMINI_HOME="$home"
  assert_untouched "other leaf name" "$home"

  home=$(make_ce_home "$tmpdir/xmodel-cr-scratch-XXXXXX")
  chmod 755 "$(dirname "$home")"
  run_home "parent mode 0755" HOME="$fakeHome" GEMINI_HOME="$home"
  assert_untouched "parent mode 0755" "$home"

  parent=$(mktemp -d "$tmpdir/xmodel-cr-scratch-XXXXXX")
  real=$(mktemp -d "$tmpdir/real-home-XXXXXX")
  ln -s "$real" "$parent/gemini-home"
  run_home "symlinked gemini-home" HOME="$fakeHome" GEMINI_HOME="$parent/gemini-home"
  assert_untouched "symlinked gemini-home" "$real"

  real=$(mktemp -d "$tmpdir/real-parent-XXXXXX")
  mkdir -p -m 700 "$real/gemini-home"
  ln -s "$real" "$tmpdir/xmodel-cr-scratch-symlinked"
  run_home "symlinked parent" HOME="$fakeHome" GEMINI_HOME="$tmpdir/xmodel-cr-scratch-symlinked/gemini-home"
  assert_untouched "symlinked parent" "$real/gemini-home"

  run_home "GEMINI_HOME unset" HOME="$fakeHome"

  home=$(make_ce_home "$tmpdir/xmodel-cr-scratch-XXXXXX")
  run_home "HOME unset" GEMINI_HOME="$home"
  assert_untouched "HOME unset" "$home"

  if [ -s "$failures" ]; then
    cat "$failures" >&2
    exit 1
  fi
  touch $out
''
