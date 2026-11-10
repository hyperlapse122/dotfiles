/*
  Check interface:

    import ./tests/agent-browser-deps.nix { inherit pkgs self; }

  Asserts that every configuration `tests/lib/configurations.nix` yields,
  production and bootstrap alike, carries what
  `agent-browser install --with-deps` installs on apt or dnf systems, so the
  Chrome for Testing build that `agent-browser install` downloads can run
  through nix-ld. Every assertion reads built output rather than the option
  lists it derives from:

  - the system path's share/nix-ld/lib, which is NIX_LD_LIBRARY_PATH, carries
    ld.so, the baseline gcc/zlib/openssl libraries, and every soname Chrome for
    Testing names in its NEEDED entries, plus the GTK, Xcursor, and X11-xcb
    libraries it dlopens;
  - built /etc/set-environment exports NIX_LD and NIX_LD_LIBRARY_PATH, and
    built /etc/tmpfiles.d/00-nixos.conf links /lib64/ld-linux-x86-64.so.2 to an
    executable /libexec/nix-ld binary;
  - the system path carries an executable bin/certutil, which agent-browser
    runs to import a CA certificate;
  - fontconfig, loaded from the built /etc/fonts/conf.d/00-nixos-cache.conf,
    resolves the font families upstream installs.

  The soname and family lists are this check's own literals, taken from
  `readelf -d` on Chrome for Testing 154 and from upstream install.rs, so a
  dropped provider in the module cannot silently shrink what is asserted.

  The fontconfig file is the cache fragment rather than fonts.conf, because
  fonts.conf includes the absolute /etc/fonts/conf.d, which does not exist in
  the build sandbox; the fragment carries every font <dir> itself.

  The builder collects every failure instead of exiting at the first, so one
  red build names every missing item across every configuration.

  It cannot see whether Chrome actually launches; confirm that on hardware.
*/
{ pkgs, self }:
let
  inherit (pkgs.lib) concatMapStrings escapeShellArg;

  esc = value: escapeShellArg (toString value);

  configurations = import ./lib/configurations.nix { inherit pkgs self; };

  sonames = [
    "ld.so"
    "libz.so.1"
    "libssl.so.3"
    "libcrypto.so.3"
    "libglib-2.0.so.0"
    "libgobject-2.0.so.0"
    "libgio-2.0.so.0"
    "libnspr4.so"
    "libnss3.so"
    "libnssutil3.so"
    "libsmime3.so"
    "libatk-1.0.so.0"
    "libatk-bridge-2.0.so.0"
    "libatspi.so.0"
    "libdbus-1.so.3"
    "libcups.so.2"
    "libexpat.so.1"
    "libxcb.so.1"
    "libxkbcommon.so.0"
    "libasound.so.2"
    "libgbm.so.1"
    "libX11.so.6"
    "libXext.so.6"
    "libXcomposite.so.1"
    "libXdamage.so.1"
    "libXfixes.so.3"
    "libXrandr.so.2"
    "libcairo.so.2"
    "libpango-1.0.so.0"
    "libudev.so.1"
    "libgcc_s.so.1"
    "libgtk-3.so.0"
    "libXcursor.so.1"
    "libX11-xcb.so.1"
  ];

  families = [
    "Noto Sans CJK KR"
    "Noto Color Emoji"
    "Liberation Sans"
    "FreeSans"
  ];

  checkHost =
    entry:
    let
      inherit (entry) config name;
      libDir = "${config.system.path}/share/nix-ld/lib";
      certutil = "${config.system.path}/bin/certutil";
      fontsConf = "${config.system.build.etc}/etc/fonts/conf.d/00-nixos-cache.conf";
      setEnv = "${config.system.build.etc}/etc/set-environment";
      tmpfiles = "${config.system.build.etc}/etc/tmpfiles.d/00-nixos.conf";
    in
    ''
      host=${esc name}
      ${concatMapStrings (soname: ''
        if [ ! -e ${esc "${libDir}/${soname}"} ]; then
          echo "$host: nix-ld library path lacks "${esc soname} >&2
          failed=1
        fi
      '') sonames}
      if [ ! -x ${esc certutil} ]; then
        echo "$host: system path lacks an executable bin/certutil" >&2
        failed=1
      fi
      if [ ! -e ${esc setEnv} ]; then
        echo "$host: built /etc lacks set-environment" >&2
        failed=1
      else
        if ! grep -Fxq 'export NIX_LD="/run/current-system/sw/share/nix-ld/lib/ld.so"' ${esc setEnv}; then
          echo "$host: set-environment does not export NIX_LD" >&2
          failed=1
        fi
        if ! grep -Fxq 'export NIX_LD_LIBRARY_PATH="/run/current-system/sw/share/nix-ld/lib"' ${esc setEnv}; then
          echo "$host: set-environment does not export NIX_LD_LIBRARY_PATH" >&2
          failed=1
        fi
      fi
      if [ ! -e ${esc tmpfiles} ]; then
        echo "$host: built /etc lacks tmpfiles.d/00-nixos.conf" >&2
        failed=1
      else
        ldso=$(awk '$1 == "L+" && $2 == "/lib64/ld-linux-x86-64.so.2" { print $NF }' ${esc tmpfiles})
        case $ldso in
          /nix/store/*/libexec/nix-ld)
            if [ ! -x "$ldso" ]; then
              echo "$host: nix-ld loader $ldso is not executable" >&2
              failed=1
            fi
            ;;
          *)
            echo "$host: tmpfiles.d/00-nixos.conf does not link /lib64/ld-linux-x86-64.so.2 to /libexec/nix-ld (got '$ldso')" >&2
            failed=1
            ;;
        esac
      fi
      if [ ! -e ${esc fontsConf} ]; then
        echo "$host: built /etc lacks fonts/conf.d/00-nixos-cache.conf" >&2
        failed=1
      else
        FONTCONFIG_FILE=${esc fontsConf} fc-list : family > families.txt
        ${concatMapStrings (family: ''
          if ! grep -Fq ${esc family} families.txt; then
            echo "$host: fontconfig does not resolve "${esc family} >&2
            failed=1
          fi
        '') families}
      fi
    '';
in
pkgs.runCommand "agent-browser-deps-tests"
  {
    nativeBuildInputs = [
      pkgs.fontconfig
      pkgs.gnugrep
      pkgs.gawk
    ];
  }
  ''
    set -x
    export HOME="$TMPDIR" XDG_CACHE_HOME="$TMPDIR/cache"
    ${configurations.guard}
    failed=0
    ${concatMapStrings checkHost configurations.entries}
    if [ "$failed" != 0 ]; then
      exit 1
    fi
    touch $out
  ''
