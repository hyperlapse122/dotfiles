/*
  Check interface:

    import ./tests/udev-device-access.nix { inherit pkgs self; }

  Asserts that the udev rules each host actually builds carry the device-access
  rules for the NuPhy Gem80 keyboard, the STM32 ROM DFU bootloader, and the
  Sennheiser BTD 600/700 dongles, and Apple iOS devices in DFU and recovery
  mode, the rules that hide the DualSense controller touchpad from libinput,
  the rule that disables USB power wakeup on Logitech Unifying (`c52b`) and
  Bolt (`c548`) receivers, and the `/dev/kvm` mode that rootless Podman
  containers depend on. Every
  assertion reads the materialised rules directory
  (`environment.etc."udev/rules.d"`), never the option lists it is derived
  from. `services.udev.extraRules` lands in 99-local.rules while
  `services.udev.packages` files keep their own names, so the option value
  cannot say which file a rule ends up in. That decides whether the rule does
  anything, because udev applies the files in byte order of their names:
  - systemd's 73-seat-late.rules queues the uaccess builtin only for devices
    already tagged when it is evaluated, so a `uaccess` tag added by a later
    file passes every check that reads an option and grants no access on real
    hardware.
  - `MODE` is decided by the last assignment, and systemd's 50-udev-default.rules
    sets 0664 on every USB device node, so a `MODE` rule in an earlier file
    loses to it.

  Files are compared by name in byte order (LC_ALL=C sort), the order udev uses,
  never by a parsed numeric prefix: a 9- prefix sorts after 73-, and 060- sorts
  before it.

  Verifies:
  - every configuration carries each Sennheiser BTD rule line verbatim,
    each in a file that sorts after the last file carrying the USB default.
  - every configuration carries the Apple DFU and recovery-mode `uaccess` rule
    line verbatim, in a file that sorts before the first file carrying the
    uaccess builtin.
  - every configuration carries both DualSense touchpad rule lines and the
    Logitech receiver wakeup-disable rule line verbatim. libinput reads
    LIBINPUT_IGNORE_DEVICE from the udev database and the Logitech rule writes
    sysfs directly, so no file order constrains them.
  - every configuration carries a file with the uaccess builtin and a file with the USB
    default. They supply the two anchors above and are the positive controls
    that stop an empty directory passing.
  - every configuration that enables the `my.nuphyGem80.enable` trait carries
    both NuPhy rule lines verbatim, each in a file that sorts before the first
    file carrying the uaccess builtin. An absent anchor fails the ordering
    assertion instead of skipping it.
  - every configuration that leaves the trait off carries neither NuPhy rule
    line. The assertion is an explicit `if`, because a bare `! grep` is exempt
    from `set -e`.
  - every configuration that enables `my.podman.enable` has the `/dev/kvm`
    0666 `static_node` rule line as the last uncommented rule, in udev's file
    order, that assigns `/dev/kvm` a `MODE`, whichever key comes first in it;
    no `/dev/kvm` rule uses `MODE:=`, which would pin an earlier mode; and the
    first `/dev/kvm` entry in the earliest-named file of the built
    `/etc/tmpfiles.d` is `z /dev/kvm 0666 - kvm -`, which tmpfiles applies to
    the static node before udevd starts. A rootless container gets the host's
    node bind-mounted and cannot change its mode, so the host's mode is what
    the container's non-root users get; systemd's own default comes from its
    `dev-kvm-mode` build option, which this repository does not control.
  - every configuration that leaves `my.podman.enable` off carries neither
    the rule line nor the tmpfiles entry.

  Coverage is every configuration `tests/lib/configurations.nix` yields. The
  NuPhy expectation is taken from each configuration's `my.nuphyGem80.enable`
  trait, never from the udev option lists the module under test sets, and at
  least one production configuration must enable the trait, or the helper fails
  the check, so the positive branch never covers zero configurations.

  The rules directory is resolved through `tests/lib/etc-file.nix`, so a
  configuration that declares none, or disables or retargets it, fails inside
  the builder rather than during evaluation or passing on `.source`. The
  builder collects every failure instead of exiting at the
  first, so one red build names every broken assertion across every
  configuration.
*/
{ pkgs, self }:
let
  inherit (pkgs) lib;
  inherit (lib) boolToString escapeShellArg escapeShellArgs;

  configurations = import ./lib/configurations.nix { inherit pkgs self; };
  etcFile = import ./lib/etc-file.nix { inherit lib; };
  nuphy = configurations.withTrait "my.nuphyGem80.enable" (config: config.my.nuphyGem80.enable);
  podman = configurations.withTrait "my.podman.enable" (config: config.my.podman.enable);

  # Every rule below is text spliced into a shell script, so it is escaped
  # rather than trusted to be quote-free.
  esc = value: escapeShellArg (toString value);

  nuphyRules = [
    ''KERNEL=="hidraw*", SUBSYSTEM=="hidraw", ATTRS{idVendor}=="19f5", ATTRS{idProduct}=="3275", TAG+="uaccess"''
    ''SUBSYSTEM=="usb", ATTR{idVendor}=="0483", ATTR{idProduct}=="df11", TAG+="uaccess"''
  ];

  btdRules = [
    ''SUBSYSTEM=="usb", ATTR{idVendor}=="3542", ATTR{idProduct}=="3000", MODE="0666"''
    ''SUBSYSTEM=="hidraw", ATTRS{idVendor}=="3542", ATTRS{idProduct}=="3000", MODE="0666"''
    ''SUBSYSTEM=="usb", ATTR{idVendor}=="3542", ATTR{idProduct}=="3001", MODE="0666"''
    ''SUBSYSTEM=="hidraw", ATTRS{idVendor}=="3542", ATTRS{idProduct}=="3001", MODE="0666"''
  ];

  appleRecoveryRule = ''SUBSYSTEM=="usb", ATTR{idVendor}=="05ac", ATTR{idProduct}=="122[27]|128[0-3]", TAG+="uaccess"'';

  dualsenseRules = [
    ''ACTION=="add|change", ATTRS{name}=="Sony Interactive Entertainment DualSense Wireless Controller Touchpad", ENV{LIBINPUT_IGNORE_DEVICE}="1"''
    ''ACTION=="add|change", ATTRS{name}=="DualSense Wireless Controller Touchpad", ENV{LIBINPUT_IGNORE_DEVICE}="1"''
  ];

  logitechRule = ''ACTION=="add", SUBSYSTEM=="usb", DRIVERS=="usb", ATTRS{idVendor}=="046d", ATTRS{idProduct}=="c52b|c548", ATTR{power/wakeup}="disabled"'';

  kvmRule = ''KERNEL=="kvm", MODE="0666", GROUP="kvm", OPTIONS+="static_node=kvm"'';
  kvmTmpfilesLine = "z /dev/kvm 0666 - kvm -";

  builtinLine = ''RUN{builtin}+="uaccess"'';
  usbDefaultLine = ''SUBSYSTEM=="usb", ENV{DEVTYPE}=="usb_device", MODE="0664"'';

  helpers = ''
    failed=0
    fail() {
      echo "$1" >&2
      failed=1
    }

    # Every rules file in $1 that carries the whole line $2.
    files_with_line() {
      grep -lFx -- "$2" "$1"/*.rules
    }

    # Whether rules file name $1 sorts strictly before $2 in byte order.
    sorts_before() {
      [ "$1" != "$2" ] && [ "$(printf '%s\n%s\n' "$1" "$2" | LC_ALL=C sort | head -n 1)" = "$1" ]
    }

    # The name of the first or last (by $3) rules file in $1 that carries the
    # fixed string $2 (an extended regex when $4 is E), or nothing when no
    # file does.
    edge_file_with() {
      edge=""
      for file in $(grep -l"''${4:-F}" -- "$2" "$1"/*.rules); do
        name=$(basename "$file")
        if [ -z "$edge" ]; then
          edge=$name
        elif [ "$3" = first ] && sorts_before "$name" "$edge"; then
          edge=$name
        elif [ "$3" = last ] && sorts_before "$edge" "$name"; then
          edge=$name
        fi
      done
      echo "$edge"
    }

    # $1 host, $2 rules directory, $3 the rules file the rule is ordered
    # against, $4 rule line, $5 before or after. The rule passes only when some
    # file carrying it sorts on that side of a present anchor.
    check_rule_order() {
      found=0
      ordered=0
      for file in $(files_with_line "$2" "$4"); do
        found=1
        name=$(basename "$file")
        if [ -n "$3" ] && [ "$5" = before ] && sorts_before "$name" "$3"; then
          ordered=1
        fi
        if [ -n "$3" ] && [ "$5" = after ] && sorts_before "$3" "$name"; then
          ordered=1
        fi
      done
      if [ "$found" = 0 ]; then
        fail "$1: no udev rules file carries: $4"
      elif [ "$ordered" = 0 ]; then
        fail "$1: the rule sits in no file applied $5 $3, so it does not take effect: $4"
      fi
    }

    # $1 host, $2 rules directory, $3 true when the NuPhy rules belong there.
    check_host() {
      host=$1
      dir=$2
      nuphy_belongs=$3
      builtin_file=$(edge_file_with "$dir" ${esc builtinLine} first)
      usb_default_file=$(edge_file_with "$dir" ${esc usbDefaultLine} last)
      if [ -z "$builtin_file" ]; then
        fail "$host: no rules file carries the uaccess builtin"
      fi
      if [ -z "$usb_default_file" ]; then
        fail "$host: no rules file carries systemd's default MODE for USB device nodes"
      fi
      for line in ${escapeShellArgs btdRules}; do
        check_rule_order "$host" "$dir" "$usb_default_file" "$line" after
      done
      check_rule_order "$host" "$dir" "$builtin_file" ${esc appleRecoveryRule} before
      for line in ${escapeShellArgs (dualsenseRules ++ [ logitechRule ])}; do
        if [ -z "$(files_with_line "$dir" "$line")" ]; then
          fail "$host: no udev rules file carries: $line"
        fi
      done
      if [ "$nuphy_belongs" = true ]; then
        for line in ${escapeShellArgs nuphyRules}; do
          check_rule_order "$host" "$dir" "$builtin_file" "$line" before
        done
      else
        for line in ${escapeShellArgs nuphyRules}; do
          if [ -n "$(files_with_line "$dir" "$line")" ]; then
            fail "$host: a NuPhy rule reaches a configuration it does not belong to: $line"
          fi
        done
      fi
    }

    # Any uncommented rule matching /dev/kvm that assigns a MODE, `MODE:=`
    # included, whichever of the two keys comes first in the rule.
    kvm_mode_pattern='^[^#]*(KERNEL=="kvm".*MODE:?=|MODE:?=.*KERNEL=="kvm")'
    # Any tmpfiles entry for the /dev/kvm path.
    kvm_tmpfiles_pattern='^[^#[:space:]]+[[:space:]]+/dev/kvm([[:space:]]|$)'

    # $1 host, $2 rules directory, $3 tmpfiles.d directory, $4 true when the
    # /dev/kvm rule and tmpfiles entry belong there.
    check_kvm() {
      if [ "$4" = true ]; then
        last_mode_file=$(edge_file_with "$2" "$kvm_mode_pattern" last E)
        last_mode_line=""
        if [ -n "$last_mode_file" ]; then
          last_mode_line=$(grep -E -- "$kvm_mode_pattern" "$2/$last_mode_file" | tail -n 1)
        fi
        if [ "$last_mode_line" != ${esc kvmRule} ]; then
          fail "$1: the last rule assigning /dev/kvm a MODE is not: "${esc kvmRule}
        fi
        # MODE:= forbids every later MODE change, so one in any file pins the
        # mode, however late the 0666 rule comes. grep -c reads all of its
        # input, so pipefail cannot turn an early match into a miss.
        if [ "$(grep -hE -- "$kvm_mode_pattern" "$2"/*.rules | grep -cF 'MODE:=' || true)" != 0 ]; then
          fail "$1: a /dev/kvm rule fixes its MODE with :="
        fi
        # tmpfiles applies the entry from the earliest-named file for a path,
        # and the first entry within that file.
        first_tmpfiles_file=$(grep -lE -- "$kvm_tmpfiles_pattern" "$3"/*.conf | LC_ALL=C sort | sed -n 1p || true)
        first_tmpfiles_line=""
        if [ -n "$first_tmpfiles_file" ]; then
          first_tmpfiles_line=$(grep -E -- "$kvm_tmpfiles_pattern" "$first_tmpfiles_file" | sed -n 1p)
        fi
        if [ "$first_tmpfiles_line" != ${esc kvmTmpfilesLine} ]; then
          fail "$1: the tmpfiles entry applied to /dev/kvm is not: "${esc kvmTmpfilesLine}
        fi
      else
        if [ -n "$(files_with_line "$2" ${esc kvmRule})" ]; then
          fail "$1: the /dev/kvm rule reaches a configuration without Podman"
        fi
        if [ -n "$(grep -lFx -- ${esc kvmTmpfilesLine} "$3"/*.conf)" ]; then
          fail "$1: the /dev/kvm tmpfiles entry reaches a configuration without Podman"
        fi
      fi
    }
  '';

  # The expectation comes from the trait, never from the udev options the
  # module under test sets. The rules directory is resolved through etcFile
  # so a configuration without one, or with a disabled/retargeted entry, fails
  # inside the builder.
  entryAssertion =
    nuphyBelongs: entry:
    let
      rules = etcFile entry.config "udev/rules.d";
    in
    if rules == null then
      ''
        fail ${esc "${entry.name}: the built system declares no /etc/udev/rules.d directory"}
      ''
    else
      ''
        check_host ${esc entry.name} ${esc rules} ${boolToString nuphyBelongs}
      '';

  # A configuration without a rules directory already fails in entryAssertion.
  # tmpfiles.d is read from the built /etc, where every file has its own name.
  kvmAssertion =
    kvmBelongs: entry:
    let
      rules = etcFile entry.config "udev/rules.d";
      tmpfiles = "${entry.config.system.build.etc}/etc/tmpfiles.d";
    in
    lib.optionalString (rules != null) ''
      check_kvm ${esc entry.name} ${esc rules} ${esc tmpfiles} ${boolToString kvmBelongs}
    '';
in
pkgs.runCommand "udev-device-access-tests" { } ''
  set -x
  ${configurations.guard}
  ${nuphy.guard}
  ${podman.guard}
  ${helpers}

  ${lib.concatMapStringsSep "\n" (entryAssertion true) nuphy.enabled}
  ${lib.concatMapStringsSep "\n" (entryAssertion false) nuphy.disabled}
  ${lib.concatMapStringsSep "\n" (kvmAssertion true) podman.enabled}
  ${lib.concatMapStringsSep "\n" (kvmAssertion false) podman.disabled}

  if [ "$failed" != 0 ]; then
    exit 1
  fi
  touch $out
''
