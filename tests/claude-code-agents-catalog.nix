{ pkgs, agentTools }:
pkgs.runCommand "claude-code-agents-catalog-tests" { } ''
  ${pkgs.lib.getExe agentTools.claudeCodeAgents} --output "$TMPDIR/extracted.json"
  if ! diff -u ${../packages/claude-code-agents.json} "$TMPDIR/extracted.json"; then
    echo 'packages/claude-code-agents.json differs from the catalog extracted from the pinned claude-code' >&2
    exit 1
  fi
  touch $out
''
