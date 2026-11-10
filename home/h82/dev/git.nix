{ config, pkgs, ... }:
{
  home.packages = [ pkgs.git-trim ];

  programs.git = {
    enable = true;
    lfs.enable = true;
    signing = {
      key = config.my.user.gpgKey;
      signByDefault = true;
    };
    settings = {
      user.name = "Joosung Park";
      user.email = "iam@h82.dev";
      core.autocrlf = false;
      init.defaultBranch = "main";
      pull.rebase = true;
      push.autoSetupRemote = true;
      push.recurseSubmodules = "check";
      tag.gpgSign = true;
      # Upstream defaults to merged:origin, which also deletes merged branches
      # on the remote, and to detaching a checkout whose merged branch it
      # deletes, which rewrites HEAD in linked worktrees.
      trim.delete = "merged-local";
      trim.detach = false;
      gpg.program =
        if config.my.kind == "darwin" then
          "${(import ../../../packages/gpg-tools.nix { inherit pkgs; }).gitGpg}/bin/gpg-git"
        else
          "${pkgs.gnupg}/bin/gpg";

      "credential.https://gist.github.com" = {
        helper = [
          ""
          "!${pkgs.gh}/bin/gh auth git-credential"
        ];
      };
      "credential.https://github.com" = {
        helper = [
          ""
          "!${pkgs.gh}/bin/gh auth git-credential"
        ];
      };
      "credential.https://gitlab.com" = {
        helper = [
          ""
          "!${pkgs.glab}/bin/glab auth git-credential"
        ];
      };
      "credential.https://git.jpi.app" = {
        helper = [
          ""
          "!${pkgs.glab}/bin/glab auth git-credential"
        ];
      };
    };
  };
}
