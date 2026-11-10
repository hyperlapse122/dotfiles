# `tag` is the pin; `expectedRev` is the revision that tag is expected to
# name, because a git tag is mutable and a relock re-resolves the ref rather
# than the revision. tests/korean-skills.nix compares expectedRev against what
# flake.lock actually recorded, so a re-pointed upstream tag fails a check
# instead of arriving as a lock diff.
{
  upstream = "DaleSeo/korean-skills";
  tag = "v1.0.0";
  expectedRev = "fe6432e95f6675f7e411eacb2e1c36f1de54f962";
  skills = [
    "humanizer"
    "grammar-checker"
    "style-guide"
  ];
}
