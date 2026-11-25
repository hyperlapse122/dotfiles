/*
  Exercise every instruction delivery and keep the T3 context separate.
  Linux callers supply self; native Darwin callers supply explicit
  entries, each { name, user }, from production/bootstrap and fixture hosts.
*/
{
  pkgs,
  self ? { },
  entries ? null,
}:
let
  inherit (pkgs) lib;
  configurations = import ./lib/configurations.nix { inherit pkgs self; };
  userEntries =
    if entries == null then
      configurations.userEntries
      ++ map (entry: {
        inherit (entry) name;
        user =
          (self.nixosConfigurations.${entry.name}.extendModules {
            modules = [ { my.user.gpgKey = lib.mkForce fakeKey; } ];
          }).config.home-manager.users.${entry.config.my.user.name};
      }) configurations.production
    else
      entries;
  esc = value: lib.escapeShellArg (toString value);
  fakeKey = "0123456789ABCDEF0123456789ABCDEF01234567";
  deliveryPaths = [
    ".claude/CLAUDE.md"
    ".pi/agent/AGENTS.md"
    ".config/opencode/AGENTS.md"
  ];
  retiredPaths = [
    ".local/share/nix-config/claude-code-agents.json"
    ".gemini/config/rules"
    ".t3/instructions/claude-code/CLAUDE.md"
    ".grok/AGENTS.md"
    ".grok/rules/instructions.md"
  ];
  homeFile =
    label: user: target: want:
    let
      entries = lib.filter (file: (file.target or "") == target) (lib.attrValues (user.home.file or { }));
      entry = if lib.length entries == 1 then lib.head entries else null;
    in
    lib.optionalString (lib.length entries != want) ''
      echo ${esc "expected ${toString want} home.file for ~/${target} on ${label}, found ${toString (lib.length entries)}"} >&2
      failed=1
    ''
    + lib.optionalString (want == 1 && entry != null && !(entry.enable or false)) ''
      echo ${esc "home.file for ~/${target} on ${label} is not enabled"} >&2
      failed=1
    '';
  assertEntry =
    entry:
    let
      inherit (entry) name user;
    in
    lib.concatMapStrings (target: homeFile name user target 0) (deliveryPaths ++ retiredPaths)
    + homeFile name user ".local/share/nix-config/refresh-agent-instructions" 1
    + homeFile name user ".local/share/nix-config/agent-instructions/task-guide.md" 1
    + homeFile name user ".local/share/nix-config/agent-instructions/t3-guide.md" 1
    + lib.optionalString ((user.my.user.gpgKey or null) == null) ''
      echo ${esc "my.user.gpgKey is unset on ${name}"} >&2
      failed=1
    ''
    + lib.optionalString ((user.home-files or null) == null) ''
      echo ${esc "no materialized home-files on ${name}"} >&2
      failed=1
    '';
  presentEntries = lib.filter (
    entry: (entry.user.home-files or null) != null && (entry.user.my.user.gpgKey or null) != null
  ) userEntries;
  manifest = pkgs.writeText "agent-instructions-deliveries.json" (
    builtins.toJSON (
      map (entry: {
        inherit (entry) name;
        key = entry.user.my.user.gpgKey;
        kind = entry.user.my.kind;
        activation = entry.user.home.activation.agentInstructions.data or "";
        git = "${entry.user.home-files}/.config/git/config";
        guides = "${entry.user.home-files}/.local/share/nix-config/agent-instructions";
      }) presentEntries
    )
  );
in
pkgs.runCommand "agent-instructions-tests"
  {
    nativeBuildInputs = [ pkgs.python3 ];
  }
  ''
    ${lib.optionalString (entries == null) configurations.guard}
    ${lib.optionalString (userEntries == [ ]) ''
      echo 'no user environments to check instruction delivery' >&2
      exit 1
    ''}
    failed=0
    ${lib.concatMapStrings assertEntry userEntries}
    ${lib.optionalString
      (entries == null && !(lib.any (entry: (entry.user.my.user.gpgKey or null) == fakeKey) userEntries))
      ''
        echo 'no user entry carries the fake my.user.gpgKey, so a literal fingerprint would pass' >&2
        failed=1
      ''
    }
    if ! python3 ${./agent-instructions.py} ${../home/h82/agents/instructions/instructions.md.tmpl} ${manifest} ${
      (import ../packages/agent-tools.nix { inherit pkgs; }).agentInstructions
    }/bin/agent-instructions ${
      (import ../packages/text-template.nix { inherit pkgs; })
    }/bin/text-template ${./lib/agent-instruction-receipts.json}; then
      failed=1
    fi
    if [ "$failed" != "0" ]; then
      exit 1
    fi
    touch $out
  ''
