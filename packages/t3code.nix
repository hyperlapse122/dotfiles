{ pkgs }:

let
  inherit (pkgs) lib;
  source = builtins.fromJSON (builtins.readFile ./t3code-release.json);
  system = pkgs.stdenv.hostPlatform.system;
  pin =
    (source.platforms.${system}
      or (throw "packages/t3code-release.json pins no t3code-desktop asset for ${system}")
    ).desktop;

  pname = "t3code-desktop";
  inherit (source) version;

  src = pkgs.fetchurl {
    url = "https://github.com/pingdotgg/t3code/releases/download/${source.tag}/${pin.asset}";
    inherit (pin) hash;
  };

  appimageContents = pkgs.appimageTools.extract {
    inherit pname version src;
  };

  meta = {
    description = "Desktop GUI for coding agents like Claude Code and OMP (nightly)";
    homepage = "https://github.com/pingdotgg/t3code";
    license = lib.licenses.mit;
    sourceProvenance = [ lib.sourceTypes.binaryNativeCode ];
    platforms = lib.attrNames source.platforms;
    mainProgram = pname;
  };

  # The bundle name the nightly zip holds; a rename upstream fails the copy.
  appBundle = "T3 Code (Nightly).app";
in
if pkgs.stdenv.hostPlatform.isDarwin then
  pkgs.stdenvNoCC.mkDerivation {
    inherit
      pname
      version
      src
      meta
      ;

    nativeBuildInputs = [ pkgs.unzip ];
    sourceRoot = ".";

    # The bundle is notarized and signed with T3's Developer ID. Fixup's
    # stripping and shebang patching would change files that signature covers,
    # so fixup is skipped and the bundle is copied byte for byte.
    dontFixup = true;

    installPhase = ''
      runHook preInstall

      mkdir -p $out/Applications
      cp -R "${appBundle}" $out/Applications/

      runHook postInstall
    '';
  }
else
  pkgs.appimageTools.wrapType2 {
    inherit pname version src;

    # The AppImage updater runs whenever APPIMAGE is set, and the wrapper's exec
    # script exports any APPIMAGE the environment passes in, so the updater is
    # turned off explicitly; the version changes only through the flake.
    #
    # Agent sessions the bundled server starts inherit this bubblewrap sandbox:
    # its /etc lacks containers/, subuid, and subgid, and no_new_privs disables
    # the setuid newuidmap. A local rootless Podman started here builds its pause
    # process from that view, and the host's Podman service then joins it and
    # fails image pulls. Remote mode sends every podman and docker call to the
    # host service instead.
    extraBwrapArgs = [
      "--setenv T3CODE_DISABLE_AUTO_UPDATE 1"
      ''--setenv CONTAINER_HOST "unix://$XDG_RUNTIME_DIR/podman/podman.sock"''
      # The Antigravity ACP server that T3 downloads embeds an OpenSSL whose
      # default CA path, /opt/pyca/cryptography/openssl/cert.pem, does not exist
      # on NixOS. Without SSL_CERT_FILE every model request fails certificate
      # verification and the session hangs after session/prompt with no output.
      "--setenv SSL_CERT_FILE /etc/ssl/certs/ca-certificates.crt"
    ];

    extraInstallCommands = ''
      install -m 444 -D ${appimageContents}/t3code.desktop $out/share/applications/t3code.desktop
      substituteInPlace $out/share/applications/t3code.desktop \
        --replace-fail 'Exec=AppRun' 'Exec=${pname}'
      mkdir -p $out/share/icons
      cp -r ${appimageContents}/usr/share/icons/* $out/share/icons/
    '';

    inherit meta;
  }
