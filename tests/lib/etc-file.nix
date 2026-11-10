# The store path a configuration materialises at /etc/<name>, or null. An
# entry that is disabled or retargeted is not materialised at its path, so it
# counts as missing even though its source still evaluates.
{ lib }:
config: name:
let
  entry = config.environment.etc.${name} or null;
in
if entry == null || !(entry.enable or true) || (entry.target or name) != name then
  null
else
  entry.source
