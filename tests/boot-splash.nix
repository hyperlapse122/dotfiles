/*
  Checks the materialized boot display, password-agent fallback, boot menus,
  and early GPU loading for every production and bootstrap configuration.
  Bootvine must run in both initrd and real root, with upstream defaults and
  shutdown wiring; Plymouth must be absent. GPU coverage retains the existing
  Intel variant when every production host uses NVIDIA.
*/
{ pkgs, self }:
let
  inherit (pkgs) lib;

  configurations = import ./lib/configurations.nix { inherit pkgs self; };
  etcFile = import ./lib/etc-file.nix { inherit lib; };

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

  assertBootvine =
    entry:
    let
      inherit (entry) config name;
      fail' = message: fail "${name}: ${message}";
      initrdUnits = initrdFile config "/etc/systemd/system";
      systemUnits = etcFile config "systemd/system";
      trees = [
        {
          label = "initrd";
          path = initrdUnits;
        }
        {
          label = "real root";
          path = systemUnits;
        }
      ];
    in
    ''
      ${lib.concatMapStrings (
        tree:
        lib.optionalString (tree.path == null) (fail' "${tree.label} has no systemd unit tree")
        + lib.optionalString (tree.path != null) ''
          start=${tree.path}/sysinit.target.wants/bootvine.service
          if ! grep -Eq '^ExecStart=@/nix/store/[^ ]+/bin/bootvine @bootvine([[:space:]]|$)' "$start"; then
            ${fail' "${tree.label} does not start bootvine with switch-root survival"}
          fi
          if ! grep -Fxq 'TTYPath=/dev/tty12' "$start"; then
            ${fail' "${tree.label} bootvine has no dedicated console"}
          fi
          if ! grep -Eq '^IgnoreOnIsolate=(yes|true)$' "$start"; then
            ${fail' "${tree.label} bootvine does not survive target isolation"}
          fi
          if grep -q -- '--config' "$start"; then
            ${fail' "${tree.label} bootvine overrides its default configuration"}
          fi
          if [ -e ${tree.path}/sysinit.target.wants/plymouth-start.service ]; then
            ${fail' "${tree.label} still starts Plymouth"}
          fi
        ''
      ) trees}

      ${lib.optionalString (initrdFile config "/etc/plymouth/plymouthd.conf" != null) (
        fail' "the initrd still carries Plymouth configuration"
      )}
      ${lib.optionalString (initrdUnits != null) ''
        if ! grep -Fxq 'DirectoryNotEmpty=/run/systemd/ask-password' ${initrdUnits}/sysinit.target.wants/systemd-ask-password-console.path; then
          ${fail' "the initrd has no console password-request watcher"}
        fi
        if ! grep -Eq '^ExecStart=.*systemd-tty-ask-password-agent.*--console' ${initrdUnits}/systemd-ask-password-console.service; then
          ${fail' "the initrd has no working console password-agent fallback"}
        fi
      ''}
      ${lib.optionalString (systemUnits != null) ''
        shutdown=${systemUnits}/shutdown.target.wants/bootvine-shutdown.service
        if ! grep -Eq '^ExecStart=.*/bin/bootvine --shutdown([[:space:]]|$)' "$shutdown"; then
          ${fail' "shutdown.target does not start bootvine in shutdown mode"}
        fi
        if ! grep -Fxq 'TTYPath=/dev/tty12' "$shutdown"; then
          ${fail' "shutdown bootvine has no dedicated console"}
        fi
      ''}

      for param in ${lib.escapeShellArgs quietParams}; do
        if grep -Fxq -- "$param" ${paramsFile config}; then
          report ${esc name}": the kernel command line still carries $param"
        fi
      done
    '';

  assertProduction =
    entry:
    let
      inherit (entry) config name;
      fail' = message: fail "${name}: ${message}";

      modulesLoad = initrdFile config "/etc/modules-load.d/nixos.conf";
      modprobe = initrdFile config "/etc/modprobe.d/nixos.conf";
      installCommand = config.boot.lanzaboote.installCommand or null;
      nvidia = usesNvidia config;
    in
    ''
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
          ${fail' "the production initrd loads no early KMS driver"}
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

      modulesLoad = initrdFile config "/etc/modules-load.d/nixos.conf";
      installer = config.system.build.installBootLoader or null;
    in
    ''
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
    ${lib.concatMapStringsSep "\n" assertBootvine (production ++ configurations.bootstraps)}
    ${lib.concatMapStringsSep "\n" assertProduction production}
    ${lib.concatMapStringsSep "\n" assertBootstrap configurations.bootstraps}

    if [ "$failed" != 0 ]; then
      exit 1
    fi
    touch $out
  ''
