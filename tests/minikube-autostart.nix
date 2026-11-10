/*
  Check interface:

    import ./tests/minikube-autostart.nix { inherit pkgs self fixtures; }

  Asserts that every NixOS configuration with `my.minikube.enable` starts a
  rootless minikube cluster from h82's user manager, and that nothing else
  does:

  - The materialized /etc/systemd/user tree carries minikube.service as a
    Type=exec unit that stays active after a successful start, runs only in
    the configured account's manager, starts and stops minikube, carries the
    MINIKUBE_* settings and the wrapped Podman on its PATH, and is wanted by
    default.target. Type=exec keeps a slow first start from holding login.
  - The materialized user@.service drop-in delegates the cpuset and io
    controllers the rootless node needs.
  - The login environment (set-environment and pam/environment) carries the
    same MINIKUBE_* settings, so a hand-run `minikube start` matches the unit.

  With the trait off, on every bootstrap output, and on a production output
  re-evaluated with `my.podman.enable` forced off, none of the unit, its
  wants link, the cpuset delegation, or the MINIKUBE_* settings exist. The
  user@ drop-in exists on every NixOS output (nixpkgs writes
  X-RestartIfChanged there), so the check reads its Delegate line, not the
  file. No non-NixOS fixture's Home Manager or system-manager output carries
  a minikube unit.

  A disabled or retargeted /etc entry is read as absent, and every lookup
  carries an `or` fallback, so a mutation fails in the builder rather than
  during evaluation. The builder collects every failure before it exits.
*/
{
  pkgs,
  self,
  fixtures,
}:
let
  inherit (pkgs) lib;

  configurations = import ./lib/configurations.nix { inherit pkgs self fixtures; };
  # Each output is judged by its own trait, so a host may opt out. Every
  # bootstrap output is asserted off on its own, so a default that drops its
  # bootstrap clause fails even though the trait split would then call those
  # outputs enabled.
  minikube = configurations.withTrait "my.minikube.enable" (config: config.my.minikube.enable);

  # One production output re-evaluated with an option forced off: forcing the
  # trait off covers a production output on the negative side, and forcing
  # Podman off proves the profile default follows the Podman trait. Both rules
  # live in the shared profile, so one host proves each.
  forcedOff =
    option: map (configurations.withTraitForcedOff option) (lib.take 1 configurations.production);

  linuxUsers = lib.filter (entry: entry.kind == "linux") configurations.userEntries;

  expectedVariables = {
    MINIKUBE_PROFILE = "minikube";
    MINIKUBE_DRIVER = "podman";
    MINIKUBE_CONTAINER_RUNTIME = "containerd";
    MINIKUBE_ROOTLESS = "true";
  };

  esc = value: lib.escapeShellArg (toString value);

  fail = message: ''
    echo ${esc message} >&2
    failed=1
  '';

  # A disabled or retargeted /etc entry is not materialised at its path.
  etcSource =
    config: path:
    let
      entry = config.environment.etc.${path} or null;
    in
    if entry == null || !(entry.enable or true) || (entry.target or path) != path then
      ""
    else
      entry.source;

  etcTrees = config: {
    userUnits = etcSource config "systemd/user";
    systemUnits = etcSource config "systemd/system";
    setEnvironment = etcSource config "set-environment";
    pamEnvironment = etcSource config "pam/environment";
  };

  assertEnabled =
    entry:
    let
      inherit (entry) config name;
      inherit (etcTrees config)
        userUnits
        systemUnits
        setEnvironment
        pamEnvironment
        ;
      podmanBin = "${config.virtualisation.podman.package or "missing-podman"}/bin";
      user = config.my.user.name;
    in
    ''
      service=${esc "${userUnits}/minikube.service"}
      ${lib.concatMapStrings
        (line: ''
          if ! grep -qx ${esc line} "$service"; then
            ${fail "${name}: minikube.service is missing, masked, or lacks ${line}"}
          fi
        '')
        [
          "Type=exec"
          "RemainAfterExit=true"
          "ConditionUser=${user}"
        ]
      }
      if ! grep -qx 'ExecStart=/nix/store/[^ ]*-minikube-[^ ]*/bin/minikube start' "$service"; then
        ${fail "${name}: minikube.service does not run minikube start"}
      fi
      if ! grep -qx 'ExecStop=/nix/store/[^ ]*-minikube-[^ ]*/bin/minikube stop' "$service"; then
        ${fail "${name}: minikube.service does not stop minikube"}
      fi
      if ! grep -q ${esc "^Environment=\"PATH=${podmanBin}:"} "$service"; then
        ${fail "${name}: minikube.service's PATH does not start with the wrapped Podman"}
      fi
      ${lib.concatStrings (
        lib.mapAttrsToList (variable: value: ''
          if ! grep -qx ${esc "Environment=\"${variable}=${value}\""} "$service"; then
            ${fail "${name}: minikube.service lacks ${variable}=${value}"}
          fi
          if ! grep -qx ${esc "export ${variable}=\"${value}\""} ${esc setEnvironment}; then
            ${fail "${name}: set-environment lacks ${variable}=${value}"}
          fi
          if ! grep -Eqx ${esc "${variable}[[:space:]]+DEFAULT=\"${value}\""} ${esc pamEnvironment}; then
            ${fail "${name}: pam/environment lacks ${variable}=${value}"}
          fi
        '') expectedVariables
      )}
      wanted=${esc "${userUnits}/default.target.wants/minikube.service"}
      if [ "$(readlink "$wanted")" != ../minikube.service ]; then
        ${fail "${name}: default.target does not want minikube.service"}
      fi
      if ! grep -qx 'Delegate=cpu cpuset io memory pids' ${esc "${systemUnits}/user@.service.d/overrides.conf"}; then
        ${fail "${name}: user@.service does not delegate the cpuset and io controllers"}
      fi
    '';

  assertDisabled =
    entry:
    let
      inherit (entry) config name;
      inherit (etcTrees config)
        userUnits
        systemUnits
        setEnvironment
        pamEnvironment
        ;
    in
    ''
      if [ -e ${esc "${userUnits}/minikube.service"} ] || [ -L ${esc "${userUnits}/default.target.wants/minikube.service"} ]; then
        ${fail "${name}: minikube is off but a minikube user unit exists"}
      fi
      if grep -q '^Delegate=.*cpuset' ${esc "${systemUnits}/user@.service.d/overrides.conf"} 2>/dev/null; then
        ${fail "${name}: minikube is off but user@.service delegates cpuset"}
      fi
      if grep -qs MINIKUBE_ ${esc setEnvironment} ${esc pamEnvironment}; then
        ${fail "${name}: minikube is off but the login environment carries MINIKUBE_ settings"}
      fi
    '';

  assertLinuxUser = entry: ''
    if [ ! -d ${esc "${entry.user.home-files or ""}"} ]; then
      ${fail "${entry.name}: the non-NixOS fixture has no Home Manager home-files"}
    elif [ -n "$(find ${esc "${entry.user.home-files or ""}/.config/systemd/user"} -name 'minikube*' 2>/dev/null)" ]; then
      ${fail "${entry.name}: a non-NixOS Home Manager output carries a minikube user unit"}
    fi
  '';

  assertLinuxSystem = entry: ''
    if grep -q minikube ${esc "${entry.host.systemManager}/services/services.json"}; then
      ${fail "${entry.name}: a non-NixOS system-manager output carries a minikube unit"}
    fi
  '';
in
pkgs.runCommand "minikube-autostart-tests" { } ''
  ${configurations.guard}
  ${minikube.guard}
  ${configurations.userGuard}
  failed=0

  ${lib.concatMapStringsSep "\n" assertEnabled minikube.enabled}
  ${lib.concatMapStringsSep "\n" assertDisabled (
    lib.filter (entry: !entry.bootstrap) minikube.disabled
    ++ configurations.bootstraps
    ++ forcedOff "my.minikube.enable"
    ++ forcedOff "my.podman.enable"
  )}
  ${lib.concatMapStringsSep "\n" assertLinuxUser linuxUsers}
  ${lib.concatMapStringsSep "\n" assertLinuxSystem configurations.linuxFixtures}

  if [ "$failed" != 0 ]; then
    exit 1
  fi
  touch $out
''
