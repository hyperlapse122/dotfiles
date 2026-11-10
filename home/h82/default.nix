{
  config,
  pkgs,
  lib,
  hostKind,
  ...
}:
let
  # Desktop parts are gated where they stand rather than moved to a separate
  # module, so the NixOS package list keeps its order and its store path. The
  # gate is the hostKind special argument: an import conditional on `config`
  # would recurse.
  nixos = hostKind == "nixos";
  gui = lib.optionals nixos;
in
{
  imports = [
    ./agents
  ]
  ++ gui [ ./desktop ]
  # macOS gets the same terminal configuration, but none of the KDE desktop.
  ++ lib.optionals (hostKind == "darwin") [ ./desktop/terminal.nix ]
  ++ [
    ./dev
    ./security
    ./shell
    ./t3code.nix
  ];

  home.username = config.my.user.name;
  home.homeDirectory = config.my.user.home;
  home.stateVersion = "26.05";

  home.packages =
    (
      with pkgs;
      [ bun ]
      ++ gui [ discord ]
      ++ [
        gh
        glab
      ]
      ++ gui [
        google-chrome
        kdePackages.kleopatra
        kdePackages.ksshaskpass
        kdePackages.okular
        libreoffice-qt
      ]
      ++ [
        nodejs
        python3
      ]
      ++ gui [ telegram-desktop ]
      ++ [ uv ]
      ++ gui [ yubioath-flutter ]
    )
    ++ gui [
      (import ../../packages/claude-desktop.nix { inherit pkgs; })
      (import ../../packages/chatgpt.nix { inherit pkgs; })
    ]
    # Its root daemon comes from modules/nixos/services/wifiman.nix under the
    # same trait.
    ++ lib.optionals (nixos && config.my.wifiman.enable) [
      (import ../../packages/wifiman-desktop.nix { inherit pkgs; })
    ]
    ++ [
      (import ../../packages/claude-code.nix { inherit pkgs; })
      (import ../../packages/codex.nix { inherit pkgs; })
      (import ../../packages/antigravity-cli.nix { inherit pkgs; })
      # Compound Engineering's Antigravity route finds the runtime on PATH.
      (import ../../packages/antigravity-acp-path.nix {
        inherit pkgs;
        skills = config.my.antigravitySkillNames;
      })
      (import ../../packages/agent-tools.nix { inherit pkgs; }).serveHtml
      (
        let
          nixTools = import ../../packages/nix-tools.nix { inherit pkgs; };
        in
        {
          nixos = nixTools.nr;
          linux = nixTools.nrLinux;
          darwin = nixTools.nrDarwin;
        }
        .${hostKind}
      )
    ];

  home.sessionVariables.LANGUAGE = "ko_KR:ko:en_US:en";
}
