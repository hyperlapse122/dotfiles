/*
  Check interface:

    import ./tests/bootstrap-secrets.nix { inherit pkgs self; }

  Asserts that a bootstrap output decrypts no sops secret at all, so
  installing one before the host's age identity exists logs no
  sops-install-secrets error, and that the production outputs still hand sops
  their Wi-Fi credentials, so the bootstrap gate cannot widen into production.
  This check is the only owner of the bootstrap side: the checks for
  individual secrets assert production outputs only.

  It reads what activation runs -- the sops-install-secrets unit and the
  setupSecrets activation script, and the manifests they hand the installer
  -- never the sops options the modules set.

  Verifies:
  - every bootstrap configuration hands sops no manifest from either place.
  - at least one production configuration's manifests carry a
    wifi/<label>/psk secret.

  The helper's guard runs first, so an empty configuration list, or one with
  no bootstrap output, fails the build instead of passing it. The builder
  collects every failure, so one red build names every affected configuration.
*/
{ pkgs, self }:
let
  inherit (pkgs) lib;

  configurations = import ./lib/configurations.nix { inherit pkgs self; };

  esc = value: lib.escapeShellArg (toString value);

  # sops-nix installs through a systemd unit when my.cliAuth is enabled and
  # through the setupSecrets activation script otherwise, so both places are
  # searched for the manifests they hand the installer.
  installersOf =
    entry:
    let
      sopsService = entry.config.systemd.services.sops-install-secrets or { };
    in
    lib.concatStringsSep " " (
      lib.toList (sopsService.serviceConfig.ExecStart or [ ])
      ++ [ (entry.config.system.activationScripts.setupSecrets.text or "") ]
    );

  manifestsOf = entry: ''
    manifests=$(printf '%s' ${esc (installersOf entry)} | grep -oE '/nix/store/[^[:space:]]+-manifest\.json' || true)
  '';

  assertBootstrap = entry: ''
    ${manifestsOf entry}
    if [ -n "$manifests" ]; then
      fail ${esc entry.name}": a bootstrap output must decrypt no sops secret, but sops is handed: $manifests"
    fi
  '';

  wifiSecretsOf = entry: ''
    ${manifestsOf entry}
    if [ -n "$manifests" ]; then
      python3 - $manifests <<'PY'
    import json, re, sys
    for path in sys.argv[1:]:
        for secret in json.load(open(path)).get("secrets", []):
            if re.fullmatch(r"wifi/[^/]+/psk", secret.get("name", "")):
                print(secret["name"])
    PY
    fi
  '';
in
pkgs.runCommand "bootstrap-secrets-tests" { nativeBuildInputs = [ pkgs.python3 ]; } ''
  ${configurations.guard}
  failed=0
  fail() { echo "$1" >&2; failed=1; }
  ${lib.concatMapStringsSep "\n" assertBootstrap configurations.bootstraps}
  productionWifi=0
  ${lib.concatMapStringsSep "\n" (entry: ''
    if [ -n "$(${wifiSecretsOf entry})" ]; then
      productionWifi=1
    fi
  '') configurations.production}
  if [ "$productionWifi" != 1 ]; then
    fail "no production configuration hands sops a wifi/<label>/psk secret"
  fi
  if [ "$failed" != 0 ]; then exit 1; fi
  touch $out
''
