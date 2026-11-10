/*
  Check interface:

    import ./tests/proton-vpn.nix { inherit pkgs self; }

  Asserts that the Proton VPN app and the split-DNS setup it needs reach every
  configuration that enables `my.protonVpn.enable` as built output, and that
  no other configuration carries them. Every assertion reads the materialised
  /etc tree
  or the system path rather than the options they derive from: enabling
  services.resolved sets networking.networkmanager.dns unconditionally, so an
  assertion on that option would fold to a constant.

  Verifies, on every configuration with the trait on (each production
  configuration re-evaluated with it forced on when no production
  configuration enables it):
  - the system path carries bin/protonvpn-app and the app's desktop entry.
  - NetworkManager.conf renders dns=systemd-resolved, and /etc/resolv.conf is
    the link to resolved's stub file.
  - sysinit.target wants a systemd-resolved.service whose ExecStart runs
    systemd-resolved. An existence test would pass for a unit NixOS masked to
    /dev/null, so the assertion reads the unit's content.
  - resolved.conf renders LLMNR=false, since resolved otherwise sends LLMNR
    queries that these hosts never sent under resolvconf.
  - resolved.conf renders Cache=no-negative, since a cached NXDOMAIN hides a
    newly created record for up to the zone's SOA minimum TTL.
  - /etc/NetworkManager/VPN carries the OpenVPN plugin's service file.

  Verifies, on every configuration with the trait off:
  - none of the items above are present. These negatives pass trivially when
    the module is missing everywhere, which is why they only run beside the
    positives above, and the helper fails the check when the positive branch
    holds no production configuration with the trait on.

  Verifies, on every configuration:
  - the firewall start script's reverse-path rule is the loose variant.
    Strict mode drops replies that arrive on an interface other than the one
    the default route names, which is what a full-tunnel VPN beside
    tailscale0 produces.

  It cannot see what the app or resolved do at runtime; confirm that on
  hardware. Every failure is collected in one build.
*/
{ pkgs, self }:
let
  inherit (pkgs) lib;
  inherit (lib) concatStringsSep concatMapStringsSep escapeShellArg;

  configurations = import ./lib/configurations.nix { inherit pkgs self; };
  protonVpn = configurations.withTrait "my.protonVpn.enable" (config: config.my.protonVpn.enable);

  esc = value: escapeShellArg (toString value);

  stubResolvConf = "/run/systemd/resolve/stub-resolv.conf";
  looseRpfilterRule = "-m rpfilter --validmark --loose -j RETURN";

  fail = message: ''
    echo ${esc message} >&2
    failed=1
  '';

  # `present` true asserts the test holds, false asserts it does not.
  expect =
    present: test: message:
    if present then
      ''
        if ! ${test}; then
          ${fail message}
        fi
      ''
    else
      ''
        if ${test}; then
          ${fail message}
        fi
      '';

  hostAssertions =
    enabled: entry:
    let
      hostName = entry.name;
      path = entry.config.system.path;
      etc = "${entry.config.system.build.etc}/etc";
      state = if enabled then "lacks" else "unexpectedly carries";
    in
    concatStringsSep "\n" [
      (expect enabled "[ -x ${esc "${path}/bin/protonvpn-app"} ]"
        "${hostName}: the system path ${state} bin/protonvpn-app"
      )
      (expect enabled "[ -f ${esc "${path}/share/applications/proton.vpn.app.gtk.desktop"} ]"
        "${hostName}: the system path ${state} the Proton VPN desktop entry"
      )
      (expect enabled "grep -Fxq dns=systemd-resolved ${esc "${etc}/NetworkManager/NetworkManager.conf"}"
        "${hostName}: NetworkManager.conf ${state} dns=systemd-resolved"
      )
      (expect enabled "[ \"$(readlink ${esc "${etc}/resolv.conf"})\" = ${esc stubResolvConf} ]"
        "${hostName}: /etc/resolv.conf ${state} the link to ${stubResolvConf}"
      )
      (expect enabled
        "grep -qs '^ExecStart=.*/lib/systemd/systemd-resolved$' ${esc "${etc}/systemd/system/sysinit.target.wants/systemd-resolved.service"}"
        "${hostName}: sysinit.target ${state} a want on a systemd-resolved.service that runs systemd-resolved"
      )
      (expect enabled "grep -Fxqs LLMNR=false ${esc "${etc}/systemd/resolved.conf"}"
        "${hostName}: resolved.conf ${state} LLMNR=false"
      )
      (expect enabled "grep -Fxqs Cache=no-negative ${esc "${etc}/systemd/resolved.conf"}"
        "${hostName}: resolved.conf ${state} Cache=no-negative"
      )
      (expect enabled "[ -e ${esc "${etc}/NetworkManager/VPN/nm-openvpn-service.name"} ]"
        "${hostName}: /etc/NetworkManager/VPN ${state} the OpenVPN plugin"
      )
      ''
        firewall_start=$(sed -n 's/^ExecStart=@\([^ ]*\) .*/\1/p' ${esc "${etc}/systemd/system/firewall.service"})
        if [ -z "$firewall_start" ] || ! grep -Fq -- ${esc looseRpfilterRule} "$firewall_start"; then
          ${fail "${hostName}: the firewall start script carries no loose reverse-path rule"}
        fi
      ''
    ];
in
pkgs.runCommand "proton-vpn-tests" { } ''
  set -x
  ${configurations.guard}
  ${protonVpn.guard}
  failed=0
  # The profile enables Proton VPN only outside bootstrap. The split above
  # follows the trait, so a default widened to bootstrap would only move those
  # outputs to the positive side; pin the clause here.
  ${lib.concatMapStrings (
    entry:
    lib.optionalString entry.config.my.protonVpn.enable (
      fail "${entry.name}: a bootstrap output enables my.protonVpn.enable"
    )
  ) configurations.bootstraps}

  ${concatMapStringsSep "\n" (hostAssertions true) protonVpn.enabled}
  ${concatMapStringsSep "\n" (hostAssertions false) protonVpn.disabled}

  if [ "$failed" != 0 ]; then
    exit 1
  fi
  touch $out
''
