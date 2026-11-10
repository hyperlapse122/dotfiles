{ pkgs, omp }:
let
  catalogs = import ./omp-model-catalogs.nix;
  synthetic = pkgs.writeText "omp-synthetic-catalog.json" (builtins.toJSON catalogs.synthetic);
  openrouter = pkgs.writeText "omp-openrouter-catalog.json" (builtins.toJSON catalogs.openrouter);
in
pkgs.runCommand "omp-declared-models.json" { nativeBuildInputs = [ pkgs.python3 ]; } ''
  export HOME=$TMPDIR/home
  mkdir -p "$HOME"
  # Darwin builders can reach the network. Force discovery to fail locally so
  # online-only rows cannot be mistaken for bundled rows and get only overrides.
  # This environment applies only to the build-time bundled catalog probe.
  export HTTP_PROXY=http://127.0.0.1:1 HTTPS_PROXY=http://127.0.0.1:1
  export ALL_PROXY=http://127.0.0.1:1 NO_PROXY=
  SYNTHETIC_API_KEY=sk-fake-synthetic OPENROUTER_API_KEY=sk-fake-openrouter \
    ${omp}/bin/omp models --json > bundled.json
  python3 -I ${./omp-declarations.py} \
    ${synthetic} ${openrouter} bundled.json \
    ${omp}/bin/omp-synthetic-key ${omp}/bin/omp-openrouter-key $out
''
