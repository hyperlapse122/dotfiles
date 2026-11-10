# Shared API key provisioning, retained from the retired Pi settings check.
{
  pkgs,
  self,
}:
let
  inherit (pkgs) lib;
  configurations = import ./lib/configurations.nix { inherit pkgs self; };
  esc = value: lib.escapeShellArg (toString value);
  # The API keys a production configuration decrypts, each with the option
  # that gates it.
  apiKeySecrets = [
    {
      label = "Synthetic";
      match = "synthetic";
      file = "synthetic_api_key";
      option = "my.cliAuth.enableSyntheticApiKey";
    }
    {
      label = "Exa";
      match = "exa_api";
      file = "exa_api_key";
      option = "my.cliAuth.enableExaApiKey";
    }
    {
      label = "OpenRouter";
      match = "openrouter";
      file = "openrouter_api_key";
      option = "my.cliAuth.enableOpenRouterApiKey";
    }
  ];

  # One production configuration re-evaluated with each key option forced
  # off, so the check proves the option, not only the bootstrap split, gates
  # that secret and leaves the other.
  keyForcedOff = lib.concatMap (
    secret:
    map (
      entry:
      configurations.withTraitForcedOff secret.option entry
      // {
        forcedOff = secret.option;
      }
    ) (lib.take 1 configurations.production)
  ) apiKeySecrets;

  assertApiKeys =
    entry:
    let
      forcedOff = entry.forcedOff or null;
      host' = esc entry.name;

      # sops-nix installs through a systemd unit when my.cliAuth is enabled
      # and through the setupSecrets activation script otherwise, so both
      # places are searched for the manifests they hand the installer.
      sopsService = entry.config.systemd.services.sops-install-secrets or { };
      installers = lib.concatStringsSep " " (
        lib.toList (sopsService.serviceConfig.ExecStart or [ ])
        ++ [ (entry.config.system.activationScripts.setupSecrets.text or "") ]
      );
      publisher = lib.concatStringsSep " " (lib.toList (sopsService.serviceConfig.ExecStartPost or [ ]));
    in
    ''
      manifests=$(printf '%s' ${esc installers} | grep -oE '/nix/store/[^[:space:]]+-manifest\.json' || true)
      if [ -z "$manifests" ]; then
        fail ${host'}": found no sops manifest"
      fi
      publisher=$(printf '%s' ${esc publisher} | grep -oE '/nix/store/[^[:space:]]+/bin/publish-cli-auth' | head -1 || true)
      ${lib.concatMapStringsSep "\n" (
        secret:
        let
          decrypts = !entry.bootstrap && forcedOff != secret.option;
        in
        ''
          secrets=$(python3 - ${secret.match} $manifests <<'PY'
          import json, sys
          match = sys.argv[1]
          for path in sys.argv[2:]:
              for found in json.load(open(path)).get("secrets", []):
                  if match in found.get("name", "") or match in found.get("key", ""):
                      print(found.get("name"), found.get("key"), found.get("owner"), found.get("mode"))
          PY
          )
          ${
            if decrypts then
              ''
                if [ "$secrets" != "cli-auth/${secret.file} ${secret.file} h82 0400" ]; then
                  fail ${host'}": expected cli-auth/${secret.file} owned by h82 with mode 0400, got: '$secrets'"
                fi
                if [ -z "$publisher" ]; then
                  fail ${host'}": sops-install-secrets no longer runs publish-cli-auth"
                elif grep -q ${secret.file} "$publisher"; then
                  fail ${host'}": publish-cli-auth must not read the ${secret.label} API key"
                fi
              ''
            else
              ''
                if [ -n "$secrets" ]; then
                  fail ${host'}": a bootstrap configuration, or one with ${secret.option} off, must not decrypt the ${secret.label} secret, got: '$secrets'"
                fi
              ''
          }
        ''
      ) apiKeySecrets}
    '';
in
pkgs.runCommand "agent-api-key-secrets-tests" { nativeBuildInputs = [ pkgs.python3 ]; } ''
  ${configurations.guard}
  ${lib.optionalString (lib.length keyForcedOff != lib.length apiKeySecrets) ''
    echo "no production configuration to re-evaluate with each API key option off" >&2
    exit 1
  ''}
  failed=0
  fail() { echo "$1" >&2; failed=1; }
  ${lib.concatMapStringsSep "\n" assertApiKeys (configurations.entries ++ keyForcedOff)}
  if [ "$failed" != 0 ]; then exit 1; fi
  touch $out
''
