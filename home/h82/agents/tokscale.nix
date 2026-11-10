{
  config,
  pkgs,
  lib,
  ...
}:
let
  merger = "${
    (import ../../../packages/agent-tools.nix { inherit pkgs; }).agentSettings
  }/bin/agent-settings";

  # The wrapper reads /run/secrets/cli-auth/tokscale_token at run time. Hosts
  # that do not opt in through my.cliAuth.enableTokscaleToken, bootstrap
  # included, have no such file and run Tokscale unauthenticated.
  wrapper = import ../../../packages/tokscale.nix (
    {
      inherit pkgs;
      inherit (config.my) hostName;
    }
    # A non-NixOS host, Linux or macOS, keeps its decrypted tokens in the
    # user's state directory instead (home/h82/security/non-nixos-secrets.nix).
    // lib.optionalAttrs (config.my.kind != "nixos") {
      tokenFile = "${config.my.secrets.stateDir}/tokscale_token";
    }
  );

  # Tokscale owns ~/.config/tokscale/settings.json and rewrites it from its TUI,
  # so activation assigns these keys and leaves every other key, including
  # runtime state such as autosubmit.lastRunAtMs, as Tokscale wrote it. A key
  # listed here returns to its declared value on the next rebuild that produces
  # a new Home Manager generation.
  settingsTier = {
    colorPalette = "blue";
    autoRefreshEnabled = true;
    autoRefreshMs = 30000;
  };

  nestedSettings = [
    # Tokscale refuses to change the bucket timezone itself because submitted
    # day rows are monotonic; changing it needs a server resync first, so do
    # not edit this value casually.
    {
      path = [
        "scanner"
        "bucketTimezone"
      ];
      value = "Asia/Seoul";
    }
    {
      path = [
        "autosubmit"
        "enabled"
      ];
      value = false;
    }
  ];

  declared = pkgs.writeText "tokscale-declared-settings.json" (
    builtins.toJSON {
      set = settingsTier;
      setPaths = nestedSettings;
    }
  );

  customPricing = {
    "$schema" = "https://tokscale.ai/custom-pricing.schema.json";
    models = {
      "gemini-3.1-pro" = {
        input_cost_per_million_tokens = 4;
        output_cost_per_million_tokens = 18;
        cache_read_input_token_cost_per_million_tokens = 0.4;
        cache_creation_input_token_cost_per_million_tokens = 0.375;
      };
      "claude-fable-5-1" = {
        input_cost_per_million_tokens = 10;
        output_cost_per_million_tokens = 50;
        cache_read_input_token_cost_per_million_tokens = 0.25;
        cache_creation_input_token_cost_per_million_tokens = 12.5;
      };
    };
  };
in
{
  home.packages = [ wrapper ];

  # Tokscale only reads its custom prices, so a store symlink is enough.
  xdg.configFile."tokscale/custom-pricing.json".text = builtins.toJSON customPricing;

  # No executable-existence guard; ordered after installPackages as on
  # claudeSettings in claude.nix: a refusal must fail the rebuild loudly
  # without stranding linkGeneration or installPackages behind it.
  home.activation.tokscaleSettings = lib.hm.dag.entryAfter [ "installPackages" ] ''
    if [[ ! -v DRY_RUN ]]; then
      ${merger} \
        --label Tokscale \
        --settings ${config.home.homeDirectory}/.config/tokscale/settings.json \
        --declared ${declared}
    fi
  '';
}
