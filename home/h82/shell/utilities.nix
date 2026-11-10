{ lib, pkgs, ... }:
{
  # Command-line tools for scripts and pipelines. They are plain commands: no
  # shell integration, so zsh and prezto keep their key bindings and aliases.
  home.packages =
    with pkgs;
    [
      bat
      fd
      ffmpeg
      file
      fzf
      jq
      lsof
      moreutils
      procps
      ripgrep
      shellcheck
      shfmt
      tree
      unzip
      wget
    ]
    # A Wayland clipboard tool; macOS has pbcopy and pbpaste. Kept in place so
    # the Linux list keeps its order.
    ++ lib.optional stdenv.hostPlatform.isLinux wl-clipboard
    ++ [
      yq-go
      zip
    ];
}
