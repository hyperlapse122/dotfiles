/*
  Check interface:

    import ./tests/grok.nix { inherit pkgs self; }

  Asserts that Grok Build gets the fff MCP server for user `h82` on every
  configuration `tests/lib/configurations.nix` yields, production and
  bootstrap alike, since none of it depends on a host trait or on
  `my.bootstrap`.

  Verifies, per configuration:
  - home.activation.grokSettings runs after installPackages, so a refusal
    cannot strand linkGeneration and installPackages behind it.
  - executed in a scratch HOME through tests/lib/agent-activation.nix, it adds
    `[mcp_servers.fff]` with the fff-mcp store path to ~/.grok/config.toml,
    keeps the marketplace sources and comments Grok wrote there, leaves the
    file unchanged on a second run, and does not swallow a merger refusal.
  - no Home Manager file targets ~/.grok/config.toml, which Grok rewrites.

  The builder collects every failure instead of exiting at the first.
*/
{ pkgs, self }:
let
  inherit (pkgs) lib;

  configurations = import ./lib/configurations.nix { inherit pkgs self; };

  executeActivation = import ./lib/agent-activation.nix { inherit pkgs; };

  settingsFile = ".grok/config.toml";

  assertHost =
    entry:
    let
      hostName = entry.name;
      userConfig = entry.user;
      activation = userConfig.home.activation.grokSettings or null;
      runsAfterPackages = lib.elem "installPackages" (
        if activation == null then [ ] else (activation.after or [ ])
      );
      targeted = lib.any (file: (file.target or "") == settingsFile) (
        lib.attrValues (userConfig.home.file or { })
      );
    in
    (
      if activation == null then
        ''
          echo 'missing home.activation.grokSettings on ${hostName}' >&2
          failed=1
        ''
      else
        ''
          if [ ${lib.boolToString runsAfterPackages} != true ]; then
            echo 'home.activation.grokSettings must run after installPackages on ${hostName}' >&2
            failed=1
          fi
          ${executeActivation {
            script = activation.data or "";
            home = userConfig.home.homeDirectory or "";
            contract = {
              file = settingsFile;
              format = "toml";
              declared.ownEntries = [
                {
                  path = [ "mcp_servers" ];
                  entries.fff = {
                    command = "${pkgs.fff-mcp}/bin/fff-mcp";
                    args = [ "--no-update-check" ];
                    enabled = true;
                  };
                }
              ];
              seed = ''
                # user comment survives
                [marketplace]
                auto_update = false
                [[marketplace.sources]]
                name = "kept"
                [mcp_servers.other]
                command = "other"
              '';
              expected = {
                marketplace = {
                  auto_update = false;
                  sources = [ { name = "kept"; } ];
                };
                mcp_servers = {
                  other.command = "other";
                  fff = {
                    command = "${pkgs.fff-mcp}/bin/fff-mcp";
                    args = [ "--no-update-check" ];
                    enabled = true;
                  };
                };
              };
            };
          }}
        ''
    )
    + lib.optionalString targeted ''
      echo 'Home Manager must not target ~/${settingsFile} on ${hostName}; Grok Build owns it' >&2
      failed=1
    '';
in
pkgs.runCommand "grok-tests" { } ''
  ${configurations.userGuard}
  failed=0

  ${lib.concatMapStringsSep "\n" assertHost configurations.userEntries}

  if [ "$failed" != "0" ]; then
    exit 1
  fi

  touch $out
''
