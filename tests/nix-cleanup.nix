/*
  Check interface:

    import ./tests/nix-cleanup.nix { inherit pkgs self; }

  Asserts that weekly Nix generation cleanup reaches every production
  configuration `tests/lib/configurations.nix` yields as built output, and
  reaches no bootstrap configuration at all. The expectation is taken from each
  configuration's `my.bootstrap`, never from the programs.nh options the module
  under test sets.

  Every assertion below reads something activation produces -- the rendered
  service and timer units, the materialised /etc/systemd/system tree, the system
  path -- rather than the programs.nh options they are derived from.  An option
  can evaluate correctly while a mkIf keeps the unit out of the built system, and
  a rendered unit exists even when nothing is wired to start it.

  Verifies, on every production configuration:
  - the nh-clean service unit exists, and the script its ExecStart names runs
    `nh clean all` with a retention count, a retention window, and --keep-one,
    without disabling store collection (--no-gc) or gcroot cleanup
    (--no-gcroots).
  - the nh-clean timer carries OnCalendar=weekly and Persistent=true, so a run
    missed while the machine was off is caught up at the next boot.
  - the materialised system unit tree wires that timer into timers.target.wants.
    Without this the two assertions above pass on a timer nothing ever starts.
  - the boot loader's configurationLimit is a number at all.  Both loader options
    are nullOr int and null is their default, meaning an unbounded menu that no
    finite retention count can cover.
  - the retention count is at or above the boot loader's configurationLimit.  The
    boot menu is rewritten only by a rebuild while collection runs on a timer, so
    a smaller count would leave menu entries naming collected generations.  The
    count is read out of the built start script rather than out of extraArgs, so
    the operand is the text the machine will actually run.
  - the system path ships bin/nh.  The nh module gates its package on
    programs.nh.enable and its units on clean.enable, so dropping the former
    leaves every assertion above untouched; this is the only one that sees it.
  - the system schedules no second collector.  nix-gc.service is materialised
    whenever Nix is enabled, so the signal is the absence of nix-gc.timer, not
    of the service.

  Verifies, on every bootstrap configuration:
  - the system renders neither unit and ships no bin/nh.

  The helper fails the check when it yields no configuration or no bootstrap
  output. The builder collects every failure instead of exiting at the first, so
  one red build names every broken assertion across every configuration.  That
  matters for the mutation rounds this repository requires: exiting early
  leaves the remaining assertions unobserved, and a round that produces no
  evidence for an assertion proves nothing about it.
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

  bootLimit = cfg: cfg.boot.loader.systemd-boot.configurationLimit;

  # Store-path interpolations stay inside optionalString guards so that removing
  # what they name fails inside the builder with the message below, rather than
  # aborting evaluation with a null coercion error.
  assertProduction =
    entry:
    let
      inherit (entry) config name;
      fail' = message: fail "${name}: ${message}";

      serviceUnit = config.systemd.units."nh-clean.service".unit or null;
      timerUnit = config.systemd.units."nh-clean.timer".unit or null;
      systemUnits = config.environment.etc."systemd/system".source or null;

      # Bound once so the comparison operand and the message it prints cannot
      # drift apart when one of them is edited.
      limitValue = bootLimit config;
      limit = esc limitValue;

      # Both configurationLimit options are nullOr int, and null is their
      # default and their documented "no limit, every surviving generation"
      # value.  It has to fail here rather than reach the shell: toString null
      # is the empty string, so the comparison below would become
      # [ "$keep" -lt '' ], which errors to stderr, leaves the branch untaken,
      # and passes the whole check in exactly the case the retention floor
      # exists to catch.
      limitUnbounded = lib.optionalString (limitValue == null) (
        fail' "the boot loader configurationLimit is null, so the boot menu offers every surviving generation and no finite retention count can cover it"
      );
    in
    ''
      ${limitUnbounded}

      ${lib.optionalString (serviceUnit == null) (
        fail' "the production system renders no nh-clean.service unit"
      )}
      ${lib.optionalString (serviceUnit != null) ''
        unit=${serviceUnit}/nh-clean.service
        if [ ! -f "$unit" ]; then
          ${fail' "the rendered nh-clean.service directory carries no unit file"}
        else
          start=$(grep -m1 '^ExecStart=' "$unit" | cut -d= -f2- | sed 's/[[:space:]]*$//')
          if [ -z "$start" ] || [ ! -f "$start" ]; then
            ${fail' "nh-clean.service names no readable ExecStart script"}
          else
            if ! grep -q 'clean all' "$start"; then
              ${fail' "the nh-clean start script does not run 'nh clean all'"}
            fi
            if ! grep -q -- '--keep-since 14d' "$start"; then
              ${fail' "the nh-clean start script does not keep generations from the last 14 days"}
            fi
            if ! grep -q -- '--keep-one' "$start"; then
              ${fail' "the nh-clean start script does not pass --keep-one to preserve direnv project gcroots"}
            fi
            if grep -w -q -- '--no-gc' "$start"; then
              ${fail' "the nh-clean start script disables store garbage collection with --no-gc"}
            fi
            if grep -q -- '--no-gcroots' "$start"; then
              ${fail' "the nh-clean start script disables gcroot cleanup with --no-gcroots"}
            fi
            keep=$(grep -o -- '--keep [0-9][0-9]*' "$start" | head -1 | awk '{ print $2 }')
            if [ -z "$keep" ]; then
              ${fail' "the nh-clean start script names no retention count"}
            fi
            ${lib.optionalString (limitValue != null) ''
              if [ -n "$keep" ] && [ "$keep" -lt ${limit} ]; then
                echo "${name}: retention count $keep is below the boot loader configurationLimit ${limit}; the boot menu would offer entries whose generations were collected" >&2
                failed=1
              fi
            ''}
          fi
        fi
      ''}

      ${lib.optionalString (timerUnit == null) (
        fail' "the production system renders no nh-clean.timer unit"
      )}
      ${lib.optionalString (timerUnit != null) ''
        timer=${timerUnit}/nh-clean.timer
        if [ ! -f "$timer" ]; then
          ${fail' "the rendered nh-clean.timer directory carries no unit file"}
        else
          if ! grep -Fxq 'OnCalendar=weekly' "$timer"; then
            ${fail' "nh-clean.timer does not run weekly"}
          fi
          if ! grep -Fxq 'Persistent=true' "$timer"; then
            ${fail' "nh-clean.timer is not persistent, so a run missed while the machine was off is never caught up"}
          fi
        fi
      ''}

      ${lib.optionalString (systemUnits == null) (
        fail' "the production system materialises no /etc/systemd/system tree"
      )}
      ${lib.optionalString (systemUnits != null) ''
        if [ ! -e ${systemUnits}/timers.target.wants/nh-clean.timer ]; then
          ${fail' "nh-clean.timer is rendered but not wired into timers.target.wants, so nothing starts it"}
        fi
        if [ -e ${systemUnits}/timers.target.wants/nix-gc.timer ]; then
          ${fail' "the production system schedules nix-gc alongside nh-clean, so two collectors run"}
        fi
      ''}

      if [ ! -x ${config.system.path}/bin/nh ]; then
        ${fail' "the production system path ships no bin/nh, so the cleanup cannot be run or previewed by hand"}
      fi
    '';

  assertBootstrap =
    entry:
    let
      inherit (entry) config name;
      systemUnits = config.environment.etc."systemd/system".source or null;
    in
    ''
      ${lib.optionalString (systemUnits == null) (
        fail "${name}: the bootstrap system materialises no /etc/systemd/system tree, so its unit assertions read nothing"
      )}
      ${lib.optionalString (systemUnits != null) ''
        for leaked in nh-clean.service nh-clean.timer; do
          if [ -e ${systemUnits}/"$leaked" ]; then
            echo "${name}: the bootstrap system renders $leaked" >&2
            failed=1
          fi
        done
      ''}
      if [ -e ${config.system.path}/bin/nh ]; then
        ${fail "${name}: the bootstrap system path ships bin/nh"}
      fi
    '';
in
pkgs.runCommand "nix-cleanup-tests"
  {
    nativeBuildInputs = [
      pkgs.gnugrep
      pkgs.gnused
      pkgs.gawk
      pkgs.coreutils
    ];
  }
  ''
    set -x
    ${configurations.guard}
    failed=0

    ${lib.optionalString (configurations.production == [ ]) (
      fail "tests/lib/configurations.nix yields no production configuration, so the cleanup assertions would cover nothing"
    )}
    ${lib.concatMapStringsSep "\n" assertProduction configurations.production}
    ${lib.concatMapStringsSep "\n" assertBootstrap configurations.bootstraps}

    if [ "$failed" != 0 ]; then
      exit 1
    fi
    touch $out
  ''
