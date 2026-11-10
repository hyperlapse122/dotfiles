{
  config,
  lib,
  pkgs,
  ...
}:
let
  completions = import ../../../packages/zsh-completions.nix { inherit pkgs; };
  mise = config.programs.mise;
  # The condition under which the Home Manager module writes globalConfig to
  # mise/config.toml.
  miseManagesGlobal = mise.enable && !mise.mutableSettings && mise.globalConfig != { };
  miseGlobalConfig = "${config.xdg.configHome}/mise/config.toml";
in
{
  home.sessionVariables.NODE_USE_SYSTEM_CA = "1";
  programs.bash = {
    enable = true;
    enableCompletion = true;
  };
  programs.zsh = {
    enable = true;
    dotDir = "${config.xdg.configHome}/zsh";
    enableCompletion = false;

    prezto = {
      enable = true;
      package = import ../../../packages/prezto.nix { inherit pkgs; };
      editor.keymap = "emacs";
      prompt.theme = "sorin";
      extraConfig = ''
        if ! grep -Eq '^[[:space:]]*enable-ssh-support([[:space:]]|$)' "${config.programs.gpg.homedir}/gpg-agent.conf" 2>/dev/null \
            && ! grep -Eq 'SSH_AUTH_SOCK|SSH_AGENT_PID' "${config.xdg.cacheHome}/prezto/gpg-agent.env" 2>/dev/null; then
          zstyle -a ':prezto:load' pmodule modules
          modules=($modules[1,-6] gpg $modules[-5,-1])
          zstyle ':prezto:load' pmodule $modules
          unset modules
        fi
      '';
      pmodules = [
        "environment"
        "terminal"
        "editor"
        "history"
        "directory"
        "spectrum"
        "git"
        "utility"
      ]
      ++ lib.optional (config.my.kind == "darwin") "homebrew"
      ++ [
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

    initContent = lib.mkBefore ''
      # Keep the user's local completion functions ahead of system functions.
      typeset -U fpath
      fpath=(${completions}/share/zsh/site-functions $HOME/.local/share/zsh/site-functions(N) $fpath)
      [[ -z $TTY ]] || export GPG_TTY=$TTY

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
