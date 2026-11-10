# The shared part of a package built from an npm tarball that ships its built
# dist/ and no lock file. `release` is the JSON file scripts/npm-release pins
# the tarball in, and `lockDirectory` holds the package-lock.json it writes for
# the package.json without devDependencies, which postPatch matches. Returns
# the release and the buildNpmPackage arguments the package extends.
{
  pkgs,
  pname,
  release,
  lockDirectory,
}:
let
  source = builtins.fromJSON (builtins.readFile release);
in
{
  inherit source;
  attrs = {
    inherit pname;
    inherit (source) version;
    src = pkgs.fetchurl { inherit (source) url hash; };
    npmDeps = pkgs.fetchNpmDeps {
      name = "${pname}-${source.version}-npm-deps";
      src = lockDirectory;
      hash = source.npmDepsHash;
    };

    nativeBuildInputs = [ pkgs.jq ];
    postPatch = ''
      cp ${lockDirectory + "/package-lock.json"} package-lock.json
      jq 'del(.devDependencies)' package.json > package.json.tmp
      mv package.json.tmp package.json
    '';
    dontNpmBuild = true;
    npmFlags = [ "--ignore-scripts" ];
  };
}
