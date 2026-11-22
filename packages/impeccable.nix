{ pkgs, inputs }:

pkgs.rustPlatform.buildRustPackage {
  pname = "impeccable";
  version = pkgs.lib.trim (builtins.readFile "${inputs.impeccable}/ENGINE_VERSION");
  src = inputs.impeccable;
  cargoLock.lockFile = "${inputs.impeccable}/Cargo.lock";
  cargoBuildFlags = [
    "-p"
    "impeccable"
  ];
  doCheck = false;
  doInstallCheck = true;

  nativeBuildInputs = [ pkgs.makeWrapper ];
  postInstall = ''
    wrapProgram "$out/bin/impeccable" --set IMPECCABLE_NO_TELEMETRY 1
  '';
  installCheckPhase = ''
    runHook preInstallCheck
    export HOME="$TMPDIR/home"
    mkdir -p "$HOME" clean findings
    printf '%s\n' '.title { font-family: Georgia; }' > clean/page.css
    printf '%s\n' '.title { font-family: Inter; }' > findings/page.css
    "$out/bin/impeccable" detect --help
    "$out/bin/impeccable" detect --no-config clean
    status=0
    "$out/bin/impeccable" detect --no-config --json findings > report || status=$?
    cat report
    test "$status" -eq 2
    grep -F 'overused-font' report
    runHook postInstallCheck
  '';

  meta = {
    description = "Offline UI anti-pattern detection for source files";
    homepage = "https://github.com/pbakaus/impeccable";
    license = pkgs.lib.licenses.asl20;
    mainProgram = "impeccable";
  };
}
