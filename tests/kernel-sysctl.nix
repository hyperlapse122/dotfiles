/*
  Check interface:

    import ./tests/kernel-sysctl.nix { inherit pkgs self; }

  Asserts that every configuration renders the kernel sysctl values declared
  in modules/nixos/system/base.nix into /etc/sysctl.d/60-nixos.conf, the file
  systemd-sysctl applies at boot.

  Verifies, on every configuration `tests/lib/configurations.nix` yields,
  production and bootstrap alike:
  - the rendered file carries the inotify limits, network send buffer sizes,
    and IPv4/IPv6 forwarding lines exactly, matched as whole lines so a longer
    value cannot satisfy the assertion.

  The builder collects every failure before it exits, so one red build names
  every affected configuration.
*/
{ pkgs, self }:
let
  configurations = import ./lib/configurations.nix { inherit pkgs self; };

  expectedLines = [
    "fs.inotify.max_user_watches=524288"
    "fs.inotify.max_user_instances=524288"
    "net.ipv4.ip_forward=1"
    "net.ipv6.conf.all.forwarding=1"
    "net.core.wmem_default=4194304"
    "net.core.wmem_max=4194304"
  ];

  assertEntry =
    entry:
    let
      sysctlFile = "${entry.config.system.build.etc}/etc/sysctl.d/60-nixos.conf";
    in
    ''
      if [ ! -f ${pkgs.lib.escapeShellArg sysctlFile} ]; then
        echo "sysctl.d/60-nixos.conf is missing from the built /etc on ${entry.name}" >&2
        failed=1
      fi
    ''
    + pkgs.lib.concatMapStrings (line: ''
      if ! grep -Fxq -- '${line}' ${pkgs.lib.escapeShellArg sysctlFile}; then
        echo "${entry.name}: sysctl.d/60-nixos.conf is missing the line '${line}'" >&2
        failed=1
      fi
    '') expectedLines;
in
pkgs.runCommand "kernel-sysctl-tests" { nativeBuildInputs = [ pkgs.gnugrep ]; } ''
  set -x
  ${configurations.guard}
  failed=0

  ${pkgs.lib.concatMapStringsSep "\n" assertEntry configurations.entries}

  if [ "$failed" != 0 ]; then
    exit 1
  fi
  touch $out
''
