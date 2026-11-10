{
  config,
  lib,
  pkgs,
  ...
}:
let
  mise = config.programs.mise;
  # The condition under which the Home Manager module writes globalConfig to
  # mise/config.toml.
  miseManagesGlobal = mise.enable && !mise.mutableSettings && mise.globalConfig != { };
  miseGlobalConfig = "${config.xdg.configHome}/mise/config.toml";
in
{
  programs.zsh = {
    enable = true;
    dotDir = "${config.xdg.configHome}/zsh";
    enableCompletion = true;
    autosuggestion.enable = true;
    syntaxHighlighting.enable = true;

    prezto = {
      enable = true;
      pmodules = [
        "environment"
        "terminal"
        "editor"
        "history"
        "directory"
        "spectrum"
        "git"
        "utility"
        "completion"
        "syntax-highlighting"
        "history-substring-search"
        "autosuggestions"
        "prompt"
      ];
    };

    shellAliases = {
      nrs = "nr switch";
      nrd = "nr build";
    }
    # boot and test need a bootloader generation, which only NixOS has; the
    # non-NixOS nr refuses them.
    // lib.optionalAttrs (config.my.kind == "nixos") {
      nrb = "nr boot";
      nrt = "nr test";
    };

    history = {
      size = 10000;
      save = 10000;
      path = "$HOME/.local/state/zsh/history";
      extended = true;
      ignoreDups = true;
      share = true;
    };

    initContent = ''
      # Keep the user's local completion functions ahead of system functions.
      fpath=($HOME/.local/share/zsh/site-functions(N) $fpath)
    '';
  };

  programs.mise = {
    enable = true;
    # Track upstream releases instead of nixpkgs' lagging version.
    package = import ../../../packages/mise.nix { inherit pkgs; };
    enableZshIntegration = true;
    # mise compiles runtimes from source by default on NixOS; nix-ld runs the
    # precompiled binaries instead.
    globalConfig.settings.all_compile = false;
  };

  # Earlier generations left a writable config.toml, which would collide with
  # the store link. The force mirrors the module's own condition, because a
  # force on an entry the module does not declare leaves it with no source.
  xdg.configFile = lib.mkIf miseManagesGlobal { "mise/config.toml".force = true; };

  # Even with force, Home Manager leaves a regular file in place when its
  # content matches the generated one, which would keep config.toml writable.
  home.activation.miseReplaceWritableConfig = lib.mkIf miseManagesGlobal (
    lib.hm.dag.entryBetween [ "linkGeneration" ] [ "writeBoundary" ] ''
      if [[ -f ${lib.escapeShellArg miseGlobalConfig} && ! -L ${lib.escapeShellArg miseGlobalConfig} ]]; then
        run rm $VERBOSE_ARG ${lib.escapeShellArg miseGlobalConfig}
      fi
    ''
  );
}
