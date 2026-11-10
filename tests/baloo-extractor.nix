/*
  Check interface:

    import ./tests/baloo-extractor.nix { inherit pkgs self; }

  Asserts that the Baloo file extractor starts without a display.

  kde-baloo.service starts before KWin exports WAYLAND_DISPLAY and DISPLAY to
  the user manager, so baloo_file and every baloo_file_extractor it spawns
  run without them. The extractor builds a QGuiApplication, which then falls
  back to wayland-0; KWin 6.8 names its first socket wayland-1, so Qt finds no
  platform and aborts, and baloo_file respawns it in a loop.

  Verifies, on every configuration `tests/lib/configurations.nix` yields,
  production and bootstrap alike, by resolving kde-baloo.service from the
  generation the way the user manager does rather than reading the option
  that renders it. The unit directories, highest priority first, are h82's
  Home Manager ~/.config/systemd/user, /etc/systemd/user (only when the
  generation materialises it there), and share/systemd/user under the system
  path:
  - the fragment is the first kde-baloo.service among them, and its
    ExecStart runs baloo_file, so a missing, masked, or replaced unit fails.
  - the drop-ins are every kde-baloo.service.d/*.conf among them, a name in
    a higher directory hiding the same name below, applied in name order.
  - the effective environment is the Environment= assignments of the
    [Service] sections of the fragment and those drop-ins, in that order,
    with an empty Environment= resetting it and systemd-style quoting. It
    sets QT_QPA_PLATFORM=offscreen and does not set PATH, as
    systemd.user.services would, replacing the session's PATH.
  - the extractor beside that baloo_file, run with only HOME and that
    environment, exits 0 on empty input. No WAYLAND_DISPLAY or DISPLAY
    reaches it, as none reaches the service.
  - baloo_file itself, run with that environment on a private session bus,
    indexes a fixture file's content, so the extractor it spawns extracts
    rather than only starts.

  It cannot see drop-ins created at runtime. Every failure is collected in
  one build.
*/
{ pkgs, self }:
let
  inherit (pkgs) lib;

  configurations = import ./lib/configurations.nix { inherit pkgs self; };

  esc = value: lib.escapeShellArg (toString value);

  etcFile = import ./lib/etc-file.nix { inherit lib; };

  assertEntry =
    entry:
    let
      units = etcFile entry.config "systemd/user";
      homeFiles = entry.user.home-files or null;
      homeUnits = if homeFiles == null then "" else "${homeFiles}/.config/systemd/user";
      packaged = "${entry.config.system.path}/share/systemd/user";
    in
    if units == null then
      ''
        echo ${esc "${entry.name}: the built system materialises no /etc/systemd/user tree"} >&2
        failed=1
      ''
    else
      ''
        check_entry ${esc entry.name} ${esc homeUnits} ${esc units} ${esc packaged}
      '';
