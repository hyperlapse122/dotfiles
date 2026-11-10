/*
  Check interface:

    import ./tests/boot-splash.nix { inherit pkgs self; }

  Asserts that every production configuration `tests/lib/configurations.nix`
  yields boots silently and graphically, and that no bootstrap configuration
  does. Expectations come from each configuration's `my.bootstrap`, never from
  the options the module under test sets.

  Every assertion reads what the machine boots from: the initrd's materialised
  /etc tree (its systemd unit tree, Plymouth configuration and themes,
  modules-load file), and the systemd-boot builder each output installs with. Kernel parameters
  are the one exception: the toplevel's kernel-params file and the bootspec
  both copy `boot.kernelParams` verbatim, and building either here would build
  each configuration's kernel and initrd that the CI build job already builds.
  They are read from the option, and production and bootstrap must disagree on
  them, so the assertion cannot fold to a constant.

  Verifies, on every production configuration:
  - the initrd wires plymouth-start.service into sysinit.target.wants, and the
    wired unit starts plymouthd rather than being masked to /dev/null.
  - the initrd Plymouth configuration selects the bgrt theme, and the initrd
    ships that theme.
  - systemd-boot is installed with a zero timeout, so it skips its menu unless
    a key is held.
  - the kernel command line carries every quiet-boot parameter.
  - the initrd loads at least one KMS driver, so Plymouth has a native display
    before switch-root instead of waiting out its simpledrm timeout.

  Verifies, on every bootstrap configuration:
  - the initrd carries no Plymouth configuration, starts no plymouth-start, and
    loads no KMS driver.
  - systemd-boot is not installed with a zero timeout.
  - the kernel command line carries none of the quiet-boot parameters.

  Failures are collected instead of exiting at the first, so one red build
  names every broken assertion across every configuration.
*/
{ pkgs, self }:
let
  inherit (pkgs) lib;

  configurations = import ./lib/configurations.nix { inherit pkgs self; };

  # Every message and path below is text spliced into a shell script; escape it
  # rather than trusting the values to be quote-free.
  esc = value: lib.escapeShellArg (toString value);

  fail = message: ''
    echo ${esc message} >&2
    failed=1
  '';

  quietParams = [
    "quiet"
    "splash"
    "loglevel=3"
    "udev.log_level=3"
    "rd.udev.log_level=3"
    "systemd.show_status=error"
    "rd.systemd.show_status=error"
  ];

  kmsDrivers = [
    "i915"
    "xe"
    "amdgpu"
    "vmwgfx"
  ];

  # The TIMEOUT a systemd-boot installer writes, read from the builder it runs.
  # Production and bootstrap must disagree on it, so the assertion cannot fold
  # to a constant.
  checkTimeout = fail': installer: expectZero: ''
    builder=$(grep -o '/nix/store/[^ ]*/bin/systemd-boot' ${installer} | head -1)
    if [ -z "$builder" ] || [ ! -f "$builder" ]; then
      ${fail' "the boot loader installer names no systemd-boot builder"}
    elif ! grep -q '^TIMEOUT = "' "$builder"; then
      ${fail' "the systemd-boot builder carries no TIMEOUT setting, so its timeout cannot be checked"}
    elif ${if expectZero then "!" else ""} grep -Fxq 'TIMEOUT = "0"' "$builder"; then
      ${fail' (
        if expectZero then
          "systemd-boot is not installed with timeout 0, so the boot menu shows on every boot"
        else
          "the bootstrap systemd-boot is installed with timeout 0, hiding the recovery menu"
      )}
    fi
  '';

  initrdFile = config: path: config.boot.initrd.systemd.contents.${path}.source or null;

  # One kernel parameter per line, so `grep -Fx` matches whole parameters
  # rather than substrings.
  paramsFile =
    config:
    pkgs.writeText "kernel-params" (lib.concatMapStrings (p: "${p}\n") config.boot.kernelParams);

  assertProduction =
    entry:
    let
      inherit (entry) config name;
      fail' = message: fail "${name}: ${message}";

      units = initrdFile config "/etc/systemd/system";
      plymouthConf = initrdFile config "/etc/plymouth/plymouthd.conf";
      themes = initrdFile config "/etc/plymouth/themes";
      modulesLoad = initrdFile config "/etc/modules-load.d/nixos.conf";
      installer = config.system.build.installBootLoader or null;
    in
    ''
      ${lib.optionalString (units == null) (fail' "the initrd materialises no systemd unit tree")}
      ${lib.optionalString (units != null) ''
        start=${units}/sysinit.target.wants/plymouth-start.service
        if [ ! -e "$start" ]; then
          ${fail' "the initrd does not wire plymouth-start.service into sysinit.target.wants"}
        elif ! grep -q '^ExecStart=.*plymouthd' "$start"; then
          ${fail' "the initrd plymouth-start.service does not start plymouthd; it may be masked"}
        fi
      ''}

      ${lib.optionalString (plymouthConf == null) (fail' "the initrd carries no Plymouth configuration")}
      ${lib.optionalString (plymouthConf != null) ''
        if ! grep -Fxq 'Theme=bgrt' ${plymouthConf}; then
          ${fail' "the initrd Plymouth configuration does not select the bgrt theme"}
        fi
      ''}
      ${lib.optionalString (themes == null) (fail' "the initrd ships no Plymouth themes")}
      ${lib.optionalString (themes != null) ''
        if [ ! -f ${themes}/bgrt/bgrt.plymouth ]; then
          ${fail' "the initrd does not ship the bgrt Plymouth theme"}
        fi
      ''}

      ${lib.optionalString (installer == null) (
        fail' "the production configuration has no boot loader installer"
      )}
      ${lib.optionalString (installer != null) (checkTimeout fail' installer true)}

      for param in ${lib.escapeShellArgs quietParams}; do
        if ! grep -Fxq -- "$param" ${paramsFile config}; then
          report ${esc name}": the kernel command line lacks $param"
        fi
      done

      ${lib.optionalString (modulesLoad == null) (
        fail' "the initrd loads no kernel modules through modules-load.d"
      )}
      ${lib.optionalString (modulesLoad != null) ''
        found=0
        for driver in ${lib.escapeShellArgs kmsDrivers}; do
          if grep -Fxq -- "$driver" ${modulesLoad}; then
            found=1
          fi
        done
        if [ "$found" = 0 ]; then
          ${fail' "the initrd loads no KMS driver, so Plymouth has no native display before switch-root"}
        fi
      ''}
    '';

  assertBootstrap =
    entry:
    let
      inherit (entry) config name;
      fail' = message: fail "${name}: ${message}";

      units = initrdFile config "/etc/systemd/system";
      modulesLoad = initrdFile config "/etc/modules-load.d/nixos.conf";
      installer = config.system.build.installBootLoader or null;
    in
    ''
      ${lib.optionalString (initrdFile config "/etc/plymouth/plymouthd.conf" != null) (
        fail' "the bootstrap initrd carries a Plymouth configuration"
      )}
      ${lib.optionalString (units == null) (
        fail' "the bootstrap initrd materialises no systemd unit tree"
      )}
      ${lib.optionalString (units != null) ''
        if [ -e ${units}/sysinit.target.wants/plymouth-start.service ]; then
          ${fail' "the bootstrap initrd starts plymouth-start.service"}
        fi
      ''}
      ${lib.optionalString (modulesLoad != null) ''
        for driver in ${lib.escapeShellArgs kmsDrivers}; do
          if grep -Fxq -- "$driver" ${modulesLoad}; then
            report ${esc name}": the bootstrap initrd loads the KMS driver $driver"
          fi
        done
      ''}

      ${lib.optionalString (installer == null) (
        fail' "the bootstrap configuration has no boot loader installer"
      )}
      ${lib.optionalString (installer != null) (checkTimeout fail' installer false)}

      for param in ${lib.escapeShellArgs quietParams}; do
        if grep -Fxq -- "$param" ${paramsFile config}; then
          report ${esc name}": the bootstrap kernel command line carries $param"
        fi
      done
    '';
in
pkgs.runCommand "boot-splash-tests"
  {
    nativeBuildInputs = [
      pkgs.gnugrep
      pkgs.coreutils
    ];
  }
  ''
    set -x
    ${configurations.guard}
    failed=0
    # For messages that expand a loop variable, which `fail` cannot escape.
    report() {
      echo "$1" >&2
      failed=1
    }

    ${lib.concatMapStringsSep "\n" assertProduction configurations.production}
    ${lib.concatMapStringsSep "\n" assertBootstrap configurations.bootstraps}

    if [ "$failed" != 0 ]; then
      exit 1
    fi
    touch $out
  ''
