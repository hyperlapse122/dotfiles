/*
  Exercise every instruction delivery and keep the T3 context separate.
  Linux callers supply self/fixtures; native Darwin callers supply explicit
  entries, each { name, user }, from production/bootstrap and fixture hosts.
*/
{
  pkgs,
  self ? { },
  fixtures ? [ ],
  entries ? null,
}:
let
  inherit (pkgs) lib;
  configurations = import ./lib/configurations.nix { inherit pkgs self fixtures; };
  userEntries =
    if entries == null then
      configurations.userEntries
      ++ map (entry: {
        inherit (entry) name;
        user =
          (self.nixosConfigurations.${entry.name}.extendModules {
            modules = [ { my.user.gpgKey = lib.mkForce fakeKey; } ];
          }).config.home-manager.users.h82;
      }) configurations.production
    else
      entries;
  esc = value: lib.escapeShellArg (toString value);
  fakeKey = "0123456789ABCDEF0123456789ABCDEF01234567";
  deliveries = {
    ".claude/CLAUDE.md" = "claude";
    ".codex/AGENTS.md" = "codex";
    ".grok/AGENTS.md" = "grok";
    ".pi/agent/AGENTS.md" = "pi";
    ".gemini/config/rules" = "antigravity";
  };
  deliveryPaths = lib.attrNames deliveries;
  retiredPaths = [
    ".t3/instructions/claude-code/CLAUDE.md"
    ".gemini/GEMINI.md"
    ".gemini/config/AGENTS.md"
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
    lib.concatMapStrings (
      target: homeFile name user target (if user.my.kind == "linux" then 1 else 0)
    ) deliveryPaths
    + homeFile name user ".local/share/nix-config/refresh-agent-instructions" (
      if user.my.kind == "linux" then 0 else 1
    )
    + lib.concatMapStrings (target: homeFile name user target 0) retiredPaths
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
        kdeActivation = entry.user.home.activation.kdeSession.data or "";
        kdeDefaults =
          if entry.user.my.kind == "nixos" then
            (import ./lib/etc-file.nix { inherit lib; }) self.nixosConfigurations.${entry.name}.config
              "xdg/plasma-localerc"
          else
            null;
        locale = {
          name = entry.user.my.locale.name;
          language = "ko-KR";
        };
        paths = map (target: {
          inherit target;
          path = "${entry.user.home-files}/${target}";
          delivery = deliveries.${target};
        }) deliveryPaths;
        git = "${entry.user.home-files}/.config/git/config";
      }) presentEntries
    )
  );
in
pkgs.runCommand "agent-instructions-tests" { nativeBuildInputs = [ pkgs.python3 ]; } ''
  ${lib.optionalString (entries == null) configurations.userGuard}
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
  if ! python3 ${./agent-instructions.py} ${../home/h82/agents/instructions/instructions.md.tmpl} ${manifest} ${../AGENTS.md} ${../CONCEPTS.md} ${
    (import ../packages/agent-tools.nix { inherit pkgs; }).agentInstructions
  }/bin/agent-instructions ${
    (import ../packages/text-template.nix { inherit pkgs; })
  }/bin/text-template ${../docs/agent-routing.md} ${../packages/t3code-release.json}; then
    failed=1
  fi
  if [ "$failed" != "0" ]; then
    exit 1
  fi
  touch $out
''
