/*
  Helper interface:

    expectedPeers = import ./lib/cross-model-peers.nix { inherit lib; };
    expectedPeers packages

  The Compound Engineering review tokens a user environment must allow,
  sorted, derived from the `pname`s of its installed `packages` rather than
  from my.agents.crossModelPeers, so a module that installs a peer harness
  but drops its token fails. OMP has no entry, because Compound
  Engineering has no OMP token. Antigravity's token follows the ACP runtime
  on PATH, which Compound Engineering's Antigravity route runs.
*/
{ lib }:
packages:
let
  tokens = {
    claude-code = "claude";
    codex = "codex";
    antigravity-acp-path = "antigravity";
  };
  pnames = map (p: p.pname or (lib.getName p)) packages;
in
lib.sort lib.lessThan (
  lib.unique (lib.attrValues (lib.filterAttrs (pname: _: lib.elem pname pnames) tokens))
)
