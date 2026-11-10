# The container registries the credential helper answers for, with the
# account and the token file under `dir` each one uses. `users` carries the
# account names (github, gitlab, jpi, docker). The NixOS secrets module passes
# /run/secrets/cli-auth; a non-NixOS host passes its user-owned state
# directory.
{ dir, users }:
{
  "ghcr.io" = {
    username = users.github;
    secret = "${dir}/github_token";
  };
  "registry.gitlab.com" = {
    username = users.gitlab;
    secret = "${dir}/gitlab_token";
  };
  "registry.jpi.app" = {
    username = users.jpi;
    secret = "${dir}/jpi_token";
  };
  "docker.io" = {
    username = users.docker;
    secret = "${dir}/docker_token";
  };
}
