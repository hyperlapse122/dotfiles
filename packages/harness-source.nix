{ repository, source }:
builtins.fetchTarball {
  url = "https://github.com/${repository}/archive/${source.rev}.tar.gz";
  inherit (source) sha256;
}
