/*
  Check interface:

    import ./tests/iphone-restore.nix { inherit pkgs self; }

  Asserts what modules/nixos/hardware/iphone-restore.nix produces on every
  configuration `tests/lib/configurations.nix` yields. The DFU and
  recovery-mode `uaccess` rule and its file order are asserted by
  `tests/udev-device-access.nix`; this check covers the rest of the restore
  path. Every assertion reads something activation produces -- the
  materialised systemd unit tree, the materialised udev rules directory, the
  system path -- never `services.usbmuxd.enable` or the package list.

  On every configuration:
  - the materialised unit tree carries a usbmuxd.service that runs usbmuxd
    as the usbmux user, so a unit masked to /dev/null fails, and
    multi-user.target wants it. idevicerestore reaches a device in restore
    mode only through usbmuxd.
  - some file in the materialised udev rules directory carries the usbmuxd
    module's rule giving Apple USB devices to the usbmux group, verbatim.
  - the system path ships executable bin/idevicerestore, bin/irecovery, and
    bin/ideviceinfo.
  - the shipped irecovery lists the iPhone 18 Pro Max (iPhone19,7), and the
    libirecovery that the shipped idevicerestore loads carries it too, so a
    restore of that device gets past "Unable to discover device type".

  It cannot see whether a real device enters DFU mode or restores; confirm that
  on hardware.

  Every /etc lookup carries an `or null` fallback and store paths are
  interpolated only inside the present branch, so a missing entry fails inside
  the builder rather than during evaluation. The builder collects every failure
  instead of exiting at the first, so one red build names every affected
  configuration.
*/
{ pkgs, self }:
let
  inherit (pkgs) lib;

  configurations = import ./lib/configurations.nix { inherit pkgs self; };

  # Every message and path below is text spliced into a shell script, so it is
  # escaped rather than trusted to be quote-free.
  esc = value: lib.escapeShellArg (toString value);

  fail = message: ''
    echo ${esc message} >&2
    failed=1
  '';

  usbmuxRule = ''SUBSYSTEM=="usb", ATTR{idVendor}=="05ac", GROUP="usbmux"'';

  newestDevice = "iPhone19,7";

  binaries = [
    "idevicerestore"
    "irecovery"
    "ideviceinfo"
  ];

  assertEntry =
    entry:
    let
      unitTree = entry.config.environment.etc."systemd/system".source or null;
      rules = entry.config.environment.etc."udev/rules.d".source or null;
      systemPath = entry.config.system.path;
    in
    lib.concatStringsSep "\n" (
      [
        (
          if unitTree == null then
            fail "${entry.name}: the built system declares no /etc/systemd/system tree"
          else
            ''
              # Read the unit's content, not its existence: a masked unit is
              # still present in the tree as a symlink to /dev/null.
              if ! grep -q '^ExecStart=.*/bin/usbmuxd -U usbmux' ${esc "${unitTree}/usbmuxd.service"}; then
                ${fail "${entry.name}: the materialised usbmuxd.service is missing, masked, or does not run usbmuxd as usbmux"}
              fi
              if [ ! -e ${esc "${unitTree}/multi-user.target.wants/usbmuxd.service"} ]; then
                ${fail "${entry.name}: multi-user.target does not want usbmuxd.service"}
              fi
            ''
        )
        (
          if rules == null then
            fail "${entry.name}: the built system declares no /etc/udev/rules.d directory"
          else
            ''
              if ! grep -qFx -- ${esc usbmuxRule} ${esc rules}/*.rules; then
                ${fail "${entry.name}: no udev rules file carries: ${usbmuxRule}"}
              fi
            ''
        )
      ]
      ++ map (name: ''
        if [ ! -x ${esc "${systemPath}/bin/${name}"} ]; then
          ${fail "${entry.name}: the system path ships no executable bin/${name}"}
        fi
      '') binaries
      ++ [
        ''
          if ! ${esc "${systemPath}/bin/irecovery"} -a | grep -q ${esc "^${newestDevice} "}; then
            ${fail "${entry.name}: the shipped irecovery does not list ${newestDevice}"}
          fi
          # idevicerestore resolves the device type through the libirecovery
          # it links, which can differ from the one bin/irecovery comes from.
          lib=$(ldd ${esc "${systemPath}/bin/idevicerestore"} | grep -o '/nix/store/[^ ]*/libirecovery[^ ]*\.so[^ ]*' || true)
          if [ -z "$lib" ] || ! grep -qF ${esc newestDevice} "$lib"; then
            ${fail "${entry.name}: the libirecovery idevicerestore loads does not know ${newestDevice}"}
          fi
        ''
      ]
    );
in
pkgs.runCommand "iphone-restore-tests"
  {
    nativeBuildInputs = [
      pkgs.gnugrep
      pkgs.stdenv.cc.libc.bin
    ];
  }
  ''
    set -x
    ${configurations.guard}
    failed=0

    ${lib.concatMapStringsSep "\n" assertEntry configurations.entries}

    if [ "$failed" != 0 ]; then
      exit 1
    fi
    touch $out
  ''
