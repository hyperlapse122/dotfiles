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
  ++ lib.optionals (hostKind == "darwin") [
    ./desktop/chrome-darwin.nix
    ./desktop/terminal.nix
  ]
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
      [
        (import ../../packages/bun.nix { inherit pkgs; })
        docker-credential-helpers
      ]
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
    ]
    ++ [
      (import ../../packages/claude-code.nix { inherit pkgs; })
      (import ../../packages/codex.nix { inherit pkgs; })
      (import ../../packages/acpx.nix { inherit pkgs; })
      (import ../../packages/agent-tools.nix { inherit pkgs; }).serveHtml
      (
        let
          nixTools = import ../../packages/nix-tools.nix { inherit pkgs; };
        in
        {
          nixos = nixTools.nr;
          darwin = nixTools.nrDarwin;
        }
        .${hostKind}
      )
    ];

  home.sessionVariables.LANGUAGE = "ko_KR:ko:en_US:en";
}
