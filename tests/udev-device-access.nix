/*
  Check interface:

    import ./tests/udev-device-access.nix { inherit pkgs self; }

  Asserts that the udev rules each host actually builds carry the rule that
  disables USB power wakeup on Logitech Unifying (`c52b`) and Bolt (`c548`)
  receivers, and the `/dev/kvm` mode that rootless Podman containers depend
  on. Every assertion reads the materialised rules directory
  (`environment.etc."udev/rules.d"`), never the option lists it is derived
  from. `MODE` is decided by the last assignment in udev's file order, so the
  option value cannot say which assignment wins.

  Files are compared by name in byte order (LC_ALL=C sort), the order udev uses,
  never by a parsed numeric prefix: a 9- prefix sorts after 73-, and 060- sorts
  before it.

  Verifies:
  - every configuration carries the Logitech receiver wakeup-disable rule line
    verbatim. The rule writes sysfs directly, so no file order constrains it,
    and its presence stops an empty rules directory passing.
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
  Podman expectation is taken from each configuration's `my.podman.enable`
  trait, never from the udev option lists the module under test sets.

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
  inherit (lib) boolToString escapeShellArg;

  configurations = import ./lib/configurations.nix { inherit pkgs self; };
  etcFile = import ./lib/etc-file.nix { inherit lib; };
  podman = configurations.withTrait "my.podman.enable" (config: config.my.podman.enable);

  # Every rule below is text spliced into a shell script, so it is escaped
  # rather than trusted to be quote-free.
  esc = value: escapeShellArg (toString value);

  logitechRule = ''ACTION=="add", SUBSYSTEM=="usb", DRIVERS=="usb", ATTRS{idVendor}=="046d", ATTRS{idProduct}=="c52b|c548", ATTR{power/wakeup}="disabled"'';

  kvmRule = ''KERNEL=="kvm", MODE="0666", GROUP="kvm", OPTIONS+="static_node=kvm"'';
  kvmTmpfilesLine = "z /dev/kvm 0666 - kvm -";

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

    # $1 host, $2 rules directory.
    check_host() {
      if [ -z "$(files_with_line "$2" ${esc logitechRule})" ]; then
        fail "$1: no udev rules file carries: "${esc logitechRule}
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

  # The rules directory is resolved through etcFile
  # so a configuration without one, or with a disabled/retargeted entry, fails
  # inside the builder.
  entryAssertion =
    entry:
    let
      rules = etcFile entry.config "udev/rules.d";
    in
    if rules == null then
      ''
        fail ${esc "${entry.name}: the built system declares no /etc/udev/rules.d directory"}
      ''
    else
      ''
        check_host ${esc entry.name} ${esc rules}
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
  ${podman.guard}
  ${helpers}

  ${lib.concatMapStringsSep "\n" entryAssertion configurations.entries}
  ${lib.concatMapStringsSep "\n" (kvmAssertion true) podman.enabled}
  ${lib.concatMapStringsSep "\n" (kvmAssertion false) podman.disabled}

  if [ "$failed" != 0 ]; then
    exit 1
  fi
  touch $out
''
