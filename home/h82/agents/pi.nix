{
  config,
  pkgs,
  lib,
  inputs,
  ...
}:
let
  catalog = (builtins.fromJSON (builtins.readFile ./pi-model-lock.json)).syntheticModelLocks;
  # The committed lists for the built-in providers. A declared row replaces
  # the model of the same id in Pi's own catalog and drops that model's compat,
  # thinking-level, and cache settings, so models.json declares only the
  # listed models the compiled catalog lacks. That set is computed from the
  # catalog the Pi build pins, so a refreshed list or a Pi bump needs no edit.
  # Each declared row names the API it is served over and leaves the
  # provider's endpoint and credentials alone.
  providerApis = {
    openai = "openai-responses";
    anthropic = "anthropic-messages";
  };
  openaiContextCap = import ./openai-context-window-cap.nix;
  providerRows = lib.mapAttrs (
    provider: _: (builtins.fromJSON (builtins.readFile (./. + "/${provider}-models.json"))).models
  ) providerApis;
  modelsJson =
    pkgs.runCommand "pi-models.json"
      {
        nativeBuildInputs = [ pkgs.jq ];
        synthetic = builtins.toJSON { inherit (catalog) api baseUrl models; };
        apis = builtins.toJSON providerApis;
        rows = builtins.toJSON providerRows;
        passAsFile = [
          "synthetic"
          "apis"
          "rows"
        ];
      }
      ''
        jq -n \
          --slurpfile catalog ${pi.modelCatalog} \
          --slurpfile synthetic "$syntheticPath" \
          --slurpfile apis "$apisPath" \
          --slurpfile rows "$rowsPath" \
          --argjson openaiCap ${toString openaiContextCap} '
          def defined($p): [$catalog[0][$p][]? | select((.type // "chat") == "chat") | .id];
          {providers: ({synthetic: $synthetic[0]} + ($apis[0] | with_entries(
            .key as $p | .value as $api | {key: $p, value: ({models: [
              $rows[0][$p][] | select(.id as $id | (defined($p) | index($id)) == null) | . + {api: $api}
            ]} + if $p == "openai" then {modelOverrides: ($rows[0][$p] | map({
              key: .id, value: {contextWindowCap: ([.contextWindow, $openaiCap] | min)}
            }) | from_entries)} else {} end)})))}' > $out
      '';
  # Cycling and startup selection cover every listed model, declared or not.
  enabledModelArgs = lib.escapeShellArgs (
    lib.concatMap (
      provider:
      lib.concatMap (model: [
        "--model"
        "${provider}/${model.id}"
      ]) providerRows.${provider}
    ) (lib.attrNames providerApis)
  );
  hiddenModelArgs = lib.escapeShellArgs (
    lib.concatMap (model: [
      "--hide-model"
      model
    ]) (import ./pi-hidden-models.nix)
  );
  agent = "${config.home.homeDirectory}/.pi/agent";
  keyDirectory =
    if config.my.kind == "nixos" then "/run/secrets/cli-auth" else config.my.secrets.stateDir;
  pi = import ../../../packages/pi.nix {
    inherit pkgs;
    syntheticKeyFile = "${keyDirectory}/synthetic_api_key";
    exaKeyFile = "${keyDirectory}/exa_api_key";
    openaiKeyFile = "${keyDirectory}/openai_api_key";
    anthropicKeyFile = "${keyDirectory}/anthropic_api_key";
  };
  state = pkgs.writeScriptBin "pi-state" (
    "#!${pkgs.python3}/bin/python3\n"
    + lib.removePrefix "#!/usr/bin/env python3\n" (builtins.readFile ../../../scripts/pi-state)
  );
  decide = import ./decide-server.nix { inherit config pkgs; };
  merger = "${
    (import ../../../packages/agent-tools.nix { inherit pkgs; }).agentSettings
  }/bin/agent-settings";
  mcpSettings = pkgs.writeText "pi-declared-mcp.json" (
    builtins.toJSON {
      ownEntries = [
        {
          path = [ "mcpServers" ];
          entries.decide = {
            type = "stdio";
            inherit (decide) command timeout;
            exposure = "direct";
          };
        }
      ];
    }
  );
in
{
  home.packages = [ pi ];
  home.file.".pi/agent/dotfiles-web.ts".source = ./pi-web.ts;
  home.file.".pi/agent/dotfiles-question.ts".source = ./pi-question.ts;
  home.file.".pi/agent/models.json".source = modelsJson;
  home.activation.piSettings = lib.hm.dag.entryAfter [ "installPackages" ] ''
    if [[ ! -v DRY_RUN ]]; then
      ${pi}/libexec/pi/pi install ${inputs.compound-engineering-plugin}
      ${state}/bin/pi-state --agent ${lib.escapeShellArg agent} --plugin ${inputs.compound-engineering-plugin} ${hiddenModelArgs} ${enabledModelArgs}
    fi
  '';
  home.activation.piMcpSettings = lib.hm.dag.entryAfter [ "installPackages" ] ''
    if [[ ! -v DRY_RUN ]]; then
      ${merger} --label Pi \
        --settings ${lib.escapeShellArg "${agent}/mcp.json"} \
        --declared ${mcpSettings} \
        --ledger ${lib.escapeShellArg "${agent}/mcp-ownership.json"}
    fi
  '';
  home.activation.piAuth = lib.mkIf (!config.my.bootstrap) (
    lib.hm.dag.entryAfter
      ([ "piSettings" ] ++ lib.optional (config.my.kind == "darwin") "nixConfigSecretsPublish")
      ''
        if [[ ! -v DRY_RUN ]]; then
          ${state}/bin/pi-state --agent ${lib.escapeShellArg agent} --auth-only \
            --key ${lib.escapeShellArg "${keyDirectory}/synthetic_api_key"} \
            --credential ${lib.escapeShellArg "openai=${keyDirectory}/openai_api_key"} \
            --credential ${lib.escapeShellArg "anthropic=${keyDirectory}/anthropic_api_key"}
        fi
      ''
  );

}
