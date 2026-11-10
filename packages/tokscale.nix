{
  pkgs,
  hostName,
  tokenFile ? "/run/secrets/cli-auth/tokscale_token",
}:

let
  inherit (pkgs) lib;
  # Both values land inside single quotes in the script, and an empty host name
  # would report every run under a blank device.
  safeHostName = builtins.match "[A-Za-z0-9][A-Za-z0-9_-]*" hostName != null;
  safeTokenFile = builtins.match "/[A-Za-z0-9._/+-]+" tokenFile != null;
in
assert lib.assertMsg safeHostName
  "tokscale: hostName '${hostName}' is empty or not a plain host name";
assert lib.assertMsg safeTokenFile
  "tokscale: tokenFile '${tokenFile}' is not a plain absolute path";
pkgs.stdenvNoCC.mkDerivation {
  pname = "tokscale";
  version = "1";
  dontUnpack = true;
  # bun stays off the closure: the wrapper finds it on PATH at run time, so a
  # missing bun reaches the wrapper's exit-127 branch.
  installPhase = ''
    install -Dm755 ${../scripts/tokscale} $out/bin/tokscale
    substituteInPlace $out/bin/tokscale \
      --replace-fail '@HOST_NAME@' '${hostName}' \
      --replace-fail '@TOKEN_FILE@' '${tokenFile}'
    patchShebangs $out/bin/tokscale
  '';
  meta.mainProgram = "tokscale";
}
