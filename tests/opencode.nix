/*
  Check interface:

    import ./tests/opencode.nix { inherit pkgs self; }

  Asserts that the OpenCode harness reaches user `h82` on every host this
  flake declares, from what each activation block does rather than from its
  text alone.

  Verifies, per Home Manager user environment:
  - `opencode` is in user packages as the package this flake builds, at the
    version `packages/opencode-release.json` pins.
  - `opencodeSettings` runs after installPackages, runs the packaged merger on
    ~/.config/opencode/opencode.json without swallowing its exit status, and no
    Home Manager file targets that path, which OpenCode rewrites.
  - Applied in a scratch HOME over a seed that holds the owner's unpinned
    Compound Engineering plugin entry, another plugin, a user key, and a user
    model, the merge sets `update` to `disable`, leaves one pinned Compound
    Engineering entry beside the other plugin, writes the Synthetic models Pi
    shows with the rest disabled, writes every model of the Go snapshot, and
    keeps the user's key and model. The expected values are computed here from
    the raw lock, hidden list, and catalog files, not from the module.
  - `opencodePlugin` runs after the settings and installs exactly the pinned
    spec.
  - `opencodeAuth` exists on production outputs and not on bootstrap ones, runs
    after the settings (and after secret publication on macOS), and names the
    published key file of each integration without any key text.

  Every lookup carries an `or` fallback and every conditional block sits behind
  `lib.optionalString`, so a removed declaration fails inside the builder
  rather than during evaluation.

  The builder collects every failure instead of exiting at the first.
*/
{ pkgs, self }:
let
  inherit (pkgs) lib;

  configurations = import ./lib/configurations.nix { inherit pkgs self; };
  executeActivation = import ./lib/agent-activation.nix { inherit pkgs; };

  esc = value: lib.escapeShellArg (toString value);

  opencode = self.packages.${pkgs.stdenv.hostPlatform.system}.opencode;
  pinnedVersion = (builtins.fromJSON (builtins.readFile ../packages/opencode-release.json)).version;
  settingsFile = ".config/opencode/opencode.json";

  agents = ../home/h82/agents;
  lockModels =
    (builtins.fromJSON (builtins.readFile (agents + "/pi-model-lock.json"))).syntheticModelLocks.models;
  hiddenIds = map (id: lib.removePrefix "synthetic/" id) (import (agents + "/pi-hidden-models.nix"));
  syntheticRows = (builtins.fromJSON (builtins.readFile (agents + "/synthetic-catalog.json"))).data;
  goRows = (builtins.fromJSON (builtins.readFile (agents + "/opencode-go-catalog.json"))).data;
  pin = (import (agents + "/agent-plugin-pins.nix")).compound-engineering;

  shownModels = builtins.filter (model: !(builtins.elem model.id hiddenIds)) lockModels;
  shownIds = map (model: model.id) shownModels;
  hiddenSynthetic = builtins.filter (id: !(builtins.elem id shownIds)) (
    map (model: model.id) lockModels ++ map (row: row.id) syntheticRows
  );

  expectedSynthetic =
    builtins.listToAttrs (
      map (model: {
        name = model.id;
        value = {
          name = model.name;
          limit = {
            context = model.contextWindow;
            output = model.maxTokens;
          };
          cost = {
            input = model.cost.input;
            output = model.cost.output;
            cache = {
              read = model.cost.cacheRead;
              write = model.cost.cacheWrite;
            };
          };
        };
      }) shownModels
    )
    // builtins.listToAttrs (
      map (id: {
        name = id;
        value.disabled = true;
      }) hiddenSynthetic
    );

  expectedGo = builtins.listToAttrs (
    map (row: {
      name = row.id;
      value = {
        name = row.name;
        limit = {
          context = row.limit.context;
          output = row.limit.output;
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
      };
    }) goRows
  );

  repository = "compound-engineering@git+https://github.com/${pin.upstream}";
  pinnedSpec = "${repository}.git#${pin.expectedRev}";

  declared = {
    set.update = "disable";
    prefixEntries = [
      {
        path = [ "plugins" ];
        prefix = repository;
        value = pinnedSpec;
      }
    ];
    ownEntries = [
      {
        path = [
          "providers"
          "synthetic"
          "models"
        ];
        entries = expectedSynthetic;
      }
      {
        path = [
          "providers"
          "opencode-go"
          "models"
        ];
        entries = expectedGo;
      }
    ];
  };

  userModel = {
    name = "My own model";
    limit = {
      context = 1000;
      output = 100;
    };
  };

  seed = {
    update = "notify";
    userKey = "keep me";
    plugins = [
      "${repository}.git"
      "other-plugin@npm:other-plugin"
    ];
    providers = {
      synthetic.models = {
        "hf:moonshotai/Kimi-K3".name = "stale name";
        my-own-model = userModel;
      };
      custom.models.tiny.name = "Tiny";
    };
  };

  applied = {
    update = "disable";
    userKey = "keep me";
    plugins = [
      "other-plugin@npm:other-plugin"
      pinnedSpec
    ];
    providers = {
      synthetic.models = expectedSynthetic // {
        my-own-model = userModel;
      };
      opencode-go.models = expectedGo;
      custom.models.tiny.name = "Tiny";
    };
  };

  assertHost =
    entry:
    let
      hostName = entry.name;
      userConfig = entry.user;
      home = userConfig.home.homeDirectory or "";
      activations = userConfig.home.activation or { };
      settings = activations.opencodeSettings or null;
      plugin = activations.opencodePlugin or null;
      auth = activations.opencodeAuth or null;
      scriptOf = activation: if activation == null then "" else (activation.data or "");
      afterOf = activation: if activation == null then [ ] else (activation.after or [ ]);
      package = lib.lists.findFirst (p: (p.pname or "") == "opencode") null (
        userConfig.home.packages or [ ]
      );
      keyDirectory =
        if entry.kind == "nixos" then
          "/run/secrets/cli-auth"
        else
          "${userConfig.my.secrets.stateDir or ""}";
      targeted = lib.any (file: (file.target or "") == settingsFile) (
        lib.attrValues (userConfig.home.file or { })
      );
      authExpected = !entry.bootstrap;
      authAfter = [
        "opencodeSettings"
      ]
      ++ lib.optional (entry.kind == "darwin") "nixConfigSecretsPublish";
    in
    ''
      ${lib.optionalString (package == null) ''
        echo 'missing opencode in user packages on ${hostName}' >&2
        failed=1
      ''}
      ${lib.optionalString (package != null) ''
        if [ ${package} != ${opencode} ]; then
          echo "opencode on ${hostName} is ${package}, expected ${opencode}" >&2
          failed=1
        fi
        if [ ${esc (package.version or "")} != ${esc pinnedVersion} ]; then
          echo 'opencode on ${hostName} is not the pinned version ${pinnedVersion}' >&2
          failed=1
        fi
      ''}

      ${lib.optionalString (settings == null) ''
        echo 'missing home.activation.opencodeSettings on ${hostName}' >&2
        failed=1
      ''}
      ${lib.optionalString (settings != null) ''
        if [ ${esc (lib.boolToString (lib.elem "installPackages" (afterOf settings)))} != true ]; then
          echo 'opencodeSettings must run after installPackages on ${hostName}' >&2
          failed=1
        fi
        if printf '%s' ${esc (scriptOf settings)} | grep -v '^[[:space:]]*#' \
          | grep -E '(\|\|[[:space:]]*(true|:|echo)|;[[:space:]]*true|set \+e)' >/dev/null; then
          echo 'opencodeSettings must not swallow the merger exit status on ${hostName}' >&2
          failed=1
        fi
        settingsArg=$(printf '%s' ${esc (scriptOf settings)} | tr '\n' ' ' \
          | grep -oE -- '--settings[[:space:]]+[^[:space:]]+' | sed -n '1p' | awk '{print $2}' || true)
        if [ "$settingsArg" != ${esc "${home}/${settingsFile}"} ]; then
          echo "opencodeSettings must point the merger at ~/${settingsFile} on ${hostName}, got: '$settingsArg'" >&2
          failed=1
        fi
        ${executeActivation {
          script = scriptOf settings;
          inherit home;
          contract = {
            file = settingsFile;
            inherit declared seed;
            expected = applied;
          };
        }}
      ''}
      if [ ${esc (lib.boolToString targeted)} != false ]; then
        echo 'Home Manager must not target ~/${settingsFile} on ${hostName}; OpenCode rewrites it' >&2
        failed=1
      fi

      ${lib.optionalString (plugin == null) ''
        echo 'missing home.activation.opencodePlugin on ${hostName}' >&2
        failed=1
      ''}
      ${lib.optionalString (plugin != null) ''
        if [ ${esc (lib.boolToString (lib.elem "opencodeSettings" (afterOf plugin)))} != true ]; then
          echo 'opencodePlugin must run after opencodeSettings on ${hostName}' >&2
          failed=1
        fi
        if ! printf '%s' ${esc (scriptOf plugin)} | grep -qF -- ${esc "plugin add '${pinnedSpec}'"}; then
          echo 'opencodePlugin must install exactly the pinned plugin spec on ${hostName}' >&2
          failed=1
        fi
      ''}

      ${lib.optionalString (authExpected && auth == null) ''
        echo 'missing home.activation.opencodeAuth on production output ${hostName}' >&2
        failed=1
      ''}
      ${lib.optionalString (!authExpected && auth != null) ''
        echo 'bootstrap output ${hostName} must not import credentials: it holds no published keys' >&2
        failed=1
      ''}
      ${lib.optionalString (authExpected && auth != null) ''
        script=${esc (scriptOf auth)}
        for want in \
          ${esc "--credential synthetic=${keyDirectory}/synthetic_api_key"} \
          ${esc "--credential opencode-go=${keyDirectory}/opencode_go_api_key"} \
          ${esc "--opencode ${opencode}/bin/opencode"}; do
          if ! printf '%s' "$script" | tr '\n\\' '  ' | grep -qF -- "$want"; then
            echo "opencodeAuth on ${hostName} lacks: $want" >&2
            failed=1
          fi
        done
        ${lib.concatMapStringsSep "\n" (dependency: ''
          if [ ${esc (lib.boolToString (lib.elem dependency (afterOf auth)))} != true ]; then
            echo 'opencodeAuth must run after ${dependency} on ${hostName}' >&2
            failed=1
          fi
        '') authAfter}
      ''}
    '';
in
pkgs.runCommand "opencode-tests" { nativeBuildInputs = [ pkgs.diffutils ]; } ''
  ${configurations.userGuard}
  failed=0

  ${lib.concatMapStringsSep "\n" assertHost configurations.userEntries}

  if [ "$failed" != "0" ]; then
    exit 1
  fi

  touch $out
''
