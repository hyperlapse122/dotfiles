{ pkgs }:

pkgs.buildNpmPackage (finalAttrs: {
  pname = "ctx7";
  version = "0.12.2";
  src = pkgs.fetchurl {
    url = "https://registry.npmjs.org/ctx7/-/ctx7-${finalAttrs.version}.tgz";
    hash = "sha512-HSq+MW5lLbDxcnKx7aloyFVoV5SZ97WTnuwJBXzMgbOnSoleqlrSF5E2OTrq3S3k6zytwuty22BwIV2PblDSKw==";
  };
  nodejs = pkgs.nodejs_24;
  npmDepsHash = "sha256-yP1s7kzsmsXMmoZ9AFBTI//PwfGZL7Nslg8H6O8dlGc=";
  postPatch = ''
    cp ${./ctx7-package-lock.json} package-lock.json
    # The tarball already contains the compiled CLI. Lock runtime dependencies only.
    ${pkgs.jq}/bin/jq 'del(.devDependencies)' package.json > runtime.json
    mv runtime.json package.json
  '';
  dontNpmBuild = true;
  npmPackFlags = [ "--ignore-scripts" ];

  postInstall = ''
    wrapProgram "$out/bin/ctx7" --set CTX7_TELEMETRY_DISABLED 1
  '';
  doInstallCheck = true;
  installCheckPhase = ''
    runHook preInstallCheck
    export HOME="$TMPDIR/home"
    mkdir -p "$HOME"
    test "$("$out/bin/ctx7" --version)" = "${finalAttrs.version}"
    "$out/bin/ctx7" library --help >/dev/null
    "$out/bin/ctx7" docs --help >/dev/null
    runHook postInstallCheck
  '';

  meta = {
    description = "Context7 documentation lookup CLI";
    homepage = "https://github.com/upstash/context7";
    license = pkgs.lib.licenses.mit;
    mainProgram = "ctx7";
  };
})
