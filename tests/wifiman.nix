/*
  Check interface:

    import ./tests/wifiman.nix { inherit pkgs self; }

  Asserts what the `my.wifiman.enable` trait produces: the WiFiman Desktop GUI
  that home/h82/default.nix installs and the root daemon that
  modules/nixos/services/wifiman.nix runs. Every assertion reads the built
  system or user environment -- the unit file, its pre-start script, the
  binaries and their wrapper -- never the options the modules set.

  Verifies, per configuration that enables the trait:
  - home.path carries bin/wifiman-desktop and
    share/applications/wifiman-desktop.desktop.
  - wifiman-desktop.service is a regular unit, not masked, whose ExecStart is
    an executable lib/wifiman-desktop/wifiman-desktopd, and
    multi-user.target.wants holds it.
  - the unit sets BASE=/var/lib/wifiman-desktop and
    StateDirectory=wifiman-desktop, and its pre-start script copies
    wg_report.sh, which the daemon chmods, rather than linking it.
  - every tool the daemon runs resolves on the unit's PATH.
  - neither binary has an unresolved library, the GUI's runpath reaches
    libayatana-appindicator3.so.1, which it dlopens for the tray, and its
    wrapper puts iw and awk on PATH.

  Every bootstrap configuration must agree with its production output on the
  trait, so installation media never lose WiFiman the host keeps, and every
  configuration with it off, or forced off when none leaves it off, must carry
  neither the GUI nor a unit that runs wifiman-desktopd.

  The builder collects every failure before it exits, so one red build names
  every affected configuration.
*/
{ pkgs, self }:
let
  inherit (pkgs) lib;

  configurations = import ./lib/configurations.nix { inherit pkgs self; };
  wifiman = configurations.withTrait "my.wifiman.enable" (config: config.my.wifiman.enable);

  esc = value: lib.escapeShellArg (toString value);

  fail = message: ''
    echo ${esc message} >&2
    failed=1
  '';

  # Fails when ldd cannot read the binary in the shell variable `var`, or
  # reports one of its libraries unresolved.
  assertResolved = var: message: ''
    if ! libs=$(ldd "${"$" + var}"); then
      ${fail message}
    elif missing=$(grep 'not found' <<< "$libs"); then
      ${fail message}
      echo "$missing" >&2
    fi
  '';

  etcFile = import ./lib/etc-file.nix { inherit lib; };
  units = config: etcFile config "systemd/system";

  # What the daemon and the wg-quick it runs call through PATH.
  daemonTools = [
    "wg"
    "wg-quick"
    "wireguard-go"
    "sh"
    "bash"
    "awk"
    "iw"
    "ip"
    "ifconfig"
    "netstat"
    "nmcli"
    "resolvconf"
    "iptables"
    "pgrep"
    "sysctl"
  ];

  checkEnabled =
    entry:
    let
      inherit (entry) name;
      homePath = entry.user.home.path or "";
      tree = units entry.config;
    in
    ''
      homePath=${esc homePath}
      if [ -z "$homePath" ] || [ ! -x "$homePath/bin/wifiman-desktop" ]; then
        ${fail "${name}: home.path carries no executable bin/wifiman-desktop"}
      else
        gui=$(dirname "$(readlink -f "$homePath/bin/wifiman-desktop")")/.wifiman-desktop-wrapped
        if [ ! -x "$gui" ]; then
          ${fail "${name}: bin/wifiman-desktop is not the wrapGAppsHook wrapper of .wifiman-desktop-wrapped"}
        else
          ${assertResolved "gui" "${name}: the WiFiman GUI has unresolved libraries"}
          tray=0
          IFS=: read -ra rpath <<< "$(patchelf --print-rpath "$gui")"
          for dir in "''${rpath[@]}"; do
            if [ -e "$dir/libayatana-appindicator3.so.1" ]; then
              tray=1
            fi
          done
          if [ "$tray" != 1 ]; then
            ${fail "${name}: the WiFiman GUI's runpath reaches no libayatana-appindicator3.so.1 for its tray"}
          fi
          # makeBinaryWrapper embeds its arguments in the binary as text.
          wrapperPath=$(grep -ao "^ *--prefix 'PATH' ':' '[^']*'" "$homePath/bin/wifiman-desktop" || true)
          wrapperDirs=$(grep -o '/nix/store/[^:'"'"']*' <<< "$wrapperPath" || true)
          ${lib.concatMapStrings
            (tool: ''
              found=0
              for dir in $wrapperDirs; do
                if [ -x "$dir/${tool}" ]; then
                  found=1
                fi
              done
              if [ "$found" != 1 ]; then
                ${fail "${name}: the WiFiman GUI wrapper puts no ${tool} on PATH"}
              fi
            '')
            [
              "iw"
              "awk"
            ]
          }
        fi
      fi
      if [ ! -f "$homePath/share/applications/wifiman-desktop.desktop" ]; then
        ${fail "${name}: home.path carries no share/applications/wifiman-desktop.desktop"}
      fi
      ${
        if tree == null then
          fail "${name}: the built system declares no /etc/systemd/system tree"
        else
          ''
            unit=${esc "${tree}/wifiman-desktop.service"}
            if [ ! -f "$unit" ] || [ "$(readlink -f "$unit")" = /dev/null ]; then
              ${fail "${name}: wifiman-desktop.service is missing or masked"}
              unit=/dev/null
            fi
            if [ ! -e ${esc "${tree}/multi-user.target.wants/wifiman-desktop.service"} ]; then
              ${fail "${name}: multi-user.target.wants does not hold wifiman-desktop.service"}
            fi
            daemon=$(sed -n 's/^ExecStart=//p' "$unit")
            if [[ "$daemon" != /nix/store/*/lib/wifiman-desktop/wifiman-desktopd ]] || [ ! -x "$daemon" ]; then
              ${fail "${name}: wifiman-desktop.service does not run lib/wifiman-desktop/wifiman-desktopd"}
            else
              ${assertResolved "daemon" "${name}: wifiman-desktopd has unresolved libraries"}
            fi
            if ! grep -qx 'Environment="BASE=/var/lib/wifiman-desktop"' "$unit"; then
              ${fail "${name}: wifiman-desktop.service does not set BASE=/var/lib/wifiman-desktop"}
            fi
            if ! grep -qx 'StateDirectory=wifiman-desktop' "$unit"; then
              ${fail "${name}: wifiman-desktop.service does not set StateDirectory=wifiman-desktop"}
            fi
            if ! grep -qx 'StateDirectoryMode=0700' "$unit"; then
              ${fail "${name}: wifiman-desktop.service does not set StateDirectoryMode=0700"}
            fi
            # Runs the pre-start script against a scratch state directory and
            # reads what it leaves there, as the daemon would under $BASE.
            preStart=$(sed -n 's/^ExecStartPre=//p' "$unit")
            state=$(mktemp -d)
            if [ -z "$preStart" ] || [ ! -f "$preStart" ]; then
              ${fail "${name}: wifiman-desktop.service has no pre-start script"}
            elif ! sed "s#/var/lib/wifiman-desktop#$state#g" "$preStart" | bash; then
              ${fail "${name}: the pre-start script fails against a scratch state directory"}
            fi
            ${lib.concatMapStrings
              (helper: ''
                if [ ! -L "$state/${helper}" ] || [[ "$(readlink "$state/${helper}")" != /nix/store/*/lib/wifiman-desktop/${helper} ]] || [ ! -e "$state/${helper}" ]; then
                  ${fail "${name}: the pre-start script does not link the packaged ${helper} into the state directory"}
                fi
              '')
              [
                ".env"
                "wg"
                "wg-quick"
                "wireguard-go"
              ]
            }
            if ! grep -qx 'API_PORT=63150' "$state/.env"; then
              ${fail "${name}: the state directory's .env does not set API_PORT=63150, the port the GUI calls"}
            fi
            # The daemon chmods wg_report.sh before running it, so it must be
            # a copy, and its interpreter must exist on NixOS.
            report="$state/wg_report.sh"
            interpreter=$(head -n 1 "$report" 2>/dev/null | sed -n 's/^#!\([^ ]*\).*/\1/p')
            if [ -L "$report" ] || [ ! -f "$report" ] || [ ! -x "$report" ]; then
              ${fail "${name}: the pre-start script does not copy an executable wg_report.sh into the state directory"}
            elif [[ "$interpreter" != /nix/store/* ]] || [ ! -x "$interpreter" ]; then
              ${fail "${name}: wg_report.sh's interpreter is not an executable store path"}
            fi
            # A runpath added to the prebuilt Go binaries makes them segfault,
            # which ldd cannot see, so each one is run.
            if ! "$state/wireguard-go" --version > /dev/null; then
              ${fail "${name}: the bundled wireguard-go does not run"}
            fi
            status=0
            wgUsage=$("$state/wg" -h 2>&1) || status=$?
            if [ "$status" -gt 2 ] || ! grep -q '^Usage of ' <<< "$wgUsage"; then
              ${fail "${name}: the bundled wg does not run"}
            fi
            # The sandbox has no /etc/machine-id, so the daemon stops once it
            # asks for one; by then it has started and logged under $BASE. A
            # crash in the loader is killed by a signal, status 128 or more.
            status=0
            BASE="$state" timeout 5 "$daemon" > /dev/null 2>&1 || status=$?
            if { [ "$status" -ge 128 ] && [ "$status" != 124 ]; } || ! grep -q 'Running Go service version' "$state/wifiman-desktop.log"; then
              ${fail "${name}: wifiman-desktopd does not start and log under \$BASE"}
            fi
            unitPath=$(sed -n 's/^Environment="PATH=\(.*\)"$/\1/p' "$unit")
            if [ -z "$unitPath" ]; then
              ${fail "${name}: wifiman-desktop.service sets no PATH"}
            fi
            ${lib.concatMapStrings (tool: ''
              if ! PATH="$unitPath" command -v ${tool} > /dev/null; then
                ${fail "${name}: ${tool} is not on wifiman-desktop.service's PATH"}
              fi
            '') daemonTools}
          ''
      }
    '';

  checkDisabled =
    entry:
    let
      inherit (entry) name;
      homePath = entry.user.home.path or "";
      tree = units entry.config;
    in
    ''
      if [ -e ${esc "${homePath}/bin/wifiman-desktop"} ]; then
        ${fail "${name}: home.path carries bin/wifiman-desktop with my.wifiman.enable off"}
      fi
      ${lib.optionalString (tree != null) ''
        if grep -Rlq wifiman-desktopd ${esc tree}; then
          ${fail "${name}: a unit runs wifiman-desktopd with my.wifiman.enable off"}
        fi
      ''}
    '';

  # Both outputs of a host come from one directory; the production output is
  # the bootstrap output's name without its suffix.
  checkBootstrap =
    entry:
    let
      production = self.nixosConfigurations.${lib.removeSuffix "-bootstrap" entry.name}.config;
    in
    lib.optionalString (entry.config.my.wifiman.enable != production.my.wifiman.enable) (
      fail "${entry.name}: the bootstrap output disagrees with its production output on my.wifiman.enable"
    );
in
pkgs.runCommand "wifiman-tests"
  {
    nativeBuildInputs = [
      pkgs.gnugrep
      pkgs.gnused
      pkgs.glibc.bin
      pkgs.patchelf
    ];
  }
  ''
    set -x
    ${configurations.guard}
    ${wifiman.guard}
    failed=0

    ${lib.concatMapStringsSep "\n" checkBootstrap configurations.bootstraps}
    ${lib.concatMapStringsSep "\n" checkEnabled wifiman.enabled}
    ${lib.concatMapStringsSep "\n" checkDisabled wifiman.disabled}

    if [ "$failed" != 0 ]; then
      exit 1
    fi
    touch $out
  ''
