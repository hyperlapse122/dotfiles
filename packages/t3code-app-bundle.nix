let
  version = (builtins.fromJSON (builtins.readFile ./t3code-release.json)).version;
in
if builtins.match ".*-nightly\\..*" version != null then
  "T3 Code (Nightly).app"
else
  "T3 Code (Beta).app"
