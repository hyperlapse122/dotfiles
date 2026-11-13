/*
  Plugin skills, enumerated from the pinned plugin sources.

  `sources` is an attribute set of plugin name to `{ src, plugin, ... }`, the
  shape `agent-plugins.nix` declares. Every consumer reads these functions, so
  a plugin added to the sources reaches the plugin skills directory and the
  Antigravity CLI install without Antigravity-specific work.

  - `skills { sources, sharedNames }`: skill name to store path for every
    plugin. A directory counts as a skill when it holds `SKILL.md`. Stops
    evaluation when two plugins, or a plugin and a shared skill, use one name.
  - `problems { sources, sharedNames }`: the messages `skills` stops with.
  - `directory skills`: one store directory holding a link per skill.
  - `agyInstall { agy, sources }`: the Antigravity CLI installation and enable
    commands for each plugin.
*/
{ lib, pkgs }:
let
  # A source given as a path, such as a test fixture, stays a path: turning it
  # into a string copies it to the store, and the read-only evaluation of
  # nix flake check --no-build computes that copy without writing it, so the
  # directory reads below would find nothing. A flake input is already in the
  # store and is used as its string.
  skillsDir = src: (if builtins.isPath src then src else "${src}") + "/skills";

  skillsOf =
    spec:
    let
      dir = skillsDir spec.src;
    in
    lib.optionalAttrs (builtins.pathExists dir) (
      lib.filterAttrs (
        name: type: type == "directory" && builtins.pathExists (dir + "/${name}/SKILL.md")
      ) (builtins.readDir dir)
    );

  owners =
    sources:
    lib.groupBy (entry: entry.name) (
      lib.concatMap (
        plugin: map (name: { inherit plugin name; }) (lib.attrNames (skillsOf sources.${plugin}))
      ) (lib.attrNames sources)
    );

  problems =
    { sources, sharedNames }:
    let
      byName = owners sources;
      duplicated = lib.filterAttrs (_: entries: lib.length entries > 1) byName;
      shadowing = lib.filter (name: byName ? ${name}) sharedNames;
    in
    lib.mapAttrsToList (
      name: entries:
      "${name} is provided by plugins ${lib.concatMapStringsSep ", " (e: e.plugin) entries}"
    ) duplicated
    ++ map (
      name: "${name} is provided by plugin ${(lib.head byName.${name}).plugin} and is also a shared skill"
    ) shadowing;

  skills =
    args:
    let
      found = problems args;
    in
    lib.throwIf (found != [ ]) "plugin skills: ${lib.concatStringsSep "; " found}" (
      lib.foldl' (
        acc: plugin:
        acc
        // lib.mapAttrs (name: _: skillsDir args.sources.${plugin}.src + "/${name}") (
          skillsOf args.sources.${plugin}
        )
      ) { } (lib.attrNames args.sources)
    );
in
{
  inherit problems skills;

  directory =
    found:
    pkgs.linkFarm "plugin-skills" (lib.mapAttrsToList (name: path: { inherit name path; }) found);

  agyInstall =
    { agy, sources }:
    lib.concatMapStringsSep "\n" (
      plugin:
      let
        spec = sources.${plugin};
        tree = toString (spec.antigravityTree or spec.src);
      in
      ''
        record="$HOME/.local/state/nix-config/antigravity-plugins/"${lib.escapeShellArg plugin}
        if [[ -f "$record" && "$(cat "$record")" == ${lib.escapeShellArg tree} && -f "$HOME/.gemini/config/plugins/"${lib.escapeShellArg spec.plugin}/plugin.json ]]; then
          echo ${lib.escapeShellArg "Skipping unchanged Antigravity plugin ${spec.plugin}"}
        else
          rm -f "$record"
          ${agy} plugin validate ${lib.escapeShellArg tree}
          ${agy} plugin install ${lib.escapeShellArg tree}
          mkdir -p "$(dirname "$record")"
          printf '%s\n' ${lib.escapeShellArg tree} > "$record"
        fi
        ${agy} plugin enable ${lib.escapeShellArg spec.plugin}''
    ) (lib.attrNames sources);
}
