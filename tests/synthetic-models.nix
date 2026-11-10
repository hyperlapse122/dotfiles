/*
  Check interface:

    import ./tests/synthetic-models.nix { inherit pkgs; }

  Pins the shape of home/h82/agents/synthetic-models.nix, the one source of
  every Synthetic model the repository uses: each `id` starts with `hf:` and
  its family is the one its org maps to, every role an entry has (GLM-5.3 and
  GLM-5.3 Flash have none) runs at `low`, `high`, or `max`, the efforts these
  models offer (never `medium`), each lineage pattern matches its own `id` and its
  first capture group is a version under both Nix `builtins.match` and Python
  `re.fullmatch`, and the top-level selections name existing entries. It also
  reads the committed catalog snapshot, home/h82/agents/synthetic-catalog.json,
  and fails on a source `id` the snapshot lacks and on a role effort or default
  effort the snapshot does not list for that model. Every problem is listed
  from the builder before it fails.
*/
{ pkgs }:
let
  inherit (pkgs) lib;

  source = import ../home/h82/agents/synthetic-models.nix;
  snapshot = builtins.fromJSON (builtins.readFile ../home/h82/agents/synthetic-catalog.json);
  snapshotRows = lib.listToAttrs (map (row: lib.nameValuePair row.id row) snapshot.data);

  # Org to family, as the shared instructions map a model ID.
  orgFamilies = {
    zai-org = "glm";
    deepseek-ai = "deepseek";
    Qwen = "qwen";
  };

  selections = [
    "defaultModel"
    "textGeneration"
  ];

  entryNames = lib.subtractLists selections (lib.attrNames source);
  entries = lib.genAttrs entryNames (name: source.${name});

  # The efforts these models offer.
  efforts = [
    "low"
    "high"
    "max"
  ];
  offered = "low, high, or max";

  versionShape = "[0-9]+([.][0-9]+)?";

  capturedVersion =
    entry:
    let
      groups = builtins.match (entry.lineage or "") (entry.id or "");
    in
    if groups == null || groups == [ ] then null else builtins.head groups;

  # The efforts the snapshot lists for an entry, or null when it lacks the id.
  snapshotEfforts =
    entry:
    let
      row = snapshotRows.${entry.id or ""} or null;
    in
    if row == null then null else row.reasoning_parameters.efforts or [ ];

  snapshotProblems =
    name: entry:
    let
      listed = snapshotEfforts entry;
      used =
        (lib.mapAttrsToList (role: effort: {
          what = "role ${role}";
          inherit effort;
        }) (entry.roles or { }))
        ++ lib.optional (entry ? defaultEffort) {
          what = "defaultEffort";
          effort = entry.defaultEffort;
        };
    in
    if listed == null then
      [ "${name}: id `${entry.id or ""}` is missing from home/h82/agents/synthetic-catalog.json" ]
    else
      map (
        use:
        "${name}: ${use.what} runs at effort `${toString use.effort}`, which the snapshot does not list (${lib.concatStringsSep ", " listed})"
      ) (lib.filter (use: !lib.elem use.effort listed) used);

  entryProblems =
    name: entry:
    let
      id = entry.id or "";
      org = builtins.match "hf:([^/]+)/.+" id;
      version = capturedVersion entry;
    in
    lib.optional (!lib.hasPrefix "hf:" id) "${name}: id `${id}` does not start with hf:"
    ++ lib.optional (
      org == null || (orgFamilies.${builtins.head org} or "unknown") != (entry.family or "")
    ) "${name}: family `${entry.family or ""}` is not the family of the org of `${id}`"
    ++ lib.optional (
      version == null
    ) "${name}: lineage `${entry.lineage or ""}` does not match `${id}` with a capture"
    ++ lib.optional (
      version != null && builtins.match versionShape version == null
    ) "${name}: lineage captures `${version}`, not a version"
    ++ lib.mapAttrsToList (
      role: effort: "${name}: role ${role} runs at effort `${toString effort}`, not ${offered}"
    ) (lib.filterAttrs (_: effort: !lib.elem effort efforts) (entry.roles or { }))
    ++ lib.optional (
      (entry.defaultEffort or "medium") == "medium"
    ) "${name}: defaultEffort is missing or medium";

  problems =
    lib.optional (entries == { }) "no model entries"
    ++ lib.concatLists (lib.mapAttrsToList entryProblems entries)
    ++ lib.concatLists (lib.mapAttrsToList snapshotProblems entries)
    ++ map (selection: "${selection} does not name a model entry") (
      lib.filter (selection: !(entries ? ${source.${selection} or ""})) selections
    );

  # The model-watch script matches catalog IDs with Python re.fullmatch and
  # takes the version from group 1, so the patterns must agree there too.
  pythonCases = pkgs.writeText "synthetic-models-lineage.json" (
    builtins.toJSON (
      lib.mapAttrsToList (name: entry: {
        inherit name;
        id = entry.id or "";
        lineage = entry.lineage or "";
        version = capturedVersion entry;
      }) entries
    )
  );
in
pkgs.runCommand "synthetic-models-tests" { nativeBuildInputs = [ pkgs.python3 ]; } ''
  fail=0

  for problem in ${lib.escapeShellArgs problems}; do
    echo "synthetic-models: $problem" >&2
    fail=1
  done

  python3 -I - ${pythonCases} <<'EOF' || fail=1
  import json, re, sys

  failed = False
  for case in json.load(open(sys.argv[1])):
      match = re.fullmatch(case["lineage"], case["id"])
      found = match.group(1) if match and match.re.groups else None
      if found != case["version"]:
          print(f"synthetic-models: {case['name']}: Python captures {found!r}, "
                f"Nix captures {case['version']!r}", file=sys.stderr)
          failed = True
  sys.exit(1 if failed else 0)
  EOF

  [ "$fail" = 0 ] || exit 1
  touch $out
''
