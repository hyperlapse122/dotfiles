{ pkgs, configurations }:
let
  # Counted over production configurations: a bootstrap output never
  # joins the tailnet as the router the production host is.
  routers = configurations.withTrait "my.tailscale.advertiseRoutes" (
    config: config.my.tailscale.advertiseRoutes
  );
  advertisers = map (entry: entry.name) (pkgs.lib.filter (entry: !entry.bootstrap) routers.enabled);
in
pkgs.runCommand "tailscale-single-router-tests" { } ''
  ${configurations.guard}
  ${routers.guard}
  ${
    if pkgs.lib.length advertisers > 1 then
      ''
        echo "more than one host advertises Tailscale subnet routes: ${pkgs.lib.concatStringsSep ", " advertisers}" >&2
        exit 1
      ''
    else
      ""
  }
  touch $out
''
