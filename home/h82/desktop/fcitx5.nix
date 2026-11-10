{ pkgs, ... }:
let
  reloadFcitx5 = "${pkgs.fcitx5}/bin/fcitx5-remote -r 2>/dev/null || true";
in
{
  xdg.configFile."fcitx5/config" = {
    text = ''
      [Hotkey]
      EnumerateWithTriggerKeys=False
      EnumerateForwardKeys=
      EnumerateBackwardKeys=
      AltTriggerKeys=
      EnumerateSkipFirst=False
      ModifierOnlyKeyTimeout=250

      [Hotkey/TriggerKeys]
      0=Hangul

      [Hotkey/ActivateKeys]
      0=Hangul_Hanja

      [Hotkey/DeactivateKeys]
      0=Hangul_Romaja

      [Hotkey/EnumerateGroupForwardKeys]
      0=Super+space

      [Hotkey/EnumerateGroupBackwardKeys]
      0=Shift+Super+space

      [Hotkey/PrevPage]
      0=Up

      [Hotkey/NextPage]
      0=Down

      [Hotkey/PrevCandidate]
      0=Shift+Tab

      [Hotkey/NextCandidate]
      0=Tab

      [Hotkey/TogglePreedit]
      0=Control+Alt+P

      [Behavior]
      ActiveByDefault=False
      resetStateWhenFocusIn=No
      ShareInputState=Program
      PreeditEnabledByDefault=True
      ShowInputMethodInformation=True
      showInputMethodInformationWhenFocusIn=False
      CompactInputMethodInformation=True
      ShowFirstInputMethodInformation=True
      DefaultPageSize=5
      OverrideXkbOption=False
      CustomXkbOption=
      EnabledAddons=
      DisabledAddons=
      PreloadInputMethod=True
      AllowInputMethodForPassword=False
      ShowPreeditForPassword=False
      AutoSavePeriod=30
    '';
    force = true;
    onChange = reloadFcitx5;
  };

  xdg.configFile."fcitx5/profile" = {
    text = ''
      [Groups/0]
      Name=기본값
      Default Layout=us
      DefaultIM=hangul

      [Groups/0/Items/0]
      Name=keyboard-us
      Layout=

      [Groups/0/Items/1]
      Name=hangul
      Layout=

      [GroupOrder]
      0=기본값
    '';
    force = true;
    onChange = reloadFcitx5;
  };

  xdg.configFile."fcitx5/conf/classicui.conf" = {
    text = ''
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
    force = true;
    onChange = reloadFcitx5;
  };

  xdg.configFile."fcitx5/conf/hangul.conf" = {
    text = ''
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
    force = true;
    onChange = reloadFcitx5;
  };

  xdg.configFile."fcitx5/conf/kimpanel.conf" = {
    text = ''
      # 텍스트 아이콘 선호
      PreferTextIcon=False
    '';
    force = true;
    onChange = reloadFcitx5;
  };
}
