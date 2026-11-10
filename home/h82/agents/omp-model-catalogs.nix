let
  synthetic = builtins.fromJSON (builtins.readFile ./synthetic-catalog.json);
  openrouter = builtins.fromJSON (builtins.readFile ./openrouter-catalog.json);
  openrouterAllow = [ "^openrouter/.*$" ];
  openrouterExclude = [ "openrouter/bodybuilder" ];
  openrouterData = builtins.filter (
    row:
    builtins.any (pattern: builtins.match pattern row.id != null) openrouterAllow
    && !(builtins.elem row.id openrouterExclude)
  ) openrouter.data;
in
{
  inherit synthetic;
  openrouter = openrouter // {
    data = openrouterData;
  };
  disabledProviders = [
    "omp-managed"
    "openai-codex"
    "google-antigravity"
  ];
  # OMP uses path globs: model IDs themselves contain slashes. Synthetic rows
  # are listed exactly because OMP's bundled catalog can carry models the live
  # catalog has retired, and a glob would offer those too.
  patterns =
    map (row: "synthetic/${row.id}") synthetic.data ++ map (row: "openrouter/${row.id}") openrouterData;
}
