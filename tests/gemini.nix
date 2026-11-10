/*
  Check interface:

    import ./tests/gemini.nix { inherit pkgs self; }

  Asserts that implicit memory is disabled declaratively for the Gemini and
  Antigravity CLIs for user `h82` on every configuration `tests/lib/configurations.nix` yields,
  production and bootstrap alike, since none of it depends on a host trait
  or on `my.bootstrap`.

  Verifies, per configuration:
  - ~/.gemini/settings.json sets experimental.autoMemory = false.
  - no Home Manager file targets .gemini/antigravity-cli/settings.json: the
    Antigravity CLI rewrites it, so a store symlink there would block the next
    activation.
  - home.activation.antigravitySettings runs after installPackages and,
    executed in a scratch HOME through tests/lib/agent-activation.nix, sets
    disableAutoGenerateMemories = true in that file while keeping the keys
    the CLI wrote, and does not swallow a merger refusal.
  - home.activation.antigravityAcpSettings runs after installPackages and,
    executed in a scratch HOME through tests/lib/agent-activation.nix, sets
    auth.type = "oauth-personal" in ~/.gemini/antigravity-acp/settings.json
    while keeping the keys the runtime wrote, so the ACP runtime asks for the
    Google sign-in Compound Engineering's Antigravity route expects.
  - home.activation.antigravityMcpConfig runs after installPackages and,
    executed in a scratch HOME, adds the fff MCP server by its store path to
    ~/.gemini/config/mcp_config.json while keeping a server `agy mcp add`
    wrote there.
*/
{ pkgs, self }:
let
  inherit (pkgs) lib;

  configurations = import ./lib/configurations.nix { inherit pkgs self; };

  executeActivation = import ./lib/agent-activation.nix { inherit pkgs; };

  acpSettingsFile = ".gemini/antigravity-acp/settings.json";

  assertHost =
    entry:
    let
      hostName = entry.name;
      userConfig = entry.user;
      homeFiles = userConfig.home-files or null;

      antigravityTargeted = lib.any (
        file: (file.target or "") == ".gemini/antigravity-cli/settings.json"
      ) (lib.attrValues (userConfig.home.file or { }));

      geminiDelivery =
        if homeFiles == null then
          "echo 'missing Gemini home-files on ${hostName}' >&2; failed=1"
        else
          ''
            if ! ${pkgs.jq}/bin/jq -e '.experimental.autoMemory == false' ${homeFiles}/.gemini/settings.json >/dev/null; then
              echo 'missing or incorrect delivered Gemini settings on ${hostName}' >&2
              failed=1
            fi
          '';

      symlinkPresent = lib.optionalString antigravityTargeted ''
        echo 'Home Manager must not target ~/.gemini/antigravity-cli/settings.json on ${hostName}' >&2
        failed=1
      '';

      cliActivation = userConfig.home.activation.antigravitySettings or null;
      cliRunsAfterPackages = lib.elem "installPackages" (
        if cliActivation == null then [ ] else (cliActivation.after or [ ])
      );
      cliSettings =
        if cliActivation == null then
          ''
            echo 'missing home.activation.antigravitySettings on ${hostName}' >&2
            failed=1
          ''
        else
          ''
            if [ ${lib.boolToString cliRunsAfterPackages} != true ]; then
              echo 'home.activation.antigravitySettings must run after installPackages on ${hostName}' >&2
              failed=1
            fi
            ${executeActivation {
              script = cliActivation.data or "";
              home = userConfig.home.homeDirectory or "";
              contract = {
                file = ".gemini/antigravity-cli/settings.json";
                declared = {
                  set.disableAutoGenerateMemories = true;
                  remove = [ ];
                };
              };
            }}
          '';

      acpActivation = userConfig.home.activation.antigravityAcpSettings or null;
      acpRunsAfterPackages = lib.elem "installPackages" (
        if acpActivation == null then [ ] else (acpActivation.after or [ ])
      );
      acpSettings =
        if acpActivation == null then
          ''
            echo 'missing home.activation.antigravityAcpSettings on ${hostName}' >&2
            failed=1
          ''
        else
          ''
            if [ ${lib.boolToString acpRunsAfterPackages} != true ]; then
              echo 'home.activation.antigravityAcpSettings must run after installPackages on ${hostName}' >&2
              failed=1
            fi
            ${executeActivation {
              script = acpActivation.data or "";
              home = userConfig.home.homeDirectory or "";
              contract = {
                file = acpSettingsFile;
                declared.setPaths = [
                  {
                    path = [
                      "auth"
                      "type"
                    ];
                    value = "oauth-personal";
                  }
                ];
                seed = {
                  auth = {
                    type = "gemini-api-key";
                    project = "kept";
                  };
                  model = "kept";
                };
                expected = {
                  auth = {
                    type = "oauth-personal";
                    project = "kept";
                  };
                  model = "kept";
                };
              };
            }}
          '';
      mcpActivation = userConfig.home.activation.antigravityMcpConfig or null;
      mcpRunsAfterPackages = lib.elem "installPackages" (
        if mcpActivation == null then [ ] else (mcpActivation.after or [ ])
      );
      mcpConfig =
        if mcpActivation == null then
          ''
            echo 'missing home.activation.antigravityMcpConfig on ${hostName}' >&2
            failed=1
          ''
        else
          ''
            if [ ${lib.boolToString mcpRunsAfterPackages} != true ]; then
              echo 'home.activation.antigravityMcpConfig must run after installPackages on ${hostName}' >&2
              failed=1
            fi
            ${executeActivation {
              script = mcpActivation.data or "";
              home = userConfig.home.homeDirectory or "";
              contract = {
                file = ".gemini/config/mcp_config.json";
                declared.ownEntries = [
                  {
                    path = [ "mcpServers" ];
                    entries.fff = {
                      command = "${pkgs.fff-mcp}/bin/fff-mcp";
                      args = [ "--no-update-check" ];
                      disabled = false;
                    };
                  }
                ];
                # A server added with `agy mcp add` survives beside it.
                seed.mcpServers.other = {
                  command = "other";
                  disabled = false;
                };
                preservePaths = [
                  [
                    "mcpServers"
                    "other"
                  ]
                ];
              };
            }}
          '';
    in
    ''
      ${geminiDelivery}
      ${symlinkPresent}
      ${cliSettings}
      ${acpSettings}
      ${mcpConfig}
    '';
in
pkgs.runCommand "gemini-tests" { nativeBuildInputs = [ pkgs.diffutils ]; } ''
  set -x
  ${configurations.userGuard}
  failed=0

  ${lib.concatMapStringsSep "\n" assertHost configurations.userEntries}

  if [ "$failed" != "0" ]; then
    exit 1
  fi

  touch $out
''
