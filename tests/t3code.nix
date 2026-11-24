{
  pkgs,
  self,
  system,
}:
let
  # Package-only: the derivations come straight from this flake's
  # outputs, so neither can be null and no interpolation needs a
  # guard. The binaries are run, not just inspected, because a
  # stripped SEA or a patched static-pie binary still exists and is
  # executable. The pinned version is read from the pin file, so a
  # binary that reports any other version fails.
  pinnedVersion = (builtins.fromJSON (builtins.readFile ../packages/t3code-release.json)).version;
  cli = self.packages.${system}.t3code-cli;
  desktop = self.packages.${system}.t3code;
  tree = "${cli}/libexec/t3code";
  fakeRuntimeDir = "/run/user/4242";
  ptyProbe = pkgs.writeText "t3code-pty-probe.cjs" ''
    const pty = require(process.env.T3CODE_TREE + "/node_modules/node-pty");
    let output = "";
    const child = pty.spawn("${pkgs.coreutils}/bin/echo", ["pty", "spawned"], {});
    child.onData((data) => { output += data; });
    child.onExit(({ exitCode }) => {
      console.log("pty-probe exit=" + exitCode + " output=" + output.trim());
    });
  '';
in
pkgs.runCommand "t3code-tests" { } ''
  set -x
  fail=0
  export HOME="$TMPDIR"

  if ! version=$(${cli}/bin/t3 --version 2>&1); then
    echo "t3 --version fails: $version" >&2
    fail=1
  elif [ "$version" != "t3 v${pinnedVersion}" ]; then
    echo "t3 --version reports '$version', expected the pin ${pinnedVersion}" >&2
    fail=1
  fi

  # The SEA honours NODE_OPTIONS, so node-pty's native addon is
  # loaded by the patched binary itself and spawns a real pty.
  probe=$(T3CODE_TREE=${tree} NODE_OPTIONS="--require ${ptyProbe}" ${cli}/bin/t3 --version 2>&1) || true
  case $probe in
    *"pty-probe exit=0 output=pty spawned"*) ;;
    *)
      echo "node-pty does not load and spawn from the t3code-cli tree: $probe" >&2
      fail=1
      ;;
  esac

  rg=${tree}/node_modules/@cursor/sdk-${cli.platformKey}/bin/rg
  if ! "$rg" --version > /dev/null 2>&1; then
    echo "the bundled static-pie rg in t3code-cli does not run" >&2
    fail=1
  fi

  monitor=${tree}/resource-monitor/${cli.platformKey}/t3-resource-monitor
  if ! timeout 10 "$monitor" < /dev/null > monitor.out 2>&1 \
    || ! grep -q '"type":"hello"' monitor.out; then
    echo "the bundled t3-resource-monitor does not run" >&2
    cat monitor.out >&2
    fail=1
  fi

  # Takes the literal value and escapes it for the extended regex.
  expect_setenv() {
    value=$(printf '%s' "$2" | sed 's/[].[*^$+?(){}|\\]/\\&/g')
    if ! grep -qE "^[[:space:]]*--setenv $1 $value( |\$)" ${desktop}/bin/t3code-desktop; then
      echo "the t3code-desktop wrapper does not set $1 to $2" >&2
      fail=1
    fi
  }
  expect_setenv T3CODE_DISABLE_AUTO_UPDATE 1
  expect_setenv SSL_CERT_FILE /etc/ssl/certs/ca-certificates.crt

  # Expanded under a fake runtime directory, so a path baked in at
  # build time cannot match.
  containerHost=$(
    XDG_RUNTIME_DIR=${fakeRuntimeDir}
    line=$(grep -E '^[[:space:]]*--setenv CONTAINER_HOST ' ${desktop}/bin/t3code-desktop) || exit 0
    eval "set -- $line"
    printf '%s' "$3"
  )
  if [ "$containerHost" != "unix://${fakeRuntimeDir}/podman/podman.sock" ]; then
    echo "t3code-desktop sandbox CONTAINER_HOST '$containerHost' is not the session Podman socket" >&2
    fail=1
  fi

  # Podman's pre-main join removes a pause.pid it cannot open, and the
  # sandbox cannot open the host's, so the directory must stay read-only
  # there. Expanded under the fake runtime directory like CONTAINER_HOST.
  libpodTmp=$(
    XDG_RUNTIME_DIR=${fakeRuntimeDir}
    line=$(grep -E '^[[:space:]]*--ro-bind-try [^ ]*libpod/tmp' ${desktop}/bin/t3code-desktop) || exit 0
    eval "set -- $line"
    printf '%s %s' "$2" "$3"
  )
  if [ "$libpodTmp" != "${fakeRuntimeDir}/libpod/tmp ${fakeRuntimeDir}/libpod/tmp" ]; then
    echo "t3code-desktop sandbox does not bind the session's libpod/tmp read-only: '$libpodTmp'" >&2
    fail=1
  fi

  entry=${desktop}/share/applications/t3code.desktop
  if [ ! -f "$entry" ]; then
    echo "t3code-desktop ships no t3code.desktop entry" >&2
    fail=1
  else
    exec=$(sed -n 's/^Exec=\([^ ]*\).*/\1/p' "$entry")
    if [ -z "$exec" ] || [ ! -x "${desktop}/bin/$exec" ]; then
      echo "t3code.desktop Exec '$exec' names no binary in the t3code-desktop package" >&2
      fail=1
    fi
  fi

  [ "$fail" = 0 ] || exit 1
  touch $out
''
