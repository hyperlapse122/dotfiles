{ pkgs, ... }:
{
  services.desktopManager.plasma6.enable = true;
  services.displayManager.sddm.enable = true;
  services.displayManager.sddm.wayland.enable = true;

  # kde-baloo starts before KWin exports WAYLAND_DISPLAY and DISPLAY, so the
  # extractor's QGuiApplication falls back to wayland-0, which KWin 6.8 no
  # longer creates, and aborts. The extractor draws nothing. The unit comes
  # from the system path, not systemd.packages, so only an explicit drop-in
  # keeps NixOS from writing a bare unit over it. A raw unit, unlike
  # systemd.user.services, does not also replace the session's PATH.
  systemd.user.units."kde-baloo.service" = {
    overrideStrategy = "asDropin";
    text = ''
      [Service]
      Environment=QT_QPA_PLATFORM=offscreen
    '';
  };

  programs._1password.enable = true;

  programs._1password-gui = {
    enable = true;
    polkitPolicyOwners = [ "h82" ];
  };

  i18n.inputMethod = {
    enable = true;
    type = "fcitx5";
    fcitx5 = {
      waylandFrontend = true;
      addons = with pkgs; [
        fcitx5-hangul
        fcitx5-gtk
        kdePackages.fcitx5-qt
      ];
      settings = {
        inputMethod = {
          "Groups/0" = {
            Name = "기본값";
            "Default Layout" = "us";
            DefaultIM = "hangul";
          };
          "Groups/0/Items/0" = {
            Name = "keyboard-us";
            Layout = "";
          };
          "Groups/0/Items/1" = {
            Name = "hangul";
            Layout = "";
          };
          GroupOrder = {
            "0" = "기본값";
          };
        };
        globalOptions = {
          "Hotkey/TriggerKeys" = {
            "0" = "Hangul";
          };
          "Hotkey/EnumerateGroupForwardKeys" = {
            "0" = "Super+space";
          };
        };
        addons = {
          hangul = {
            globalSection = {
              Keyboard = "Dubeolsik";
            };
            sections = {
              HanjaModeToggleKey = {
                "0" = "Hangul_Hanja";
                "1" = "F9";
              };
            };
          };
        };
      };
    };
  };

  environment.etc."xdg/fcitx5/conf/classicui.conf".text = ''
    Vertical Candidate List=False
    WheelForPaging=True
    Font="Pretendard 10"
    MenuFont="Pretendard 10"
    TrayFont="Pretendard Bold 10"
    TrayOutlineColor=#000000
    TrayTextColor=#ffffff
    PreferTextIcon=False
    ShowLayoutNameInIcon=True
    UseInputMethodLanguageToDisplayText=True
    Theme=default
    DarkTheme=default-dark
    UseDarkTheme=True
    UseAccentColor=True
    PerScreenDPI=True
    ForceWaylandDPI=0
    EnableFractionalScale=True
  '';

  environment.etc."xdg/fcitx5/conf/hangul.conf".text = ''
    # 자판 배열
    Keyboard=Dubeolsik
    # 자동 재배열
    AutoReorder=False
    # 같은 글쇠 두 번 입력 시 결합
    CombiOnDoubleStroke=False
    # 초성이 아닌 자모 결합
    NonChoseongCombi=False
    # 단어 단위 확정
    WordCommit=False
    # 한자 모드
    HanjaMode=False

    [HanjaModeToggleKey]
    0=Hangul_Hanja
    1=F9

    [PrevPage]
    0=Up

    [NextPage]
    0=Down

    [PrevCandidate]
    0=Shift+Tab

    [NextCandidate]
    0=Tab
  '';

  environment.etc."xdg/fcitx5/conf/kimpanel.conf".text = ''
    # 텍스트 아이콘 선호
    PreferTextIcon=False
  '';

  environment.etc."xdg/kwinrc".text = ''
    [Wayland]
    InputMethod=/run/current-system/sw/share/applications/fcitx5-wayland-launcher.desktop

    [ElectricBorders]
    Bottom=None
    BottomLeft=None
    BottomRight=None
    Left=None
    Right=None
    Top=None
    TopLeft=None
    TopRight=None

    [EdgeBarrier]
    CornerBarrier=false
    EdgeBarrier=0
  '';

  environment.etc."xdg/ksmserverrc".text = ''
    [General]
    loginMode=emptySession
  '';

  environment.etc."xdg/powerdevilrc".text = ''
    [AC/Display]
    DimDisplayIdleTimeoutSec=-1
    DimDisplayWhenIdle=false

    [Battery/Display]
    DimDisplayIdleTimeoutSec=120
    DimDisplayWhenIdle=true

    [LowBattery/Display]
    DimDisplayIdleTimeoutSec=60
    DimDisplayWhenIdle=true
  '';

  environment.etc."xdg/dolphinrc".text = ''
    [General]
    HomeUrl=/home/h82
    RememberOpenedTabs=false
  '';

  environment.etc."xdg/krunnerrc".text = ''
    [General]
    FreeFloating=true
    historyBehavior=ImmediateCompletion

    [Runners/krunner_kill]
    sorting=1
    triggerWord=kill
    useTriggerWord=true
  '';

  environment.etc."xdg/spectaclerc".text = ''
    [General]
    rememberSelectionRect=Never
  '';

  environment.etc."xdg/plasma-localerc".text = ''
    [Translations]
    LANGUAGE=ko:en_US
  '';

  # KColorScheme reads colors from kdeglobals groups and falls back to its
  # built-in defaults when they are absent, so the ColorScheme name alone does
  # not set Qt app colors. Append the scheme's color groups from the packaged
  # file. Breeze Light is only the baseline; Plasma switches by time of day.
  environment.etc."xdg/kdeglobals".source =
    pkgs.runCommand "kdeglobals" { nativeBuildInputs = [ pkgs.gawk ]; }
      ''
        cat > $out <<'EOF'
        [General]
        ColorScheme=BreezeLight
        TerminalApplication=ghostty

        [Icons]
        Theme=breeze

        [KDE]
        AutomaticLookAndFeel=true
        DefaultDarkLookAndFeel=org.kde.breezedark.desktop
        DefaultLightLookAndFeel=org.kde.breeze.desktop
        LookAndFeelPackage=org.kde.breeze.desktop

        [Locale]
        Language=ko:en_US
        EOF
        awk '
          /^\[/ { keep = ($0 ~ /^\[(Colors|ColorEffects):/ || $0 == "[WM]") }
          keep { print }
        ' ${pkgs.kdePackages.breeze}/share/color-schemes/BreezeLight.colors >> $out
      '';
}
