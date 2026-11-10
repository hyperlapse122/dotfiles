/*
  Check interface:

    import ./tests/boot-splash.nix { inherit pkgs self; }

  Asserts that every production configuration `tests/lib/configurations.nix`
  yields boots silently and graphically, and that no bootstrap configuration
  does. Expectations come from each configuration's `my.bootstrap` and its GPU
  driver choice, never from the options the module under test sets.

  Every assertion reads what the machine boots from: the initrd's materialised
  /etc tree (its systemd unit tree, Plymouth configuration and themes,
  modules-load and modprobe files), the loader.conf lanzaboote installs, and the
  systemd-boot builder the bootstrap output installs with. Kernel parameters
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
  - the wired plymouth-start.service pulls in the Plymouth password agent's
    path unit, which watches for password requests and is not masked, and the
    agent service forwards them to Plymouth, so a failed TPM2 unlock asks for
    the passphrase on the splash.
  - lanzaboote's loader.conf sets `timeout 0`, so systemd-boot skips its menu
    unless a key is held.
  - the kernel command line carries every quiet-boot parameter.
  - the initrd loads at least one KMS driver, so Plymouth has a native display
    before switch-root instead of waiting out its simpledrm timeout.
  - a configuration that drives its GPU with the NVIDIA driver and modesetting
    loads nvidia, nvidia_modeset and nvidia_drm in the initrd, leaves
    nvidia_uvm to its post-load softdep, and passes nvidia-drm modeset=1 there.
    Any other configuration loads no nvidia module in the initrd.

  Verifies, on every bootstrap configuration:
  - the initrd carries no Plymouth configuration, starts no plymouth-start, and
    loads no KMS driver.
  - systemd-boot is not installed with a zero timeout.
  - the kernel command line carries none of the quiet-boot parameters.

  The check fails when no production configuration uses NVIDIA. When none
  uses another driver, the other branch runs on each production configuration
  re-evaluated with an Intel KMS driver in place of NVIDIA, so neither branch
  of the GPU assertions passes vacuously.
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
    "nvidia_drm"
  ];

  # The NVIDIA predicate and module list repeat the module's on purpose: the
  # expectation must not come from the code under test. Change both together.
  nvidiaModules = [
    "nvidia"
    "nvidia_modeset"
    "nvidia_drm"
  ];

  usesNvidia =
    config:
    lib.elem "nvidia" config.services.xserver.videoDrivers && config.hardware.nvidia.modesetting.enable;

  # A production configuration re-evaluated with the Intel driver in place of
  # NVIDIA, for a fleet in which every production configuration uses NVIDIA.
  withIntelDriver =
    entry:
    configurations.entryOf "${entry.name} with the Intel driver in place of NVIDIA" (
      self.nixosConfigurations.${entry.name}.extendModules {
        modules = [
          {
            services.xserver.videoDrivers = lib.mkForce [ "modesetting" ];
            hardware.nvidia.modesetting.enable = lib.mkForce false;
            hardware.nvidia-container-toolkit.enable = lib.mkForce false;
            boot.initrd.kernelModules = lib.mkForce [ "i915" ];
          }
        ];
      }
    );

  production =
    configurations.production
    ++ lib.optionals (lib.all (entry: usesNvidia entry.config) configurations.production) (
      map withIntelDriver configurations.production
    );

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
      modprobe = initrdFile config "/etc/modprobe.d/nixos.conf";
      installCommand = config.boot.lanzaboote.installCommand or null;
      nvidia = usesNvidia config;
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
        if ! grep -qs '^Wants=.*systemd-ask-password-plymouth\.path' "$start"; then
          ${fail' "the initrd plymouth-start.service does not pull in the Plymouth password agent's path unit"}
        fi
        if ! grep -Fxqs 'DirectoryNotEmpty=/run/systemd/ask-password' ${units}/systemd-ask-password-plymouth.path; then
          ${fail' "the initrd Plymouth password agent's path unit watches no password requests; it may be masked"}
        fi
        if ! grep -qs '^ExecStart=.*systemd-tty-ask-password-agent.*--plymouth' ${units}/systemd-ask-password-plymouth.service; then
          ${fail' "the initrd carries no Plymouth password agent, so a failed TPM2 unlock cannot prompt on the splash"}
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

      ${lib.optionalString (installCommand == null) (
        fail' "the production configuration has no lanzaboote install command"
      )}
      ${lib.optionalString (installCommand != null) ''
        loader=$(grep -o -- '--systemd-boot-loader-config [^ ]*' ${pkgs.writeText "lzbt-install" installCommand} | cut -d' ' -f2)
        if [ -z "$loader" ] || [ ! -f "$loader" ]; then
          ${fail' "the lanzaboote install command names no readable loader.conf"}
        elif ! grep -Fxq 'timeout 0' "$loader"; then
          ${fail' "lanzaboote's loader.conf does not set timeout 0, so the boot menu shows on every boot"}
        fi
      ''}

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
        ${
          if nvidia then
            ''
              for module in ${lib.escapeShellArgs nvidiaModules}; do
                if ! grep -Fxq -- "$module" ${modulesLoad}; then
                  report ${esc name}": the NVIDIA configuration does not load $module in the initrd"
                fi
              done
              if grep -Fxq nvidia_uvm ${modulesLoad}; then
                ${fail' "the initrd loads nvidia_uvm, which nixpkgs leaves to its post-load softdep"}
              fi
            ''
          else
            ''
              if grep -q '^nvidia' ${modulesLoad}; then
                ${fail' "a configuration without the NVIDIA driver loads an nvidia module in the initrd"}
              fi
            ''
        }
      ''}
      ${lib.optionalString nvidia ''
        ${lib.optionalString (modprobe == null) (fail' "the initrd carries no modprobe configuration")}
        ${lib.optionalString (modprobe != null) ''
          if ! grep -Eq '^options nvidia-drm( .*)? modeset=1( |$)' ${modprobe}; then
            ${fail' "the initrd does not pass nvidia-drm modeset=1, so nvidia_drm loads without KMS"}
          fi
        ''}
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
      ${lib.optionalString (installer != null) ''
        builder=$(grep -o '/nix/store/[^ ]*/bin/systemd-boot' ${installer} | head -1)
        if [ -z "$builder" ] || [ ! -f "$builder" ]; then
          ${fail' "the bootstrap boot loader installer names no systemd-boot builder"}
        elif ! grep -q '^TIMEOUT = "' "$builder"; then
          ${fail' "the bootstrap systemd-boot builder carries no TIMEOUT setting, so its timeout cannot be checked"}
        elif grep -Fxq 'TIMEOUT = "0"' "$builder"; then
          ${fail' "the bootstrap systemd-boot is installed with timeout 0, hiding the recovery menu"}
        fi
      ''}

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

    ${lib.optionalString (!lib.any (entry: usesNvidia entry.config) production) (
      fail "no production configuration uses the NVIDIA driver, so the NVIDIA initrd assertions would cover nothing"
    )}
    ${lib.optionalString (lib.all (entry: usesNvidia entry.config) production) (
      fail "every production configuration uses the NVIDIA driver, even the one re-evaluated with the Intel driver, so the assertion that others load no nvidia module would cover nothing"
    )}
    ${lib.concatMapStringsSep "\n" assertProduction production}
    ${lib.concatMapStringsSep "\n" assertBootstrap configurations.bootstraps}

    if [ "$failed" != 0 ]; then
      exit 1
    fi
    touch $out
  ''
