{
  pkgs,
  syntheticKeyFile ? "/run/secrets/cli-auth/synthetic_api_key",
  openrouterKeyFile ? "/run/secrets/cli-auth/openrouter_api_key",
}:

let
  inherit (pkgs) lib stdenv;
  source = builtins.fromJSON (builtins.readFile ./omp-release.json);
  system = stdenv.hostPlatform.system;
  pin = source.platforms.${system} or (throw "omp: no native release pinned for ${system}");
  plainPath = path: builtins.match "/[A-Za-z0-9._/+-]+" path != null;
in
assert lib.assertMsg (plainPath syntheticKeyFile)
  "omp: syntheticKeyFile must be a plain absolute path";
assert lib.assertMsg (plainPath openrouterKeyFile)
  "omp: openrouterKeyFile must be a plain absolute path";
stdenv.mkDerivation {
  pname = "omp";
  inherit (source) version;

  src = pkgs.fetchurl { inherit (pin) url hash; };
  dontUnpack = true;
  dontConfigure = true;
  dontBuild = true;

  # These are single Bun executables, not archives. Stripping loses the
  # appended application; Darwin fixups would invalidate its signature.
  dontStrip = true;
  dontFixup = stdenv.hostPlatform.isDarwin;
  nativeBuildInputs = [
    pkgs.writableTmpDirAsHomeHook
  ]
  ++ lib.optional stdenv.hostPlatform.isLinux pkgs.autoPatchelfHook;
  buildInputs = lib.optionals stdenv.hostPlatform.isLinux [ stdenv.cc.cc.lib ];

  installPhase = ''
    runHook preInstall
    install -Dm755 $src $out/libexec/omp/omp
    install -Dm755 ${../scripts/omp} $out/bin/omp
    substituteInPlace $out/bin/omp --replace-fail '@OMP@' "$out/libexec/omp/omp"
    install -Dm755 ${../scripts/omp-provider-key} $out/bin/omp-synthetic-key
    substituteInPlace $out/bin/omp-synthetic-key \
      --replace-fail '@KEY_VAR@' 'SYNTHETIC_API_KEY' \
      --replace-fail '@KEY_FILE@' ${lib.escapeShellArg syntheticKeyFile}
    install -Dm755 ${../scripts/omp-provider-key} $out/bin/omp-openrouter-key
    substituteInPlace $out/bin/omp-openrouter-key \
      --replace-fail '@KEY_VAR@' 'OPENROUTER_API_KEY' \
      --replace-fail '@KEY_FILE@' ${lib.escapeShellArg openrouterKeyFile}
    patchShebangs $out/bin
    runHook postInstall
  '';

  doInstallCheck = true;
  nativeInstallCheckInputs = [ pkgs.versionCheckHook ];
  versionCheckKeepEnvironment = [ "HOME" ];
  postInstallCheck = ''
    "$out/bin/omp" --help > /dev/null
    # Enter print mode without credentials or a network request. The expected
    # model-resolution failure proves the bundled application starts headlessly.
    if "$out/bin/omp" --no-extensions --no-session \
      --model u1-nonexistent-provider/u1-nonexistent-model -p smoke > stdout 2> stderr; then
      echo "omp unexpectedly accepted the nonexistent smoke-test model" >&2
      exit 1
    fi
    grep -F 'Model "u1-nonexistent-provider/u1-nonexistent-model" not found' stderr
    ${lib.optionalString stdenv.hostPlatform.isLinux ''
      test "$(patchelf --print-interpreter "$out/libexec/omp/omp")" = ${lib.escapeShellArg stdenv.cc.bintools.dynamicLinker}
    ''}
    ${lib.optionalString stdenv.hostPlatform.isDarwin ''
      # A byte-identical installed executable preserves the upstream signature.
      cmp -s "$src" "$out/libexec/omp/omp"
    ''}
  '';

  meta = {
    description = "Oh My Pi terminal coding agent";
    homepage = "https://github.com/can1357/oh-my-pi";
    license = lib.licenses.mit;
    sourceProvenance = [ lib.sourceTypes.binaryNativeCode ];
    platforms = lib.attrNames source.platforms;
    mainProgram = "omp";
  };
}