in
pkgs.runCommand "baloo-extractor-tests"
  {
    nativeBuildInputs = [
      pkgs.coreutils
      pkgs.dbus
      pkgs.findutils
      pkgs.gawk
      pkgs.gnugrep
      pkgs.gnused
    ];
  }
  ''
    ${configurations.guard}
    failed=0

    # The Environment= values of a unit file's [Service] sections; systemd
    # ignores the key in any other section.
    environment_of() {
      awk '
        /^[[:space:]]*\[/ { service = ($0 ~ /^[[:space:]]*\[Service\][[:space:]]*$/); next }
        service && sub(/^[[:space:]]*Environment[[:space:]]*=[[:space:]]*/, "") { print }
      ' "$1"
    }

    check_entry() {
      local name=$1
      shift
      local -a dirs=()
      local dir
      for dir in "$@"; do
        [ -n "$dir" ] && dirs+=("$dir")
      done

      local fragment=""
      for dir in "''${dirs[@]}"; do
        if [ -e "$dir/kde-baloo.service" ]; then
          fragment="$dir/kde-baloo.service"
          break
        fi
      done

      local exec=""
      [ -n "$fragment" ] && exec=$(sed -n 's/^ExecStart=//p' "$fragment" 2>/dev/null | tail -n 1)
      case "$exec" in
        /*/libexec/kf6/baloo_file) ;;
        *)
          echo "$name: kde-baloo.service is missing, masked, or does not run baloo_file (ExecStart='$exec')" >&2
          failed=1
          return
          ;;
      esac

      local -A dropins=()
      local dropin base
      for dir in "''${dirs[@]}"; do
        for dropin in "$dir"/kde-baloo.service.d/*.conf; do
          [ -f "$dropin" ] || continue
          base=''${dropin##*/}
          [ -n "''${dropins[$base]-}" ] || dropins[$base]=$dropin
        done
      done

      local -a assignments=() words=()
      local line
      while IFS= read -r line; do
        if [ -z "$line" ]; then
          assignments=()
        else
          mapfile -t words < <(printf '%s\n' "$line" | xargs -n 1 printf '%s\n')
          assignments+=("''${words[@]}")
        fi
      done < <(
        environment_of "$fragment"
        for base in $(printf '%s\n' "''${!dropins[@]}" | LC_ALL=C sort); do
          environment_of "''${dropins[$base]}"
        done
      )

      local assignment platform=""
      for assignment in "''${assignments[@]}"; do
        case "$assignment" in
          PATH=*)
            echo "$name: kde-baloo.service sets PATH, which replaces the session's PATH for baloo_file" >&2
            failed=1
            ;;
          QT_QPA_PLATFORM=*) platform=''${assignment#QT_QPA_PLATFORM=} ;;
        esac
      done
      if [ "$platform" != offscreen ]; then
        echo "$name: kde-baloo.service's effective QT_QPA_PLATFORM is '$platform', not offscreen" >&2
        failed=1
      fi

      local extractor=''${exec%/baloo_file}/baloo_file_extractor
      local home="$TMPDIR/$name-home"
      mkdir -p "$home"
      local status=0
      timeout 60 env -i HOME="$home" "''${assignments[@]}" "$extractor" </dev/null >"$home/log" 2>&1 || status=$?
      if [ "$status" -ne 0 ]; then
        echo "$name: baloo_file_extractor exits $status without a display under kde-baloo.service's environment (134 is the Qt platform abort):" >&2
        sed 's/^/  /' "$home/log" >&2
        failed=1
      fi

      # The same environment drives a real indexing run: baloo_file on a
      # private session bus indexes one fixture file, and a word from its
      # content, which only the extractor records, must become searchable.
      local bin=''${exec%/libexec/kf6/baloo_file}/bin
      local index="$TMPDIR/$name-index"
      mkdir -p "$index/docs" "$index/.config" "$index/run"
      echo 'balooextractorprobe' >"$index/docs/probe.txt"
      printf '[General]\nfirst run=false\nfolders[$e]=%s/docs\n\n[Basic Settings]\nIndexing-Enabled=true\n' "$index" >"$index/.config/baloofilerc"
      # The user manager hands its own PATH to the service, so this run has
      # one too, ahead of the unit's assignments.
      if ! timeout 120 env -i PATH="$PATH" HOME="$index" XDG_RUNTIME_DIR="$index/run" "''${assignments[@]}" \
        dbus-run-session --config-file=${pkgs.dbus}/share/dbus-1/session.conf -- \
        bash -c '
          "$1" &
          for _ in $(seq 90); do
            if "$2/baloosearch6" balooextractorprobe 2>/dev/null | grep -q "/docs/probe.txt$"; then
              exit 0
            fi
            sleep 1
          done
          exit 1
        ' bash "$exec" "$bin" >"$index/log" 2>&1; then
        echo "$name: baloo_file under kde-baloo.service's environment never indexed the fixture's content:" >&2
        sed 's/^/  /' "$index/log" | tail -n 40 >&2
        failed=1
      fi
    }

    ${lib.concatMapStringsSep "\n" assertEntry configurations.entries}

    if [ "$failed" -ne 0 ]; then
      exit 1
    fi
    touch $out
  ''
