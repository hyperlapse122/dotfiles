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
pkgs.runCommand "zsh-prezto-pinned" { } ''
  mkdir -p $out/share/zsh-prezto
  cp -r ${unpack (builtins.head archives)}/. $out/share/zsh-prezto/
  chmod -R u+w $out
  ${pkgs.lib.concatMapStringsSep "\n" (asset: ''
    rm -rf $out/share/zsh-prezto/${asset.path}
    mkdir -p $out/share/zsh-prezto/${asset.path}
    cp -r ${unpack asset}/. $out/share/zsh-prezto/${asset.path}/
  '') (builtins.tail archives)}
''
