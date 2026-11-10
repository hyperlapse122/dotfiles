{
  config,
  pkgs,
  lib,
  ...
}:
let
  cfg = config.programs.vscodium;

  merger = "${
    (import ../../../packages/agent-tools.nix { inherit pkgs; }).agentSettings
  }/bin/agent-settings";

  # The families Ghostty uses (desktop/terminal.nix). The NixOS monospace
  # default is not this list: Plasma appends Hack and Noto Sans Mono to it.
  monospaceFamilies = [
    "JetBrainsMono Nerd Font"
    "D2CodingLigature Nerd Font"
    "D2KodingLigature Nerd Font"
  ];

  # `emmet.preferences` is omitted: its empty legacy object is VSCodium's
  # default.
  settings = {
    "[json]"."editor.defaultFormatter" = "vscode.json-language-features";
    "[jsonc]"."editor.defaultFormatter" = "biomejs.biome";
    "[nix]"."editor.tabSize" = 2;
    "[typescript]"."editor.defaultFormatter" = "biomejs.biome";
    "[typescriptreact]"."editor.defaultFormatter" = "biomejs.biome";
    "[yaml]"."editor.defaultFormatter" = "biomejs.biome";
    "agCockpit.groupingEnabled" = true;
    "agCockpit.notificationEnabled" = true;
    "biome.requireConfiguration" = true;
    "biome.suggestInstallingGlobally" = false;
    "chat.agent.maxRequests" = 1000;
    "chat.instructionsFilesLocations".".github/instructions" = true;
    "chat.mcp.gallery.enabled" = true;
    "chat.tools.terminal.autoApprove"."/.*/" = true;
    "csharp.experimental.debug.hotReload" = true;
    "editor.accessibilitySupport" = "off";
    "editor.aiStats.enabled" = true;
    "editor.codeActionsOnSave" = {
      "source.fixAll.biome" = "explicit";
      "source.organizeImports.biome" = "explicit";
    };
    "editor.fontFamily" =
      lib.concatMapStrings (family: "'${family}', ") monospaceFamilies + "monospace";
    "editor.fontLigatures" = true;
    "editor.formatOnSave" = true;
    "editor.quickSuggestions".strings = "on";
    "editor.smoothScrolling" = true;
    "editor.tabSize" = 2;
    "emmet.showAbbreviationSuggestions" = false;
    "explorer.autoReveal" = false;
    "explorer.incrementalNaming" = "smart";
    "extensions.autoCheckUpdates" = false;
    "extensions.autoUpdate" = "off";
    "files.associations" = {
      "*.json" = "json";
      "*.tmpl" = "plaintext";
    };
    "files.autoSave" = "onFocusChange";
    "files.enableTrash" = false;
    "git.autofetch" = true;
    "git.blame.editorDecoration.enabled" = false;
    "git.confirmSync" = false;
    "git.enableCommitSigning" = true;
    "git.enableSmartCommit" = true;
    "git.followTagsWhenSync" = true;
    "git.replaceTagsWhenPull" = true;
    "github.copilot.chat.agent.thinkingTool" = true;
    "github.copilot.chat.codesearch.enabled" = true;
    "github.copilot.chat.commitMessageGeneration.instructions" = [
      {
        text = "Use multi-line conventional commit message format. First line should be a short summary (max 72 characters), followed by a blank line, and then a detailed description if necessary.";
      }
    ];
    "github.copilot.chat.languageContext.fix.typescript.enabled" = true;
    "github.copilot.chat.languageContext.inline.typescript.enabled" = true;
    "github.copilot.chat.languageContext.typescript.enabled" = true;
    "github.copilot.chat.localeOverride" = "en";
    "github.copilot.enable" = {
      "*" = true;
      json = true;
      markdown = false;
      plaintext = false;
      scminput = false;
    };
    "github.copilot.nextEditSuggestions.enabled" = true;
    "github.gitProtocol" = "https";
    "githubPullRequests.codingAgent.promptForConfirmation" = false;
    "gitlab.authentication.oauthClientIds"."https://git.jpi.app" =
      "c173cf3eb02fabd54c93401cadce5a4a1f8c034e2d85e1f95e9d33dc5e5243e5";
    "gitlab.duoAgentPlatform.enabled" = false;
    "gitlab.duoChat.enabled" = false;
    "gitlab.duoCodeSuggestions.enabled" = false;
    "gitlens.ai.model" = "vscode";
    "gitlens.ai.vscode.model" = "copilot:gpt-4.1";
    "gitlens.gitkraken.mcp.autoEnabled" = false;
    "js/ts.implicitProjectConfig.checkJs" = true;
    "js/ts.implicitProjectConfig.experimentalDecorators" = true;
    "js/ts.preferences.autoImportFileExcludePatterns" = [ "**/dist/**" ];
    "js/ts.preferences.autoImportSpecifierExcludeRegexes" = [
      "^(node:)?os$"
      "^node_modules.+$"
      "^type$"
    ];
    "js/ts.suggest.completeFunctionCalls" = true;
    "js/ts.updateImportsOnFileMove.enabled" = "never";
    "json.schemaDownload.trustedDomains" = lib.genAttrs [
      "https://biomejs.dev"
      "https://developer.microsoft.com/json-schemas/"
      "https://inlang.com"
      "https://json-schema.org/"
      "https://json.schemastore.org/"
      "https://models.dev"
      "https://raw.githubusercontent.com/"
      "https://raw.githubusercontent.com/devcontainers/spec/"
      "https://raw.githubusercontent.com/microsoft/vscode/"
      "https://schemastore.azurewebsites.net/"
      "https://tokscale.ai/custom-pricing.schema.json"
      "https://turbo.build"
      "https://turborepo.dev"
      "https://ui.shadcn.com"
      "https://unpkg.com"
      "https://www.schemastore.org/"
    ] (_: true);
    "markdownlint.lintWorkspaceGlobs" = [
      "**/*.{md,mkd,mdwn,mdown,markdown,markdn,mdtxt,mdtext,workbook}"
      "!**/*.code-search"
      "!**/bower_components"
      "!**/node_modules"
      "!**/.git"
      "!**/vendor"
      "!**/.sisyphus"
    ];
    "nix.enableLanguageServer" = true;
    "nix.serverPath" = "nixd";
    "prettier.enable" = false;
    "python.analysis.typeCheckingMode" = "basic";
    "redhat.telemetry.enabled" = false;
    "remote.SSH.remotePlatform"."deskmini.tetra-gecko.ts.net" = "linux";
    "sherlock.previewLanguageTag" = "en";
    "sherlock.userId" = "f2117860-db4f-4634-9ddb-58c999457bce";
    "terminal.integrated.enableImages" = true;
    "terminal.integrated.fontLigatures.enabled" = true;
    "terminal.integrated.stickyScroll.enabled" = false;
    "todo-tree.general.tags" = [
      "BUG"
      "HACK"
      "FIXME"
      "TODO"
      "XXX"
    ];
    "update.mode" = "none";
    "vscode-edge-devtools.webhintInstallNotification" = true;
    "window.restoreWindows" = "none";
    "workbench.welcomePage.walkthroughs.openOnInstall" = false;
  };

  # VSCodium owns settings.json and rewrites it from its UI, so activation
  # assigns these values and leaves every other key as VSCodium wrote it.
  # VSCodium and its extensions also write into object-valued settings (a
  # trusted schema domain, a Copilot toggle, a new SSH host), so an object is
  # declared leaf by leaf rather than owned whole. Arrays have no element-wise
  # form and are owned.
  leaves =
    path: value:
    if lib.isAttrs value then
      lib.concatLists (lib.mapAttrsToList (key: leaves (path ++ [ key ])) value)
    else
      [ { inherit path value; } ];

  declared = pkgs.writeText "vscodium-declared-settings.json" (
    builtins.toJSON {
      set = lib.filterAttrs (_: value: !(lib.isAttrs value || lib.isList value)) settings;
      setPaths = leaves [ ] (lib.filterAttrs (_: lib.isAttrs) settings);
      own = lib.filterAttrs (_: lib.isList) settings;
    }
  );

  sendNewline = key: {
    inherit key;
    command = "workbench.action.terminal.sendSequence";
    args.text = "\\\r\n";
    when = "terminalFocus";
  };

  explorer = "filesExplorerFocus && foldersViewVisible";

  # Home Manager's VSCodium module picks the user directory by platform, so
  # this follows the same test rather than the host kind.
  isDarwin = pkgs.stdenv.hostPlatform.isDarwin;

  # Where Home Manager's VSCodium module puts the user settings: macOS keeps
  # them under Application Support rather than the XDG config directory.
  userDir =
    if isDarwin then
      "${config.home.homeDirectory}/Library/Application Support/VSCodium/User"
    else
      "${config.xdg.configHome}/VSCodium/User";

  # The macOS path holds a space, so it is quoted there; the Linux path is
  # interpolated as before so the Linux activation script is unchanged.
  settingsArg =
    if isDarwin then lib.escapeShellArg "${userDir}/settings.json" else "${userDir}/settings.json";
