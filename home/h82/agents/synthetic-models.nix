# Each entry:
# - `id`: the upstream model ID, without the `synthetic/` provider prefix OMP
#   adds.
# - `family`: the family the shared instructions map the ID's org to.
# - `lineage`: an anchored regular expression, valid for both Nix
#   `builtins.match` and Python `re.fullmatch`, that matches this ID and newer
#   builds of the same product but no suffixed product such as `-Air` or
#   `-Code`. Its first capture group is the version; POSIX regular
#   expressions have no non-capturing group, so later groups only hold the
#   optional parts of that version or the build suffix.
# - `roles`: each role a consumer reads from the model, with the effort that
#   role runs at. An entry no consumer reads a role from carries
#   `roles = { }`. These models offer no `medium` effort.
# - `defaultEffort`: the preferred reasoning effort monitored for catalog
#   drift; it does not set T3's startup selection.
#
# The DeepSeek `id` pins one dated build and moves only when the user changes
# it after a reconcile issue reports a newer one.
{
  glm = {
    id = "hf:zai-org/GLM-5.3";
    family = "glm";
    lineage = "hf:zai-org/GLM-([0-9]+([.][0-9]+)?)";
    roles = { };
    defaultEffort = "max";
  };

  glmFlash = {
    id = "hf:zai-org/GLM-5.3-Flash";
    family = "glm";
    lineage = "hf:zai-org/GLM-([0-9]+([.][0-9]+)?)-Flash";
    roles = { };
    defaultEffort = "high";
  };

  deepseek = {
    id = "hf:deepseek-ai/DeepSeek-V4.1-Flash-1017";
    family = "deepseek";
    lineage = "hf:deepseek-ai/DeepSeek-V([0-9]+([.][0-9]+)?)-Flash(-[0-9]{4})?";
    roles = {
      text-generation = "low";
    };
    defaultEffort = "high";
  };

  defaultModel = "glm";
  textGeneration = "deepseek";
}
