{
  pkgs,
  syntheticKeyFile ? "/run/secrets/cli-auth/synthetic_api_key",
  exaKeyFile ? "/run/secrets/cli-auth/exa_api_key",
  anthropicKeyFile ? "/run/secrets/cli-auth/anthropic_api_key",
}:

let
  inherit (pkgs) lib stdenv;
  source = builtins.fromJSON (builtins.readFile ./pi-release.json);
  runtime = pkgs.callPackage ./pi-runtime.nix {
    source = import ./harness-source.nix {
      repository = "earendil-works/pi";
      inherit (source) source;
    };
  };
  # Each path lands inside single quotes in a shell script or in a JavaScript
  # string literal.
  plainPath = path: builtins.match "/[A-Za-z0-9._/+-]+" path != null;
in
assert lib.assertMsg (plainPath syntheticKeyFile)
  "pi: syntheticKeyFile '${syntheticKeyFile}' is not a plain absolute path";
assert lib.assertMsg (plainPath exaKeyFile)
  "pi: exaKeyFile '${exaKeyFile}' is not a plain absolute path";
assert lib.assertMsg (plainPath anthropicKeyFile)
  "pi: anthropicKeyFile '${anthropicKeyFile}' is not a plain absolute path";
assert lib.assertMsg (
  runtime.version == source.version
) "pi: source version does not match the release pin";
stdenv.mkDerivation {
  pname = "pi";
  inherit (source) version;

  dontUnpack = true;
  nativeBuildInputs = [ pkgs.writableTmpDirAsHomeHook ];

  dontConfigure = true;
  dontBuild = true;

  installPhase = ''
    runHook preInstall

    mkdir -p $out/libexec/pi
    ln -s ${runtime}/bin/pi $out/libexec/pi/pi
    install -Dm755 ${../scripts/pi} $out/bin/pi
    substituteInPlace $out/bin/pi \
      --replace-fail '@PI@' "$out/libexec/pi/pi"
    patchShebangs $out/bin/pi

    install -Dm755 ${../scripts/pi-state} $out/bin/pi-state
    substituteInPlace $out/bin/pi-state --replace-fail '/usr/bin/env python3' '${pkgs.python3}/bin/python3'
    substituteInPlace $out/bin/pi \
      --replace-fail '@NODE@' '${lib.getExe pkgs.nodejs_22}' \
      --replace-fail '@PI_ARGS@' '${runtime}/lib/pi/node_modules/@earendil-works/pi-coding-agent/dist/cli/args.js' \
      --replace-fail '@STATE@' "$out/bin/pi-state" \
      --replace-fail '@KEY@' '${syntheticKeyFile}' \
      --replace-fail '@EXA_KEY@' '${exaKeyFile}' \
      --replace-fail '@ANTHROPIC_KEY@' '${anthropicKeyFile}'
    runHook postInstall
  '';

  doInstallCheck = true;
  nativeInstallCheckInputs = [ pkgs.versionCheckHook ];
  versionCheckKeepEnvironment = [ "HOME" ];

  passthru = {
    inherit (runtime) modelCatalog;
    nodeModules = "${runtime}/lib/pi/node_modules";
  };

  meta = {
    description = "Minimal terminal coding agent";
    homepage = "https://github.com/earendil-works/pi";
    license = lib.licenses.mit;
    sourceProvenance = runtime.meta.sourceProvenance;
    platforms = lib.attrNames source.platforms;
    mainProgram = "pi";
  };
}
