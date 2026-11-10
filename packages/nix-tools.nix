{ pkgs }:

let
  nr = pkgs.stdenvNoCC.mkDerivation {
    pname = "nr";
    version = "1";
    dontUnpack = true;
    installPhase = ''
      install -Dm755 ${../scripts/nr} $out/bin/nr
      substituteInPlace $out/bin/nr \
        --replace-fail '@NVD@' '${pkgs.nvd}/bin/nvd' \
        --replace-fail '@GIT@' '${pkgs.git}/bin/git'
      patchShebangs $out/bin/nr
    '';
    meta.mainProgram = "nr";
  };

  # The non-NixOS apply helper, installed under the same command name so the
  # shell aliases work on either host kind.
  nrLinux = pkgs.stdenvNoCC.mkDerivation {
    pname = "nr-linux";
    version = "1";
    dontUnpack = true;
    installPhase = ''
      install -Dm755 ${../scripts/nr-linux} $out/bin/nr
      substituteInPlace $out/bin/nr \
        --replace-fail '@GIT@' '${pkgs.git}/bin/git'
      patchShebangs $out/bin/nr
    '';
    meta.mainProgram = "nr";
  };

  # The macOS apply helper, under the same command name for the same reason.
  nrDarwin = pkgs.stdenvNoCC.mkDerivation {
    pname = "nr-darwin";
    version = "1";
    dontUnpack = true;
    installPhase = ''
      install -Dm755 ${../scripts/nr-darwin} $out/bin/nr
      substituteInPlace $out/bin/nr \
        --replace-fail '@GIT@' '${pkgs.git}/bin/git'
      patchShebangs $out/bin/nr
    '';
    meta.mainProgram = "nr";
  };
in
{
  inherit nr nrLinux nrDarwin;
}
