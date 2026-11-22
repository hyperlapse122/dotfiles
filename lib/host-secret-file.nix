hostName: fileName:
let
  file = ../secrets/hosts + "/${hostName}/${fileName}";
in
if builtins.pathExists file then file else null
