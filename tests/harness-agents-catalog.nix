{ pkgs, agentTools }:
pkgs.runCommand "harness-agents-catalog-tests" { } ''
  ${pkgs.lib.getExe agentTools.codexAgents} --output "$TMPDIR/codex.json"
  diff -u ${../packages/codex-agents.json} "$TMPDIR/codex.json"
  ${pkgs.lib.getExe agentTools.piAgents} --output "$TMPDIR/pi.json"
  diff -u ${../packages/pi-agents.json} "$TMPDIR/pi.json"
  touch $out
''