in
{
  programs.vscodium = {
    enable = true;
    package = pkgs.vscodium;
    profiles.default = {
      extensions = with pkgs.vscode-extensions; [
        jnoortheen.nix-ide
        biomejs.biome
      ];
      keybindings = [
        (sendNewline "shift+enter")
        (sendNewline "ctrl+enter")
        {
          key = "backspace";
          command = "deleteFile";
          when = "${explorer} && !inputFocus";
        }
        {
          key = "delete";
          command = "deleteFile";
          when = "${explorer} && !inputFocus";
        }
        {
          key = "shift+delete";
          command = "deleteFile";
          when = "${explorer} && !explorerResourceMoveableToTrash && !inputFocus";
        }
        {
          key = "shift+delete";
          command = "-deleteFile";
          when = "${explorer} && !inputFocus";
        }
        {
          key = "delete";
          command = "-deleteFile";
          when = "${explorer} && !explorerResourceMoveableToTrash && !inputFocus";
        }
      ];
    };
  };

  # The legacy dotfiles installed a regular keybindings.json here, and an
  # unmanaged file at a Home Manager target aborts activation.
  home.file."${userDir}/keybindings.json".force = true;

  home.packages = [
    pkgs.nixd
    # pkgs.vscodium ships only `codium`; a wrapper, unlike a shell alias, is
    # found by Git and other non-interactive callers.
    (pkgs.writeShellScriptBin "code" ''
      exec ${lib.getExe cfg.package} "$@"
    '')
  ];

  # No executable-existence guard; ordered after installPackages as on
  # claudeSettings in agents/claude.nix: a refusal must fail the rebuild
  # loudly without stranding linkGeneration or installPackages behind it.
  home.activation.vscodiumSettings = lib.hm.dag.entryAfter [ "installPackages" ] ''
    if [[ ! -v DRY_RUN ]]; then
      ${merger} \
        --label VSCodium \
        --settings ${settingsArg} \
        --declared ${declared}
    fi
  '';
}
