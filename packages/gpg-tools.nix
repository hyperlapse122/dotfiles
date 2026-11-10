{ pkgs }:

let
  pinentryKeyring = import ./pinentry-keyring.nix { inherit pkgs; };

  gitGpg = pkgs.stdenvNoCC.mkDerivation {
    pname = "gpg-git";
    version = "1";
    dontUnpack = true;
    nativeBuildInputs = [ pkgs.makeWrapper ];
    nativeInstallCheckInputs = [ pkgs.python3 ];
    installPhase = ''
      install -Dm644 ${../scripts/gpg-git} $out/libexec/gpg-git.py
      makeWrapper ${pkgs.python3}/bin/python3 $out/bin/gpg-git \
        --add-flags "$out/libexec/gpg-git.py" \
        --prefix PATH : ${pkgs.lib.makeBinPath [ pkgs.gnupg ]}
    '';
    doInstallCheck = true;
    installCheckPhase = ''
      python3 ${../tests/gpg-git.py} $out/libexec/gpg-git.py
      $out/bin/gpg-git --version
    '';
    meta.mainProgram = "gpg-git";
  };

  restoreAgeIdentity = pkgs.stdenvNoCC.mkDerivation {
    pname = "restore-age-identity";
    version = "1";
    dontUnpack = true;
    nativeBuildInputs = [ pkgs.python3 ];
    installPhase = ''
      install -Dm755 ${../scripts/restore-age-identity} $out/bin/restore-age-identity
      substituteInPlace $out/bin/restore-age-identity \
        --replace-fail '@AGE_KEYGEN@' '${pkgs.age}/bin/age-keygen'
      patchShebangs $out/bin/restore-age-identity
    '';
    meta.mainProgram = "restore-age-identity";
  };

  # The non-NixOS counterpart: installs into the invoking user's home, so it
  # needs no root and no fixed system path.
  installUserAgeIdentity = pkgs.stdenvNoCC.mkDerivation {
    pname = "install-user-age-identity";
    version = "1";
    dontUnpack = true;
    nativeBuildInputs = [ pkgs.python3 ];
    installPhase = ''
      install -Dm755 ${../scripts/install-user-age-identity} $out/bin/install-user-age-identity
      substituteInPlace $out/bin/install-user-age-identity \
        --replace-fail '@AGE_KEYGEN@' '${pkgs.age}/bin/age-keygen'
      patchShebangs $out/bin/install-user-age-identity
    '';
    meta.mainProgram = "install-user-age-identity";
  };
in
{
  inherit
    pinentryKeyring
    gitGpg
    restoreAgeIdentity
    installUserAgeIdentity
    ;
}
