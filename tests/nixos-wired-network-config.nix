/*
  Check interface:

    import ./tests/nixos-wired-network-config.nix { inherit pkgs self; }

  Asserts that the wired network trait reaches NixOS configurations as the
  materialised systemd unit that renders the static NetworkManager profile,
  reading the unit files in each configuration's /etc tree rather than the
  options they derive from.

  Verifies, on every production configuration with my.wiredNetwork.enable:
  - etc/systemd/system/nixos-wired-network.service orders itself before
    NetworkManager.service, so the profile exists when NetworkManager first
    reads its connection directories.
  - its ExecStart runs the packaged nixos-wired-network with an encrypted
    wired-network.yaml from the store and writes into NetworkManager's
    runtime connection directory.
  - its PATH holds nmcli, which the tool needs to reload NetworkManager on a
    switch.
  - NetworkManager.service wants it, so a NetworkManager start pulls it in.

  Verifies, on every bootstrap configuration and on every production
  configuration with the trait off (forced off when no production
  configuration leaves it off):
  - no nixos-wired-network.service unit exists. The bootstrap outputs enable
    the trait through the host file, so the module's bootstrap gate is what
    keeps them on DHCP.

  Verifies by evaluation:
  - the trait defaults to off, so a host that does not set it gets no unit.
  - a production configuration with the trait on and no encrypted file fails
    with the assertion that names the missing file.

  The positive branch fails when no production configuration enables the
  trait. It cannot see whether NetworkManager applies the profile; the
  wired-network-provisioning VM check proves that. Every failure is collected
  in one build.
*/
{ pkgs, self }:
let
  inherit (pkgs) lib;
  inherit (lib) concatMapStringsSep escapeShellArg;

  configurations = import ./lib/configurations.nix { inherit pkgs self; };

  unitName = "nixos-wired-network.service";
  missingFileMessage = "my.wiredNetwork.enable needs secrets/hosts/";

  esc = value: escapeShellArg (toString value);

  fail = message: ''
    echo ${esc message} >&2
    failed=1
  '';

  enabled = builtins.filter (entry: entry.config.my.wiredNetwork.enable) configurations.production;
  disabledProduction = builtins.filter (
    entry: !entry.config.my.wiredNetwork.enable
  ) configurations.production;
  disabled =
    if disabledProduction != [ ] then
      disabledProduction
    else
      map (configurations.withTraitForcedOff "my.wiredNetwork.enable") configurations.production;

  systemUnits = entry: "${entry.config.system.build.etc}/etc/systemd/system";

  present =
    entry:
    let
      units = systemUnits entry;
      unit = "${units}/${unitName}";
    in
    ''
      if ! grep -Fxq Before=NetworkManager.service ${esc unit}; then
        ${fail "${entry.name}: ${unitName} is missing or does not order itself before NetworkManager.service"}
      fi
      exec_start=$(sed -n 's/^ExecStart=//p' ${esc unit})
      if ! grep -Eq '^/nix/store/[^ ]+/bin/nixos-wired-network --file /nix/store/[^ ]+-wired-network\.yaml ' <<<"$exec_start"; then
        ${fail "${entry.name}: ${unitName} does not run nixos-wired-network on an encrypted wired-network.yaml"}
      fi
      if ! grep -Fq -- '--output-dir /run/NetworkManager/system-connections' <<<"$exec_start"; then
        ${fail "${entry.name}: ${unitName} does not write into /run/NetworkManager/system-connections"}
      fi
      # The tool reloads NetworkManager through nmcli on a switch, and skips the
      # reload when nmcli is not on its PATH.
      unit_path=$(sed -n 's/^Environment="PATH=\(.*\)"$/\1/p' ${esc unit})
      has_nmcli=0
      IFS=: read -ra path_dirs <<<"$unit_path"
      for dir in "''${path_dirs[@]}"; do
        if [ -x "$dir/nmcli" ]; then
          has_nmcli=1
        fi
      done
      if [ "$has_nmcli" != 1 ]; then
        ${fail "${entry.name}: ${unitName} has no nmcli on its PATH"}
      fi
      if [ ! -e ${esc "${units}/NetworkManager.service.wants/${unitName}"} ]; then
        ${fail "${entry.name}: NetworkManager.service does not want ${unitName}"}
      fi
    '';

  absent = entry: ''
    if [ -e ${esc "${systemUnits entry}/${unitName}"} ]; then
      ${fail "${entry.name}: ${unitName} exists although the output must stay on DHCP"}
    fi
  '';

  # Evaluation-only facts, rendered as failures inside the builder.
  defaultOff = lib.all (
    entry: !self.nixosConfigurations.${entry.name}.options.my.wiredNetwork.enable.default
  ) configurations.entries;

  withoutFile =
    entry:
    self.nixosConfigurations.${entry.name}.extendModules {
      modules = [
        {
          my.wiredNetwork.enable = lib.mkForce true;
          my.wiredNetwork.file = lib.mkForce null;
        }
      ];
    };
  missingFileAsserted =
    entry:
    lib.any (
      assertion: !assertion.assertion && lib.hasInfix missingFileMessage assertion.message
    ) (withoutFile entry).config.assertions;
in
pkgs.runCommand "nixos-wired-network-config-tests" { } ''
  set -x
  ${configurations.guard}
  failed=0

  ${lib.optionalString (enabled == [ ]) (
    fail "no production configuration enables my.wiredNetwork.enable"
  )}
  ${lib.optionalString (!defaultOff) (fail "my.wiredNetwork.enable no longer defaults to off")}
  ${concatMapStringsSep "\n" (
    entry:
    lib.optionalString (!missingFileAsserted entry) (
      fail "${entry.name}: the trait without an encrypted file does not fail the missing-file assertion"
    )
  ) configurations.production}

  ${concatMapStringsSep "\n" present enabled}
  ${concatMapStringsSep "\n" absent (configurations.bootstraps ++ disabled)}

  if [ "$failed" != 0 ]; then
    exit 1
  fi
  touch $out
''
