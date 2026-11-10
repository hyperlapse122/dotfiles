{ pkgs }:
let
  archives = (builtins.fromJSON (builtins.readFile ./prezto-pin.json)).zshLock.archives;
  unpack =
    asset:
    pkgs.runCommand "prezto-archive"
      {
        nativeBuildInputs = [
          pkgs.gnutar
          pkgs.gzip
        ];
      }
      ''
        mkdir -p $out
        tar -xzf ${pkgs.fetchurl { inherit (asset) url sha256; }} --strip-components=1 -C $out
      '';
in
pkgs.stdenvNoCC.mkDerivation {
  pname = "zsh-prezto-pinned";
  version = builtins.substring 0 12 (builtins.head archives).commit;
  dontUnpack = true;
  nativeBuildInputs = [ pkgs.zsh pkgs.diffutils ];
  installPhase = ''

  mkdir -p $out/share/zsh-prezto
  cp -r ${unpack (builtins.head archives)}/. $out/share/zsh-prezto/
  chmod -R u+w $out
  ${pkgs.lib.concatMapStringsSep "\n" (asset: ''
    rm -rf $out/share/zsh-prezto/${asset.path}
    mkdir -p $out/share/zsh-prezto/${asset.path}
    cp -r ${unpack asset}/. $out/share/zsh-prezto/${asset.path}/
  '') (builtins.tail archives)}
  substituteInPlace $out/share/zsh-prezto/runcoms/zshrc \
    --replace-fail '"''${ZDOTDIR:-$HOME}/.zprezto/' '"'$out'/share/zsh-prezto/'
  '';
  doInstallCheck = true;
  installCheckPhase = ''
    export HOME=$TMPDIR/prezto-home ZDOTDIR=$TMPDIR/prezto-home TERM=xterm-256color
    export LANG=C.UTF-8 LC_ALL=C.UTF-8
    mkdir -p "$HOME"
    ${pkgs.lib.concatMapStringsSep "\n" (asset: ''
      rm -rf expected
      cp -r ${unpack asset} expected
      chmod -R u+w expected
      patchShebangs --host expected
      diff -r expected $out/share/zsh-prezto/${asset.path}
    '') (builtins.tail archives)}
    for asset in \
      modules/autosuggestions/external/zsh-autosuggestions.zsh \
      modules/completion/external/src/_git-flow \
      modules/history-substring-search/external/zsh-history-substring-search.zsh \
      modules/syntax-highlighting/external/zsh-syntax-highlighting.zsh \
      modules/prompt/external/powerline/prompt_powerline_setup \
      modules/prompt/external/agnoster/agnoster.zsh-theme \
      modules/prompt/external/pure/pure.zsh \
      modules/prompt/external/async/async.zsh \
      modules/prompt/external/powerlevel10k/powerlevel10k.zsh-theme; do
      test -s "$out/share/zsh-prezto/$asset" || { echo "missing Prezto asset: $asset" >&2; exit 1; }
    done
    for theme in sorin powerline agnoster pure powerlevel10k; do
      echo "checking Prezto prompt: $theme"
      zsh -dfc '
        zstyle ":prezto:load" pmodule prompt
        zstyle ":prezto:module:prompt" theme "$2"
        POWERLEVEL9K_DISABLE_CONFIGURATION_WIZARD=true
        source "$1/init.zsh"
        zstyle -t ":prezto:module:prompt" loaded || { print -u2 -- "prompt module failed: $2"; exit 1; }
      ' zsh "$out/share/zsh-prezto" "$theme"
    done
  '';
}
