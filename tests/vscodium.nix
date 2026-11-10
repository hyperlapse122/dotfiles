/*
  Check interface:

    import ./tests/vscodium.nix { inherit pkgs self; }

  Asserts that every configuration `tests/lib/configurations.nix` yields gives
  h82 VSCodium, a `code` command, nixd, the Nix IDE and Biome extensions, the
  legacy keybindings, and the declared settings merge. It reads what the
  generations materialize -- home-path, home-files, the Home Manager file
  entries, and the rendered activation script -- rather than the options they
  come from. Expected values are literals stated here, independently of
  home/h82/dev/vscodium.nix.

  Verifies, on every configuration:
  - home-path ships executable bin/codium and bin/nixd, and bin/code execs the
    same codium that bin/codium resolves to.
  - home-files carries the jnoortheen.nix-ide and biomejs.biome extensions
    under .vscode-oss/extensions.
  - .config/VSCodium/User/keybindings.json parses to the legacy bindings, and
    its Home Manager entry is forced, because the legacy dotfiles left an
    unmanaged copy at that path.
  - no Home Manager file targets .config/VSCodium/User/settings.json, and
    Home Manager's own userSettings activation writers are absent.
  - home.activation.vscodiumSettings runs after installPackages, invokes the
    packaged merger without swallowing its exit status, points it at
    ~/.config/VSCodium/User/settings.json, and passes a declared document that
    rebuilds to the legacy settings stated here. Object-valued settings must
    be declared leaf by leaf, never owned whole.
  - running that exact merger with that exact document against a seeded,
    divergent settings file reasserts declared values and keeps keys the user
    or VSCodium added, including keys inside a declared object.

  It cannot see whether VSCodium starts or whether nixd attaches to a file.

  Every lookup carries an `or` fallback so a mutation that removes an entry
  reaches the builder as shell rather than failing evaluation. See
  .compound-engineering/artifacts/solutions/best-practices/unguarded-derivation-interpolation-defeats-nix-check-mutation-testing.md
  The builder collects every failure, so one red build names every broken
  assertion across every configuration.
*/
{ pkgs, self }:
let
  inherit (pkgs) lib;

  configurations = import ./lib/configurations.nix { inherit pkgs self; };

  esc = value: lib.escapeShellArg (toString value);

  # The legacy dotfiles' vscodium-settings.json.tmpl, rendered. `emmet.preferences`
  # is absent: the legacy value is an empty object, which is VSCodium's default.
  settingsExpected = pkgs.writeText "vscodium-expected-settings.json" ''
    {
      "[json]": { "editor.defaultFormatter": "vscode.json-language-features" },
      "[jsonc]": { "editor.defaultFormatter": "biomejs.biome" },
      "[nix]": { "editor.tabSize": 2 },
      "[typescript]": { "editor.defaultFormatter": "biomejs.biome" },
      "[typescriptreact]": { "editor.defaultFormatter": "biomejs.biome" },
      "[yaml]": { "editor.defaultFormatter": "biomejs.biome" },
      "agCockpit.groupingEnabled": true,
      "agCockpit.notificationEnabled": true,
      "biome.requireConfiguration": true,
      "biome.suggestInstallingGlobally": false,
      "chat.agent.maxRequests": 1000,
      "chat.instructionsFilesLocations": { ".github/instructions": true },
      "chat.mcp.gallery.enabled": true,
      "chat.tools.terminal.autoApprove": { "/.*/": true },
      "csharp.experimental.debug.hotReload": true,
      "editor.accessibilitySupport": "off",
      "editor.aiStats.enabled": true,
      "editor.codeActionsOnSave": {
        "source.fixAll.biome": "explicit",
        "source.organizeImports.biome": "explicit"
      },
      "editor.fontFamily": "'JetBrainsMono Nerd Font', 'D2CodingLigature Nerd Font', 'D2KodingLigature Nerd Font', monospace",
      "editor.fontLigatures": true,
      "editor.formatOnSave": true,
      "editor.quickSuggestions": { "strings": "on" },
      "editor.smoothScrolling": true,
      "editor.tabSize": 2,
      "emmet.showAbbreviationSuggestions": false,
      "explorer.autoReveal": false,
      "explorer.incrementalNaming": "smart",
      "extensions.autoCheckUpdates": false,
      "extensions.autoUpdate": "off",
      "files.associations": { "*.json": "json", "*.tmpl": "plaintext" },
      "files.autoSave": "onFocusChange",
      "files.enableTrash": false,
      "git.autofetch": true,
      "git.blame.editorDecoration.enabled": false,
      "git.confirmSync": false,
      "git.enableCommitSigning": true,
      "git.enableSmartCommit": true,
      "git.followTagsWhenSync": true,
      "git.replaceTagsWhenPull": true,
      "github.copilot.chat.agent.thinkingTool": true,
      "github.copilot.chat.codesearch.enabled": true,
      "github.copilot.chat.commitMessageGeneration.instructions": [
        {
          "text": "Use multi-line conventional commit message format. First line should be a short summary (max 72 characters), followed by a blank line, and then a detailed description if necessary."
        }
      ],
      "github.copilot.chat.languageContext.fix.typescript.enabled": true,
      "github.copilot.chat.languageContext.inline.typescript.enabled": true,
      "github.copilot.chat.languageContext.typescript.enabled": true,
      "github.copilot.chat.localeOverride": "en",
      "github.copilot.enable": {
        "*": true,
        "json": true,
        "markdown": false,
        "plaintext": false,
        "scminput": false
      },
      "github.copilot.nextEditSuggestions.enabled": true,
      "github.gitProtocol": "https",
      "githubPullRequests.codingAgent.promptForConfirmation": false,
      "gitlab.authentication.oauthClientIds": {
        "https://git.jpi.app": "c173cf3eb02fabd54c93401cadce5a4a1f8c034e2d85e1f95e9d33dc5e5243e5"
      },
      "gitlab.duoAgentPlatform.enabled": false,
      "gitlab.duoChat.enabled": false,
      "gitlab.duoCodeSuggestions.enabled": false,
      "gitlens.ai.model": "vscode",
      "gitlens.ai.vscode.model": "copilot:gpt-4.1",
      "gitlens.gitkraken.mcp.autoEnabled": false,
      "js/ts.implicitProjectConfig.checkJs": true,
      "js/ts.implicitProjectConfig.experimentalDecorators": true,
      "js/ts.preferences.autoImportFileExcludePatterns": [ "**/dist/**" ],
      "js/ts.preferences.autoImportSpecifierExcludeRegexes": [ "^(node:)?os$", "^node_modules.+$", "^type$" ],
      "js/ts.suggest.completeFunctionCalls": true,
      "js/ts.updateImportsOnFileMove.enabled": "never",
      "json.schemaDownload.trustedDomains": {
        "https://biomejs.dev": true,
        "https://developer.microsoft.com/json-schemas/": true,
        "https://inlang.com": true,
        "https://json-schema.org/": true,
        "https://json.schemastore.org/": true,
        "https://models.dev": true,
        "https://raw.githubusercontent.com/": true,
        "https://raw.githubusercontent.com/devcontainers/spec/": true,
        "https://raw.githubusercontent.com/microsoft/vscode/": true,
        "https://schemastore.azurewebsites.net/": true,
        "https://tokscale.ai/custom-pricing.schema.json": true,
        "https://turbo.build": true,
        "https://turborepo.dev": true,
        "https://ui.shadcn.com": true,
        "https://unpkg.com": true,
        "https://www.schemastore.org/": true
      },
      "markdownlint.lintWorkspaceGlobs": [
        "**/*.{md,mkd,mdwn,mdown,markdown,markdn,mdtxt,mdtext,workbook}",
        "!**/*.code-search",
        "!**/bower_components",
        "!**/node_modules",
        "!**/.git",
        "!**/vendor",
        "!**/.sisyphus"
      ],
      "nix.enableLanguageServer": true,
      "nix.serverPath": "nixd",
      "prettier.enable": false,
      "python.analysis.typeCheckingMode": "basic",
      "redhat.telemetry.enabled": false,
      "remote.SSH.remotePlatform": { "deskmini.tetra-gecko.ts.net": "linux" },
      "sherlock.previewLanguageTag": "en",
      "sherlock.userId": "f2117860-db4f-4634-9ddb-58c999457bce",
      "terminal.integrated.enableImages": true,
      "terminal.integrated.fontLigatures.enabled": true,
      "terminal.integrated.stickyScroll.enabled": false,
      "todo-tree.general.tags": [ "BUG", "HACK", "FIXME", "TODO", "XXX" ],
      "update.mode": "none",
      "vscode-edge-devtools.webhintInstallNotification": true,
      "window.restoreWindows": "none",
      "workbench.welcomePage.walkthroughs.openOnInstall": false
    }
  '';

  # The legacy keybindings.json with its duplicated backspace entry dropped.
  # "\\\r\n" is a backslash, a carriage return, and a line feed.
  keybindingsExpected = pkgs.writeText "vscodium-expected-keybindings.json" ''
    [
      { "args": { "text": "\\\r\n" }, "command": "workbench.action.terminal.sendSequence", "key": "shift+enter", "when": "terminalFocus" },
      { "args": { "text": "\\\r\n" }, "command": "workbench.action.terminal.sendSequence", "key": "ctrl+enter", "when": "terminalFocus" },
      { "command": "deleteFile", "key": "backspace", "when": "filesExplorerFocus && foldersViewVisible && !inputFocus" },
      { "command": "deleteFile", "key": "delete", "when": "filesExplorerFocus && foldersViewVisible && !inputFocus" },
      { "command": "deleteFile", "key": "shift+delete", "when": "filesExplorerFocus && foldersViewVisible && !explorerResourceMoveableToTrash && !inputFocus" },
      { "command": "-deleteFile", "key": "shift+delete", "when": "filesExplorerFocus && foldersViewVisible && !inputFocus" },
      { "command": "-deleteFile", "key": "delete", "when": "filesExplorerFocus && foldersViewVisible && !explorerResourceMoveableToTrash && !inputFocus" }
    ]
  '';

  # Rebuilds the settings a declared document assigns and compares them with
  # the expected legacy settings. An owned or set object fails even when the
  # rebuilt settings match, because owning an object discards the entries
  # VSCodium writes into it.
  checkDeclared = pkgs.writeText "vscodium-check-declared.py" ''
    import json, sys
    declared = json.load(open(sys.argv[1]))
    expected = json.load(open(sys.argv[2]))
    problems = []
    unknown = set(declared) - {'set', 'setPaths', 'own'}
    if unknown:
        problems.append('unexpected fields: {}'.format(sorted(unknown)))
    rebuilt = {}
    for name, value in declared.get('set', {}).items():
        rebuilt[name] = value
    for name, value in declared.get('own', {}).items():
        if isinstance(value, dict):
            problems.append('object setting owned whole: {}'.format(name))
        rebuilt[name] = value
    for entry in declared.get('setPaths', []):
        node = rebuilt
        for key in entry['path'][:-1]:
            node = node.setdefault(key, {})
        node[entry['path'][-1]] = entry['value']
    for name in sorted(set(rebuilt) | set(expected)):
        if rebuilt.get(name, '<absent>') != expected.get(name, '<absent>'):
            problems.append('{}: declared {!r}, expected {!r}'.format(
                name, rebuilt.get(name, '<absent>'), expected.get(name, '<absent>')))
    for problem in problems:
        print(problem, file=sys.stderr)
    sys.exit(1 if problems else 0)
  '';

  seededSettings = pkgs.writeText "vscodium-seeded-settings.json" (
    builtins.toJSON {
      "files.autoSave" = "off";
      "[nix]" = {
        "editor.tabSize" = 4;
        "editor.insertSpaces" = false;
      };
      "json.schemaDownload.trustedDomains" = {
        "https://biomejs.dev" = false;
        "https://example.test/" = true;
      };
      "workbench.colorTheme" = "Solarized Dark";
    }
  );

  checkMerged = pkgs.writeText "vscodium-check-merged.py" ''
    import json, sys
    merged = json.load(open(sys.argv[1]))
    wanted = {
        'files.autoSave': 'onFocusChange',
        'workbench.colorTheme': 'Solarized Dark',
        'editor.tabSize': 2,
    }
    problems = ['{}: {!r}'.format(k, merged.get(k)) for k, v in wanted.items() if merged.get(k) != v]
    if merged.get('[nix]') != {'editor.tabSize': 2, 'editor.insertSpaces': False}:
        problems.append('[nix]: {!r}'.format(merged.get('[nix]')))
    domains = merged.get('json.schemaDownload.trustedDomains', {})
    if domains.get('https://biomejs.dev') is not True or domains.get('https://example.test/') is not True:
        problems.append('json.schemaDownload.trustedDomains: {!r}'.format(domains))
    for problem in problems:
        print(problem, file=sys.stderr)
    sys.exit(1 if problems else 0)
  '';

  compareJson = pkgs.writeText "compare-json.py" ''
    import json, sys
    sys.exit(0 if json.load(open(sys.argv[1])) == json.load(open(sys.argv[2])) else 1)
  '';

  assertEntry =
    entry:
    let
      hm = entry.user;
      homePath = hm.home.path or null;
      homeFiles = hm.home-files or null;
      files = lib.attrValues (hm.home.file or { });

      activation = hm.home.activation.vscodiumSettings or null;
      script = if activation == null then "" else (activation.data or "");
      runsAfterPackages = lib.elem "installPackages" (
        if activation == null then [ ] else (activation.after or [ ])
      );

      targeting = target: lib.filter (file: (file.target or "") == target) files;
      keybindingsEntries = targeting ".config/VSCodium/User/keybindings.json";
      keybindingsForced =
        keybindingsEntries != [ ] && lib.all (file: file.force or false) keybindingsEntries;
      settingsTargeted = targeting ".config/VSCodium/User/settings.json" != [ ];
      # Home Manager's own userSettings writers, which a later declaration
      # would add beside the merge without targeting settings.json.
      hmSettingsWriters = lib.filter (name: lib.hasAttr name (hm.home.activation or { })) [
        "vscodiumMutableUserSettings"
        "vscodiumImmutableUserSettings"
      ];

      host' = esc entry.name;
    in
    ''
      ${
        if homePath == null then
          ''fail ${host'}": no home-path"''
        else
          ''
            for bin in codium code nixd; do
              if [ ! -x ${homePath}/bin/$bin ]; then
                fail ${host'}": home-path has no executable bin/$bin"
              fi
            done
            if [ -x ${homePath}/bin/code ] && [ -x ${homePath}/bin/codium ]; then
              codium=$(readlink -f ${homePath}/bin/codium)
              target=$(sed -n '/^exec /{s/^exec \([^[:space:]]*\).*/\1/p;q}' "$(readlink -f ${homePath}/bin/code)")
              if [ -z "$target" ] || [ "$(readlink -f "$target")" != "$codium" ]; then
                fail ${host'}": bin/code does not exec the codium bin/codium resolves to ($codium), got: '$target'"
              fi
            fi
          ''
      }
      ${
        if homeFiles == null then
          ''fail ${host'}": no home-files"''
        else
          ''
            for extension in jnoortheen.nix-ide biomejs.biome; do
              if [ ! -f ${homeFiles}/.vscode-oss/extensions/$extension/package.json ]; then
                fail ${host'}": missing extension .vscode-oss/extensions/$extension"
              fi
            done
            keybindings=${homeFiles}/.config/VSCodium/User/keybindings.json
            if [ ! -f "$keybindings" ]; then
              fail ${host'}": missing .config/VSCodium/User/keybindings.json"
            elif ! python3 "$compareJson" "$keybindings" ${keybindingsExpected}; then
              fail ${host'}": keybindings.json differs from the legacy bindings"
            fi
          ''
      }
      if [ ${esc (lib.boolToString keybindingsForced)} != "true" ]; then
        fail ${host'}": the keybindings.json entry must set force = true; the legacy dotfiles left an unmanaged copy there"
      fi
      if [ ${esc (lib.boolToString settingsTargeted)} != "false" ]; then
        fail ${host'}": Home Manager must not target .config/VSCodium/User/settings.json; VSCodium owns it"
      fi
      ${lib.optionalString (hmSettingsWriters != [ ]) ''
        fail ${host'}": Home Manager's own settings writer would run beside the merge: ${lib.concatStringsSep ", " hmSettingsWriters}"
      ''}

      ${lib.optionalString (activation == null) ''
        fail ${host'}": missing home.activation.vscodiumSettings"
      ''}
      if [ ${esc (lib.boolToString runsAfterPackages)} != "true" ]; then
        fail ${host'}": home.activation.vscodiumSettings must run after installPackages"
      fi

      script=${esc script}
      # Comment lines are stripped so an explanatory sentence cannot match.
      if printf '%s' "$script" | grep -v '^[[:space:]]*#' \
        | grep -qE '(\|\|[[:space:]]*(true|:|echo)|;[[:space:]]*true|set \+e)'; then
        fail ${host'}": the vscodiumSettings activation script swallows the merger exit status"
      fi

      merger=$(printf '%s' "$script" | tr '\n' ' ' \
        | grep -oE -- '/nix/store/[^[:space:]]+/bin/agent-settings' | head -1 || true)
      if [ -z "$merger" ]; then
        fail ${host'}": the vscodiumSettings activation script does not invoke the packaged merger"
      fi

      settingsArg=$(printf '%s' "$script" | tr '\n' ' ' \
        | grep -oE -- '--settings[[:space:]]+[^[:space:]]+' | head -1 | awk '{print $2}' || true)
      if [ "$settingsArg" != /home/h82/.config/VSCodium/User/settings.json ]; then
        fail ${host'}": the merger must be pointed at ~/.config/VSCodium/User/settings.json, got: '$settingsArg'"
      fi

      declaredPath=$(printf '%s' "$script" | tr '\n' ' ' \
        | grep -oE -- '--declared[[:space:]]+/nix/store/[^[:space:]]+' | head -1 | awk '{print $2}' || true)
      if [ -z "$declaredPath" ]; then
        fail ${host'}": the vscodiumSettings activation script passes no declared document"
      elif ! python3 ${checkDeclared} "$declaredPath" ${settingsExpected}; then
        fail ${host'}": the declared settings drifted from the legacy settings"
      elif [ -n "$merger" ]; then
        seeded=$TMPDIR/${entry.name}-settings.json
        cp ${seededSettings} "$seeded"
        chmod 600 "$seeded"
        redirected="$TMPDIR/${entry.name}-activation.sh"
        python3 -c '
      import sys
      target, scratch, output, body = sys.argv[1:]
      assert target and target in body, "activation destination was not redirected"
      rewritten = body.replace(target, scratch)
      assert rewritten != body and target not in rewritten
      open(output, "w").write(rewritten)
        ' "$settingsArg" "$seeded" "$redirected" "$script"
        if ! DRY_RUN=1 ${pkgs.bash}/bin/bash -euo pipefail "$redirected"; then
          fail ${host'}": settings dry-run failed"
        elif ! cmp -s "$seeded" ${seededSettings}; then
          fail ${host'}": settings dry-run changed protected bytes"
        fi
        if ! ${pkgs.bash}/bin/bash -eu "$redirected"; then
          fail ${host'}": the activation merger refused the seeded settings file"
        elif ! python3 ${checkMerged} "$seeded"; then
          fail ${host'}": merging the seeded settings file lost a declared value or a key VSCodium wrote"
        fi
        rm -f "$seeded"
        mkdir "$seeded"
        if ${pkgs.bash}/bin/bash -eu "$redirected"; then
          fail ${host'}": activation swallowed a settings refusal"
        fi
        rmdir "$seeded"
      fi
    '';
in
pkgs.runCommand "vscodium-tests" { nativeBuildInputs = [ pkgs.python3 ]; } ''
  ${configurations.guard}
  failed=0
  fail() {
    echo "$1" >&2
    failed=1
  }
  compareJson=${compareJson}

  ${lib.concatMapStringsSep "\n" assertEntry configurations.entries}

  if [ "$failed" != 0 ]; then
    exit 1
  fi
  touch $out
''
