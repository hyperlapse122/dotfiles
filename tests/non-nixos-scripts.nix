/*
  Check interface:

    import ./tests/non-nixos-scripts.nix { inherit pkgs; }
    -> { install-user-age-identity, nr-linux, nr-darwin }

  The unit tests of the non-NixOS helper scripts, each run against the
  packaged executable: tests/test_install_user_age_identity.py for
  gpgTools.installUserAgeIdentity, tests/nr-linux.sh for nixTools.nrLinux, and
  tests/nr-darwin.sh for nixTools.nrDarwin.
*/
{ pkgs }:
let
  gpgTools = import ../packages/gpg-tools.nix { inherit pkgs; };
  nixTools = import ../packages/nix-tools.nix { inherit pkgs; };
in
{
  install-user-age-identity =
    pkgs.runCommand "install-user-age-identity-tests"
      {
        nativeBuildInputs = [
          pkgs.python3
          pkgs.age
        ];
      }
      ''
        export PYTHONDONTWRITEBYTECODE=1
        mkdir -p scripts tests
        cp ${gpgTools.installUserAgeIdentity}/bin/install-user-age-identity scripts/install-user-age-identity
        chmod +x scripts/install-user-age-identity
        cp ${./test_install_user_age_identity.py} tests/test_install_user_age_identity.py
        python tests/test_install_user_age_identity.py
        touch $out
      '';

  nr-linux = pkgs.runCommand "nr-linux-tests" { nativeBuildInputs = [ pkgs.git ]; } ''
    ! grep -Eq '@[A-Z_]+@' ${nixTools.nrLinux}/bin/nr
    mkdir -p tests
    cp ${./nr-linux.sh} tests/nr-linux.sh
    bash tests/nr-linux.sh ${nixTools.nrLinux}/bin/nr
    touch $out
  '';

  nr-darwin = pkgs.runCommand "nr-darwin-tests" { nativeBuildInputs = [ pkgs.git ]; } ''
    ! grep -Eq '@[A-Z_]+@' ${nixTools.nrDarwin}/bin/nr
    mkdir -p tests
    cp ${./nr-darwin.sh} tests/nr-darwin.sh
    bash tests/nr-darwin.sh ${nixTools.nrDarwin}/bin/nr
    touch $out
  '';
}
