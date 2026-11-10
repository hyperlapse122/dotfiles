/*
  Check interface:

    import ./tests/podman-containers.nix { inherit pkgs self; }

  Asserts that rootless Podman, disabled rootful socket, helper package,
  environment variables, registries search drop-in, and auth.json activation logic
  materialize correctly on every configuration `tests/lib/configurations.nix`
  yields, production and bootstrap alike.

  On every configuration with `my.podman.enable`, the materialized
  /etc/systemd/user tree carries the weekly podman-prune timer and its oneshot
  service, which runs the wrapped Podman's `system prune --force` with a filter
  that skips minikube's labelled objects, only in the configured account's
  user manager. With the trait off, neither unit exists.

  The builder collects every failure before it exits, so one red build names
  every affected configuration.
*/
{ pkgs, self }:
let
  inherit (pkgs) lib;

  authEffects = ./lib/containers-auth-effects.py;

  configurations = import ./lib/configurations.nix { inherit pkgs self; };
  podman = configurations.withTrait "my.podman.enable" (config: config.my.podman.enable);

  esc = value: lib.escapeShellArg (toString value);

  fail = message: ''
    echo ${esc message} >&2
    failed=1
  '';

  # A disabled or retargeted /etc entry is not materialised at its path.
  userUnits =
    config:
    let
      entry = config.environment.etc."systemd/user" or null;
    in
    if
      entry == null || !(entry.enable or true) || (entry.target or "systemd/user") != "systemd/user"
    then
      null
    else
      entry.source;

  assertPruneEnabled =
    entry:
    let
      inherit (entry) config name;
      tree = userUnits config;
      podmanBin = "${config.virtualisation.podman.package}/bin/podman";
    in
    if tree == null then
      fail "${name}: the built system declares no /etc/systemd/user tree"
    else
      ''
        service=${esc "${tree}/podman-prune.service"}
        timer=${esc "${tree}/podman-prune.timer"}
        if ! grep -qx 'Type=oneshot' "$service"; then
          ${fail "${name}: podman-prune.service is missing, masked, or not a oneshot"}
        fi
        if ! grep -qx ${esc "ConditionUser=${config.my.user.name}"} "$service"; then
          ${fail "${name}: podman-prune.service does not run only in ${config.my.user.name}'s user manager"}
        fi
        if ! grep -qx ${esc "ExecStart=${podmanBin} system prune --force --filter label!=created_by.minikube.sigs.k8s.io"} "$service"; then
          ${fail "${name}: podman-prune.service does not run exactly the wrapped Podman's system prune --force skipping minikube's labelled objects"}
        fi
        if [ ! -x ${esc podmanBin} ] || ! grep -q '/run/wrappers' ${esc podmanBin}; then
          ${fail "${name}: the prune's Podman is not executable or its PATH lacks the /run/wrappers setuid helpers"}
        fi
        # stdenv sets nullglob, so `ls` on an unmatched glob lists the build
        # directory and succeeds; test each match instead.
        for wanted in ${esc tree}/*.wants/podman-prune.service; do
          if [ -e "$wanted" ]; then
            ${fail "${name}: a unit wants podman-prune.service, so it runs outside its timer"}
          fi
        done
        ${lib.concatMapStrings
          (line: ''
            if ! grep -qx ${esc line} "$timer"; then
              ${fail "${name}: podman-prune.timer is missing, masked, or lacks ${line}"}
            fi
          '')
          [
            "OnCalendar=weekly"
            "Persistent=true"
            "RandomizedDelaySec=1h"
          ]
        }
        if [ ! -e ${esc "${tree}/timers.target.wants/podman-prune.timer"} ]; then
          ${fail "${name}: timers.target does not want podman-prune.timer"}
        fi
      '';

  assertPruneDisabled =
    entry:
    let
      inherit (entry) config name;
      tree = userUnits config;
    in
    lib.optionalString (tree != null) ''
      if [ -e ${esc "${tree}/podman-prune.service"} ] || [ -e ${esc "${tree}/podman-prune.timer"} ]; then
        ${fail "${name}: my.podman.enable is off but a podman-prune user unit exists"}
      fi
    '';

  checkHost =
    entry:
    let
      hostName = entry.name;
      packages = entry.config.environment.systemPackages or [ ];
      podmanPkg = pkgs.lib.lists.findFirst (p: (p.pname or "") == "podman") null packages;
      dockerCompatPkg = pkgs.lib.lists.findFirst (
        p: pkgs.lib.strings.hasPrefix "podman-docker-compat" p.name
      ) null packages;
      helperPkg = pkgs.lib.lists.findFirst (p: (p.pname or "") == "docker-credential-sops") null packages;

      absentPodman = pkgs.lib.optionalString (podmanPkg == null) ''
        echo "missing podman in environment.systemPackages on ${hostName}" >&2
        failed=1
      '';
      presentPodman = pkgs.lib.optionalString (podmanPkg != null) ''
        if [ ! -x ${podmanPkg}/bin/podman ]; then
          echo "podman package ships no bin/podman executable on ${hostName}" >&2
          failed=1
        fi
      '';

      absentDockerCompat = pkgs.lib.optionalString (dockerCompatPkg == null) ''
        echo "missing podman-docker-compat in environment.systemPackages on ${hostName}" >&2
        failed=1
      '';
      presentDockerCompat = pkgs.lib.optionalString (dockerCompatPkg != null) ''
        if [ ! -x ${dockerCompatPkg}/bin/docker ]; then
          echo "podman-docker-compat package ships no bin/docker compat shim on ${hostName}" >&2
          failed=1
        fi
      '';

      absentHelper = pkgs.lib.optionalString (helperPkg == null) ''
        echo "missing docker-credential-sops in environment.systemPackages on ${hostName}" >&2
        failed=1
      '';
      presentHelper = pkgs.lib.optionalString (helperPkg != null) ''
        if [ ! -x ${helperPkg}/bin/docker-credential-sops ]; then
          echo "docker-credential-sops package ships no bin/docker-credential-sops executable on ${hostName}" >&2
          failed=1
        fi
      '';

      rootfulWantedBy = entry.config.systemd.sockets.podman.wantedBy or null;

      hm = entry.user;
      sessionAuth = hm.home.sessionVariables.REGISTRY_AUTH_FILE or "";
      sessionDocker = hm.home.sessionVariables.DOCKER_HOST or "";
      userSessionAuth = hm.systemd.user.sessionVariables.REGISTRY_AUTH_FILE or "";
      userSessionDocker = hm.systemd.user.sessionVariables.DOCKER_HOST or "";

      activationScript = hm.home.activation.containersAuth.data or "";
      authBlock = pkgs.writeText "containers-auth-block.sh" activationScript;
      registryFile =
        if hm ? home-files then
          "${hm.home-files}/.config/containers/registries.conf.d/10-unqualified-search.conf"
        else
          "";
    in
    ''
      # 1. Verify systemPackages contains podman, podman-docker-compat, and docker-credential-sops
      ${absentPodman}
      ${presentPodman}
      ${absentDockerCompat}
      ${presentDockerCompat}
      ${absentHelper}
      ${presentHelper}

      # 2. Verify rootful podman socket wantedBy is empty
      if [ "${builtins.toJSON rootfulWantedBy}" != "[]" ]; then
        echo "systemd.sockets.podman.wantedBy is not empty on ${hostName}: '${builtins.toJSON rootfulWantedBy}'" >&2
        failed=1
      fi

      # 3. Verify REGISTRY_AUTH_FILE and DOCKER_HOST session variables
      if [ '${sessionAuth}' != "/home/h82/.config/containers/auth.json" ]; then
        echo "home.sessionVariables.REGISTRY_AUTH_FILE is incorrect on ${hostName}: '${sessionAuth}'" >&2
        failed=1
      fi
      if [ '${sessionDocker}' != "unix://\''${XDG_RUNTIME_DIR}/podman/podman.sock" ]; then
        echo "home.sessionVariables.DOCKER_HOST is incorrect on ${hostName}: '${sessionDocker}'" >&2
        failed=1
      fi
      if [ '${userSessionAuth}' != "/home/h82/.config/containers/auth.json" ]; then
        echo "systemd.user.sessionVariables.REGISTRY_AUTH_FILE is incorrect on ${hostName}: '${userSessionAuth}'" >&2
        failed=1
      fi
      if [ '${userSessionDocker}' != "unix://\''${XDG_RUNTIME_DIR}/podman/podman.sock" ]; then
        echo "systemd.user.sessionVariables.DOCKER_HOST is incorrect on ${hostName}: '${userSessionDocker}'" >&2
        failed=1
      fi

      if ! python3 ${authEffects} ${authBlock}; then
        echo "containersAuth effect contract failed on ${hostName}" >&2
        failed=1
      fi
      if ! python3 - ${esc registryFile} <<'PYREGISTRY'
      import sys, tomllib
      from pathlib import Path
      path = Path(sys.argv[1])
      assert path.is_file(), "missing materialized registry search drop-in"
      assert tomllib.loads(path.read_text()).get("unqualified-search-registries") == ["docker.io"], "incorrect materialized registry search policy"
      PYREGISTRY
      then
        echo "registry consumer configuration failed on ${hostName}" >&2
        failed=1
      fi
    '';
in
pkgs.runCommand "podman-containers-tests"
  {
    nativeBuildInputs = [
      pkgs.python3
      pkgs.gnugrep
    ];
  }
  ''
    set -x
    ${configurations.guard}
    ${podman.guard}
    failed=0

    ${pkgs.lib.concatMapStringsSep "\n" checkHost configurations.entries}
    ${lib.concatMapStringsSep "\n" assertPruneEnabled podman.enabled}
    ${lib.concatMapStringsSep "\n" assertPruneDisabled podman.disabled}

    if [ "$failed" != 0 ]; then
      exit 1
    fi
    touch $out
  ''
