{
  pkgs,
  backend ? if pkgs.stdenv.hostPlatform.isDarwin then "mlx" else "openrouter",
  openrouterKeyFile ? null,
}:

let
  lib = pkgs.lib;
  runtime = import ./decide-runtime.nix { inherit pkgs backend; };
  pins = builtins.fromJSON (builtins.readFile ./decide-runtime-pins.json);
  nativeModels = lib.mapAttrs (_: pin: { inherit (pin) model revision; }) pins;
  model =
    {
      mlx = pins.darwin.model;
      cuda = pins.linux.model;
      openrouter = "typesafe/jev-1.14";
    }
    .${backend};
  loader = if backend == "mlx" then runtime.loaders.darwin else runtime.loaders.linux;
  pythonLiteral = value: if value == null then "None" else builtins.toJSON (toString value);
  mcpPython = pkgs.python314.withPackages (p: [
    p.aiohttp
    p.mcp
  ]);
  testPython = pkgs.python314.withPackages (p: [
    p.aiohttp
    p.click
    p.jsonschema
    p.pillow
  ]);
  usage = lib.getExe pkgs.usage;
in
pkgs.stdenvNoCC.mkDerivation {
  pname = "decide";
  version = "1";
  src = lib.cleanSource ./decide;
  nativeBuildInputs = [
    pkgs.installShellFiles
    pkgs.makeWrapper
  ];
  dontBuild = true;
  installPhase = ''
    runHook preInstall
    mkdir -p "$out/lib/decide" "$out/bin" "$out/share/licenses/decide"
    cp -R decide "$out/lib/decide/"
    cp NOTICE "$out/share/licenses/decide/NOTICE"
    ${lib.optionalString (backend != "openrouter") ''
      cp ${if backend == "mlx" then runtime.loaders.darwinLicense else runtime.loaders.linuxLicense} \
        "$out/share/licenses/decide/clef-LICENSE"
    ''}
    cat > "$out/lib/decide/decide/_package.py" <<'EOF'
    BACKEND = ${pythonLiteral backend}
    MODEL = ${pythonLiteral model}
    LOADER = ${pythonLiteral (if backend == "openrouter" then null else loader)}
    KEY_FILE = ${pythonLiteral openrouterKeyFile}
    NATIVE_MODELS = ${builtins.toJSON nativeModels}
    EOF
    ${runtime.python}/bin/python3 -I -m compileall -q --invalidation-mode unchecked-hash "$out/lib/decide"
    makeWrapper ${runtime.python}/bin/python3 "$out/bin/decide" \
      --prefix PYTHONPATH : "$out/lib/decide" --add-flags "-P -m decide"
    makeWrapper ${mcpPython}/bin/python3 "$out/bin/decide-mcp" \
      --prefix PYTHONPATH : "$out/lib/decide" --add-flags "-P -m decide.mcp"

    mkdir -p "$out/share/decide"
    spec="$out/share/decide/decide.usage.kdl"
    PYTHONPATH="$out/lib/decide" ${runtime.python}/bin/python3 -B -P usage-spec.py > "$spec"
    for shell in bash zsh; do
      ${usage} generate completion "$shell" decide --file "$spec" --usage-bin ${usage} > "decide.$shell"
    done
    installShellCompletion --cmd decide --bash decide.bash --zsh decide.zsh
    runHook postInstall
  '';
  doInstallCheck = true;
  installCheckPhase = ''
    runHook preInstallCheck
    export HOME="$TMPDIR/home" XDG_CONFIG_HOME="$TMPDIR/config" PYTHONDONTWRITEBYTECODE=1
    export PYTHONPATH="$out/lib/decide" DECIDE_TEST_CLI="$out/bin/decide" DECIDE_TEST_MCP="$out/bin/decide-mcp"
    mkdir -p "$HOME"
    "$out/bin/decide" --help > /dev/null
    test -s "$out/share/bash-completion/completions/decide.bash"
    test -s "$out/share/zsh/site-functions/_decide"
    spec="$out/share/decide/decide.usage.kdl"
    test "$(${usage} complete-word --file "$spec" -- decide ju)" = judge
    test "$(${usage} complete-word --file "$spec" -- decide serve --no-p)" = --no-preload
    ${testPython}/bin/python3 ${../tests/decide-contract.py}
    ${testPython}/bin/python3 ${../tests/decide-local.py}
    ${testPython}/bin/python3 ${../tests/decide-ipc.py}
    runHook postInstallCheck
  '';
  meta = {
    description = "Human CLI and private Decisions service";
    mainProgram = "decide";
    platforms = lib.platforms.unix;
  };
}
