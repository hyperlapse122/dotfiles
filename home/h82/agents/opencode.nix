{
  config,
  pkgs,
  lib,
  ...
}:
let
  quality = import ./quality-hooks.nix {
    inherit config pkgs lib;
    harness = "opencode";
  };
  opencode = import ../../../packages/opencode.nix { inherit pkgs; };
  tools = import ../../../packages/agent-tools.nix { inherit pkgs; };
  merger = "${tools.agentSettings}/bin/agent-settings";
  authSync = "${tools.opencodeAuthSync}/bin/opencode-auth-sync";
  settingsFile = "${config.home.homeDirectory}/.config/opencode/opencode.json";

  keyDirectory = config.my.secrets.stateDir;

  # Synthetic shows the models Pi shows: the lock minus Pi's hidden set.
  # Every other model either source names is disabled, so a catalog that
  # grows or a hidden model OpenCode's own catalog adds never appears.
  lock = (builtins.fromJSON (builtins.readFile ./pi-model-lock.json)).syntheticModelLocks;
  hiddenIds = map (lib.removePrefix "synthetic/") (import ./pi-hidden-models.nix);
  syntheticCatalog = (builtins.fromJSON (builtins.readFile ./synthetic-catalog.json)).data;
  visibleModels = lib.filter (model: !(lib.elem model.id hiddenIds)) lock.models;
  visibleIds = map (model: model.id) visibleModels;
  hiddenCandidates = lib.unique (
    map (model: model.id) lock.models ++ map (row: row.id) syntheticCatalog
  );

  # A model row in Pi's models.json shape, as OpenCode declares it.
  openCodeModel = model: {
    inherit (model) name;
    limit = {
      context = model.contextWindow;
      output = model.maxTokens;
    };
    cost = {
      inherit (model.cost) input output;
      cache = {
        read = model.cost.cacheRead;
        write = model.cost.cacheWrite;
      };
    };
  };
  declaredModels =
    models: lib.listToAttrs (map (model: lib.nameValuePair model.id (openCodeModel model)) models);

  # OpenAI and Anthropic show the same committed lists as Pi. OpenCode's own
  # catalog keeps every other model of these providers.
  openaiModels = declaredModels (import ./openai-models.nix lib);
  anthropicModels = declaredModels (builtins.fromJSON (builtins.readFile ./anthropic-models.json))
    .models;

  syntheticModels =
    declaredModels visibleModels
    // lib.genAttrs (lib.subtractLists visibleIds hiddenCandidates) (_: {
      disabled = true;
    });

  # OpenCode's own catalog already routes each Go model over the protocol it
  # is served on, so the snapshot only sets the limits and prices.
  goCatalog = (builtins.fromJSON (builtins.readFile ./opencode-go-catalog.json)).data;
  goModels = lib.listToAttrs (
    map (
      row:
      lib.nameValuePair row.id (
        {
          inherit (row) name;
          limit = {
            inherit (row.limit) context output;
          };
        }
        // lib.optionalAttrs (row ? cost) {
          cost = {
            input = row.cost.text.input.price;
            output = row.cost.text.output.price;
          }
          // lib.optionalAttrs (row.cost.text.input ? cache) {
            cache.read = row.cost.text.input.cache.read;
          };
        }
      )
    ) goCatalog
  );

  # The release the Compound Engineering flake input is pinned to, in the
  # name@spec form OpenCode already accepts, so the entry an earlier unpinned
  # install left in the file is replaced rather than joined by a second one.
  pin = import ./agent-plugin-pins.nix;
  pluginRepository = "compound-engineering@git+https://github.com/${pin.compound-engineering.upstream}";
  pluginSpec = "${pluginRepository}.git#${pin.compound-engineering.expectedRev}";

  declared = pkgs.writeText "opencode-declared-settings.json" (
    builtins.toJSON {
      set.update = "disable";
      prefixEntries = [
        {
          path = [ "plugins" ];
          prefix = pluginRepository;
          value = pluginSpec;
        }
      ];
      ownEntries = [
        {
          path = [
            "providers"
            "synthetic"
            "models"
          ];
          entries = syntheticModels;
        }
        {
          path = [
            "providers"
            "opencode-go"
            "models"
          ];
          entries = goModels;
        }
        {
          path = [
            "providers"
            "openai"
            "models"
          ];
          entries = openaiModels;
        }
        {
          path = [
            "providers"
            "anthropic"
            "models"
          ];
          entries = anthropicModels;
        }
      ];
    }
  );
in
{
  home.packages = [
    opencode
    tools.opencodeServingModel
  ];
  xdg.configFile."opencode/plugins/dotfiles-agent-quality.ts" = lib.mkIf quality.enable {
    source = quality.renderExtension ./opencode-quality.ts;
  };
  my.agents.crossModelPeers = [ "opencode" ];

  # OpenCode rewrites its own config (`plugin add` and the settings it saves),
  # so activation assigns the declared keys and leaves the rest as it wrote
  # it. The update check is off because the release pin owns the version.
  home.activation.opencodeSettings = lib.hm.dag.entryAfter [ "installPackages" ] ''
    if [[ ! -v DRY_RUN ]]; then
      ${merger} --label OpenCode \
        --settings ${lib.escapeShellArg settingsFile} \
        --declared ${declared} \
        --ledger ${lib.escapeShellArg "${config.home.homeDirectory}/.config/opencode/opencode-ownership.json"}
    fi
  '';

  # Installs the pinned plugin into OpenCode's cache now, instead of leaving
  # the first session to fetch it in the background. It fetches from GitHub,
  # so a failure warns and the switch goes on; OpenCode installs the plugin
  # itself on first use.
  home.activation.opencodePlugin = lib.hm.dag.entryAfter [ "opencodeSettings" ] ''
    if [[ ! -v DRY_RUN ]]; then
      if ! ${opencode}/bin/opencode plugin add ${lib.escapeShellArg pluginSpec}; then
        echo 'opencodePlugin: could not pre-install the pinned plugin; OpenCode installs it on first use.' >&2
      fi
    fi
  '';

  # NixOS imports after SOPS publication, without waiting for Home Manager.
  home.activation.opencodeAuth = lib.mkIf (config.my.kind == "darwin" && !config.my.bootstrap) (
    lib.hm.dag.entryAfter [ "nixConfigSecretsPublish" ] ''
      if [[ ! -v DRY_RUN ]]; then
        ${authSync} --opencode ${opencode}/bin/opencode \
          --credential synthetic=${lib.escapeShellArg "${keyDirectory}/synthetic_api_key"} \
          --credential opencode-go=${lib.escapeShellArg "${keyDirectory}/opencode_go_api_key"} \
          --credential openai=${lib.escapeShellArg "${keyDirectory}/openai_api_key"} \
          --credential anthropic=${lib.escapeShellArg "${keyDirectory}/anthropic_api_key"}
      fi
    ''
  );
}
