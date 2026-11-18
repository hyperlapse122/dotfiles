# Neutral source pin metadata for agent plugins: what a plugin is and where it
# comes from, with no opinion about which agent gets it. `tag` is the pin;
# `expectedRev` is the revision that tag is expected to name, because a git tag
# is mutable and a relock re-resolves the ref rather than the revision.
# tests/agent-plugins.nix compares expectedRev against what flake.lock actually
# recorded, so a re-pointed upstream tag fails a check instead of arriving as a
# lock diff.
{
  compound-engineering = {
    upstream = "EveryInc/compound-engineering-plugin";
    # Upstream interleaves several tag trains in one namespace, so resolution
    # filters on this prefix. Stripping it from `tag` also yields the version
    # segment the materialized path is keyed by.
    tagPrefix = "compound-engineering-";
    tag = "compound-engineering-v3.38.2";
    expectedRev = "8f7614639e7f3792a6f9337d8742a80a232bd596";
    # Read from the source's own manifests, never invented here: the install
    # identifier is `<plugin>@<marketplace>`.
    plugin = "compound-engineering";
    marketplace = "compound-engineering-plugin";
  };
}
