{ pkgs }:
pkgs.lib.mapAttrsToList (
  name: asset:
  pkgs.stdenvNoCC.mkDerivation {
    pname = name;
    version = pkgs.lib.removePrefix "v" asset.tag;
    src = pkgs.fetchurl { inherit (asset) url sha256; };
    nativeBuildInputs = [ pkgs.unzip ];
    sourceRoot = ".";
    doInstallCheck = true;
    nativeInstallCheckInputs = [ pkgs.fontconfig ];
    installCheckPhase = ''
      count=$(find $out/share/fonts -name '*.ttf' -type f | wc -l)
      test "$count" -gt 0
      fc-scan --format '%{family}\n' $out/share/fonts/truetype/*.ttf | grep -i '${
        if name == "jetendard" then
          "Jetendard"
        else if name == "pretendard-jp" then
          "Pretendard JP"
        else if name == "pretendard-std" then
          "Pretendard Std"
        else if name == "pretendard-gov" then
          "Pretendard GOV"
        else if name == "d2coding-nerd" then
          "D2.*Nerd"
        else
          "JetBrains.*Nerd"
      }'
    '';
    installPhase = ''
      mkdir -p $out/share/fonts/truetype
      find . -type f -name '*.ttf' -exec cp {} $out/share/fonts/truetype/ \;
    '';
  }
) (builtins.fromJSON (builtins.readFile ./overlay-fonts.json))
