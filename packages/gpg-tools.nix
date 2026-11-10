{ pkgs }:

let
  linuxPinentryCard = pkgs.stdenvNoCC.mkDerivation {
    pname = "pinentry-card-wrapper";
    version = "1";
    dontUnpack = true;
    nativeBuildInputs = [ pkgs.python3 ];
    installPhase = ''
      install -Dm755 ${../scripts/pinentry-card} $out/bin/pinentry-card
      ln -s pinentry-card $out/bin/pinentry
      substituteInPlace $out/bin/pinentry-card \
        --replace-fail '@PINENTRY_QT@' '${pkgs.pinentry-qt}/bin/pinentry-qt' \
        --replace-fail '@PINENTRY_CURSES@' '${pkgs.pinentry-curses}/bin/pinentry-curses' \
        --replace-fail '@SECRET_TOOL@' '${pkgs.libsecret}/bin/secret-tool'
      patchShebangs $out/bin/pinentry-card
    '';
    meta.mainProgram = "pinentry-card";
  };

  # The darwin build: scripts/pinentry-card-darwin in front of a darwin render
  # of the shared proxy, which it runs as its child.  The shared script is
  # rendered here rather than edited, because its content feeds the Linux
  # store path.  `pinentryMac` is the delegate's executable path, so the
  # checks can render this on Linux with a stand-in.
  mkDarwinPinentryCard =
    { pinentryMac }:
    pkgs.stdenvNoCC.mkDerivation {
      pname = "pinentry-card-wrapper";
      version = "1";
      dontUnpack = true;
      nativeBuildInputs = [ pkgs.python3 ];
      installPhase = ''
        install -Dm644 ${../scripts/pinentry-card} $out/libexec/pinentry-card/pinentry-card-proxy
        substituteInPlace $out/libexec/pinentry-card/pinentry-card-proxy \
          --replace-fail '@PINENTRY_QT@' '${pinentryMac}' \
          --replace-fail '@PINENTRY_CURSES@' '${pinentryMac}' \
          --replace-fail '@SECRET_TOOL@' '/usr/bin/security' \
          --replace-fail 'IS_LINUX = True' 'IS_LINUX = False' \
          --replace-fail 'KEYRING_LOOKUP_TIMEOUT = 30' 'KEYRING_LOOKUP_TIMEOUT = 5' \
          --replace-fail 'KEYRING_BACKEND = "secret-tool"' 'KEYRING_BACKEND = "security"'
        install -Dm755 ${../scripts/pinentry-card-darwin} $out/bin/pinentry-card
        ln -s pinentry-card $out/bin/pinentry
        substituteInPlace $out/bin/pinentry-card \
          --replace-fail '@PINENTRY_CARD_PROXY@' "$out/libexec/pinentry-card/pinentry-card-proxy" \
          --replace-fail '@SECURITY@' '/usr/bin/security'
        patchShebangs $out/bin/pinentry-card
      '';
      meta.mainProgram = "pinentry-card";
    };

  pinentryCard =
    if pkgs.stdenv.hostPlatform.isDarwin then
      mkDarwinPinentryCard { pinentryMac = pkgs.lib.getExe pkgs.pinentry_mac; }
    else
      linuxPinentryCard;

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
    pinentryCard
    gitGpg
    mkDarwinPinentryCard
    restoreAgeIdentity
    installUserAgeIdentity
    ;
}
