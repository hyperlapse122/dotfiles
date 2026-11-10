{
  pkgs,
  syntheticKeyFile ? "/run/secrets/cli-auth/synthetic_api_key",
  exaKeyFile ? "/run/secrets/cli-auth/exa_api_key",
  openrouterKeyFile ? "/run/secrets/cli-auth/openrouter_api_key",
}:

let
  inherit (pkgs) lib stdenv;
  source = builtins.fromJSON (builtins.readFile ./pi-release.json);
  system = stdenv.hostPlatform.system;
  pin =
    source.platforms.${system} or (throw "packages/pi-release.json pins no pi asset for ${system}");
  # Each path lands inside single quotes in a shell script or in a JavaScript
  # string literal.
  plainPath = path: builtins.match "/[A-Za-z0-9._/+-]+" path != null;
in
assert lib.assertMsg (plainPath syntheticKeyFile)
  "pi: syntheticKeyFile '${syntheticKeyFile}' is not a plain absolute path";
assert lib.assertMsg (plainPath exaKeyFile)
  "pi: exaKeyFile '${exaKeyFile}' is not a plain absolute path";
assert lib.assertMsg (plainPath openrouterKeyFile)
  "pi: openrouterKeyFile '${openrouterKeyFile}' is not a plain absolute path";
stdenv.mkDerivation {
  pname = "pi";
  inherit (source) version;

  src = pkgs.fetchurl { inherit (pin) url hash; };

  # Each tarball holds one pi/ directory: the binary and the themes, docs,
  # wasm, and native addons it resolves from its own directory, so the
  # directory is installed whole.
  sourceRoot = "pi";

  # Pi is a Bun-compiled executable whose JavaScript payload rides at the end
  # of the file, so stripping it leaves the bare Bun runtime. On Linux it and
  # its X11 clipboard addon are patched to the store's loader. On macOS
  # nothing is fixed up, so the binary's code signature stays valid.
  dontStrip = true;
  dontFixup = stdenv.hostPlatform.isDarwin;
  nativeBuildInputs = [
    pkgs.writableTmpDirAsHomeHook
  ]
  ++ lib.optional stdenv.hostPlatform.isLinux pkgs.autoPatchelfHook;
  buildInputs = lib.optionals stdenv.hostPlatform.isLinux [
    stdenv.cc.cc.lib
    pkgs.libxcb
  ];

  dontConfigure = true;
  dontBuild = true;

  installPhase = ''
    runHook preInstall

    mkdir -p $out/libexec
    cp -R . $out/libexec/pi
    install -Dm755 ${../scripts/pi} $out/bin/pi
    substituteInPlace $out/bin/pi \
      --replace-fail '@PI@' "$out/libexec/pi/pi"
    install -Dm755 ${../scripts/pi-provider-key} $out/bin/pi-synthetic-key
    substituteInPlace $out/bin/pi-synthetic-key \
      --replace-fail '@KEY_VAR@' 'SYNTHETIC_API_KEY' \
      --replace-fail '@KEY_FILE@' '${syntheticKeyFile}'
    install -Dm755 ${../scripts/pi-provider-key} $out/bin/pi-openrouter-key
    substituteInPlace $out/bin/pi-openrouter-key \
      --replace-fail '@KEY_VAR@' 'OPENROUTER_API_KEY' \
      --replace-fail '@KEY_FILE@' '${openrouterKeyFile}'
    patchShebangs $out/bin/pi $out/bin/pi-synthetic-key $out/bin/pi-openrouter-key

    install -Dm755 ${../scripts/pi-state} $out/bin/pi-state
    substituteInPlace $out/bin/pi-state --replace-fail '/usr/bin/env python3' '${pkgs.python3}/bin/python3'
    substituteInPlace $out/bin/pi \
      --replace-fail '@STATE@' "$out/bin/pi-state" \
            --replace-fail '@KEY@' '${syntheticKeyFile}'
    runHook postInstall
  '';

  doInstallCheck = true;
  nativeInstallCheckInputs = [ pkgs.versionCheckHook ];
  versionCheckKeepEnvironment = [ "HOME" ];

  meta = {
    description = "Minimal terminal coding agent";
    homepage = "https://github.com/earendil-works/pi";
    license = lib.licenses.mit;
    sourceProvenance = [ lib.sourceTypes.binaryNativeCode ];
    platforms = lib.attrNames source.platforms;
    mainProgram = "pi";
  };
}
