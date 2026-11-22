{ pkgs, self }:
let
  inherit (import ./lib/host-check-helpers.nix { inherit pkgs self; })
    forEveryConfiguration
    userPackageOf
    assertUserPackage
    ;
  # No version-pin comparison: the package reads its version from the
  # pin file, so that assertion could only ever hold. The wrapper is
  # read for an ozone flag because upstream marks Wayland
  # experimental; the app must stay on its X11 default. The
  # bundled static binaries are run, because a patched one still
  # exists and is executable.
  assertConfiguration =
    entry:
    let
      chatgptPkg = userPackageOf "chatgpt" entry;
    in
    ''
      ${assertUserPackage {
        pname = "chatgpt";
        executables = [ "chatgpt" ];
        desktopEntries = [ "chatgpt.desktop" ];
      } entry}
      ${pkgs.lib.optionalString (chatgptPkg != null) ''
        if grep -q -- 'ozone' ${chatgptPkg}/bin/chatgpt; then
          echo 'the chatgpt wrapper on ${entry.name} carries an ozone flag' >&2
          fail=1
        fi
        # Exercise the generated environment without starting the GUI.
        # Replace only the final application target in a temporary copy.
        python - ${chatgptPkg}/bin/chatgpt "$PWD/chatgpt-probe" "$PWD/chatgpt-record" <<'PY'
        import pathlib, sys
        source, probe, recorder = map(pathlib.Path, sys.argv[1:])
        wrapper = source.read_text()
        target = '"${chatgptPkg}/lib/chatgpt/ChatGPT"'
        if wrapper.count(target) != 1:
            sys.exit("cannot identify the final ChatGPT exec target")
        probe.write_text(wrapper.replace(target, '"' + str(recorder) + '"'))
        probe.chmod(0o755)
        PY
        cat > chatgpt-record <<'SH'
        #!${pkgs.runtimeShell}
        command -v bwrap
        SH
        chmod +x chatgpt-record
        mkdir -p empty-path
        if ! bwrap=$(PATH="$PWD/empty-path" ./chatgpt-probe) \
          || [ "$bwrap" != '${pkgs.bubblewrap}/bin/bwrap' ]; then
          echo 'the chatgpt wrapper on ${entry.name} does not resolve the packaged bwrap' >&2
          fail=1
        fi
        python - ${chatgptPkg}/share/applications/chatgpt.desktop ${chatgptPkg}/bin/chatgpt <<'PY'
        import configparser, shlex, sys
        desktop = configparser.ConfigParser(interpolation=None, strict=False)
        desktop.read(sys.argv[1])
        command = shlex.split(desktop.get("Desktop Entry", "Exec", fallback=""))
        if not command or command[0] not in ("chatgpt", sys.argv[2]):
            sys.exit("ChatGPT desktop entry does not launch bin/chatgpt")
        PY
        # Run, not just inspect: autoPatchelf adding a runpath to these
        # static-pie binaries leaves them segfaulting while every file
        # still exists.
        for binary in codex rg; do
          if ! HOME="$TMPDIR" ${chatgptPkg}/lib/chatgpt/resources/$binary --version > /dev/null 2>&1; then
            echo "the bundled $binary in chatgpt on ${entry.name} does not run" >&2
            fail=1
          fi
        done
        if ! HOME="$TMPDIR" ${chatgptPkg}/lib/chatgpt/resources/codex-code-mode-host --help > /dev/null 2>&1; then
          echo 'the bundled codex-code-mode-host in chatgpt on ${entry.name} does not run' >&2
          fail=1
        fi
      ''}
    '';
in
pkgs.runCommand "chatgpt-tests" { nativeBuildInputs = [ pkgs.python3 ]; } ''
  set -x
  ${forEveryConfiguration assertConfiguration}
  touch $out
''
