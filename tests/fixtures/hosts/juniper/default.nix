# The aarch64 fixture keeps the default account and enables only the T3 Code
# CLI, a server's trait, so its build runs the aarch64 `t3` install check.
{
  my.t3.cli.enable = true;
}
