{
  config,
  pkgs,
  lib,
  ...
}:
let
  opencode = import ../../../packages/opencode.nix { inherit pkgs; };
  tools = import ../../../packages/agent-tools.nix { inherit pkgs; };
  merger = "${tools.agentSettings}/bin/agent-settings";
  authSync = "${tools.opencodeAuthSync}/bin/opencode-auth-sync";
  settingsFile = "${config.home.homeDirectory}/.config/opencode/opencode.json";

  keyDirectory = config.my.secrets.stateDir;

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
      set.shell = "${pkgs.bash}/bin/bash";
      prefixEntries = [
        {
          path = [ "plugins" ];
          prefix = pluginRepository;
          value = pluginSpec;
        }
      ];
      ownEntries = [
        # OpenCode's own catalog lists the Synthetic and Anthropic models. The
        # empty sets remove the rows earlier generations declared, including
        # the disabled rows that hid catalog models; delete them once every
        # host has applied them.
        {
          path = [
            "providers"
            "synthetic"
            "models"
          ];
          entries = { };
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
            "anthropic"
            "models"
          ];
          entries = { };
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
          --credential anthropic=${lib.escapeShellArg "${keyDirectory}/anthropic_api_key"}
      fi
    ''
  );
}
