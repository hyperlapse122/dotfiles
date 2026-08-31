---
title: "Customize Ghostty Terminal Aesthetics, Keybindings, and Behavior"
date: "2026-08-31"
artifact_contract: "ce-unified-plan/v1"
artifact_readiness: "implementation-ready"
product_contract_source: "ce-brainstorm"
execution: "code"
---

## Goal Capsule

- **Objective:** Establish a high-contrast, developer-friendly Ghostty terminal configuration across dotfiles desktop environments featuring Catppuccin Mocha theming, refined window opacity and blur, balanced padding, intuitive split navigation, interactive URL handling, Kitty image protocol support, and robust scrollback history.
- **Means:** Update `dot_config/ghostty/config.tmpl` to configure Catppuccin Mocha theme, 0.95 opacity with background blur, 12px balanced padding, blinking block cursor, intuitive split/tab shortcuts, URL detection and launching, and 50,000-line scrollback buffer with silent bell while preserving font coupling from `.chezmoidata/fonts.yaml` (KD1-KD6, KTD1-KTD3).
- **Product Authority:** Dotfiles repository terminal emulator configuration (`dot_config/ghostty/config.tmpl`).
- **Open Blockers:** None.

---

## Product Contract

### Summary

Upgrade the managed Ghostty configuration in `dot_config/ghostty/config.tmpl` with Catppuccin Mocha theming, refined window optics (0.95 opacity with active background blur), 12px balanced padding, and a blinking block cursor. Introduce intuitive split shortcuts (`Ctrl+Shift+D`/`S`, `Alt+Arrows`, `Ctrl+Shift+Z`), URL detection with click-to-open, Kitty image protocol support, and 50,000 lines of scrollback with a silent bell, while preserving centralized font coupling to `.chezmoidata/fonts.yaml`.

### Problem Frame

The baseline Ghostty template established font coupling, basic opacity, and quick-terminal shortcuts, but left the color scheme on default and lacked window padding, cursor customization, structured split-pane navigation, URL interaction controls, and fine-tuned terminal history limits. Enhancing these settings provides an ergonomic daily terminal environment with clear text contrast, modern visual aesthetics, and efficient multitasking workflows.

### Key Decisions

- KD1. **Catppuccin Mocha Color Theme** `(session-settled: user-directed — chosen over Tokyo Night, Gruvbox, Dracula: balanced pastel dark aesthetic)`
  - Rationale: Catppuccin Mocha offers high text contrast with a soothing dark palette that complements both KDE Breeze Dark and GNOME environments.
  - Governs R1.
- KD2. **Refined Opacity and Background Blur** `(session-settled: user-directed — chosen over 0.9 투명도: 0.95 불투명도로 텍스트 대비 향상 및 배경 블러 유지)`
  - Rationale: An opacity of 0.95 maintains a subtle modern desktop blur while maximizing text legibility for dense code and log output.
  - Governs R2.
- KD3. **Blinking Block Cursor and Balanced Window Padding** `(session-settled: user-directed — chosen over 기본/빔 커서 및 얇은 여백: 시각적 집중도와 정돈된 UI 여백 제공)`
  - Rationale: A 12px balanced padding prevents terminal text from touching window borders, while a blinking block cursor provides clear position tracking.
  - Governs R3, R4.
- KD4. **Intuitive Split-Pane and Window Shortcuts** `(session-settled: user-directed — chosen over Vim 스타일 HJKL 및 기본 키바인딩: Ctrl+Shift+D/S 분할 및 Alt+방향키 이동으로 직관적 제어)`
  - Rationale: Explicit directional split and navigation keybindings enable rapid terminal tiling without modal state confusion or tmux prefix dependencies.
  - Governs R5, R6, R7, R8.
- KD5. **Developer-Focused History and Notification Defaults** `(session-settled: user-directed — chosen over 기본값 및 무제한 모드: 스크롤백 5만줄, 무음 벨, 프로세스 실행 중 닫기 확인)`
  - Rationale: 50,000 lines of scrollback accommodate extensive test and build outputs without unbounded memory growth, paired with a silent bell and safety prompt on closing active processes.
  - Governs R9, R10, R11.
- KD6. **Interactive URL Handling and Kitty Graphics Protocol** `(session-settled: user-directed — chosen over 수동 URL 복사 및 텍스트 전용 모드: 자동 링크 감지 및 터미널 내 이미지 렌더링 활성화)`
  - Rationale: Built-in URL detection with direct click-to-open streamlines web links, and native Kitty image protocol support enables terminal image rendering tools.
  - Governs R12, R13.

### Requirements

**Theming and Visual Styling**
- R1. Ghostty applies the `catppuccin-mocha` built-in color theme (`theme = catppuccin-mocha`).
- R2. Window background opacity is set to `0.95` with background blur enabled (`background-opacity = 0.95`, `background-blur = true`).
- R3. Terminal window applies 12px horizontal and vertical padding with balanced spacing and extended background color (`window-padding-x = 12`, `window-padding-y = 12`, `window-padding-balance = true`, `window-padding-color = extend`).
- R4. Cursor is configured as a blinking block (`cursor-style = block`, `cursor-style-blink = true`).

**Window Splits and Keybindings**
- R5. Split pane creation is mapped to directional shortcuts: right split on `ctrl+shift+d=new_split:right` and down split on `ctrl+shift+s=new_split:down`.
- R6. Split pane navigation allows directional focus switching via `alt+left=goto_split:left`, `alt+right=goto_split:right`, `alt+up=goto_split:top`, and `alt+down=goto_split:bottom`.
- R7. Surface controls include closing active surface on `ctrl+shift+w=close_surface`, toggling split zoom on `ctrl+shift+z=toggle_split_zoom`, and balancing splits on `ctrl+shift+equal=equalize_splits`.
- R8. Tab navigation and quick-terminal shortcuts remain configured (`ctrl+shift+t=new_tab`, `ctrl+page_up=previous_tab`, `ctrl+page_down=next_tab`, `global:ctrl+grave_accent=toggle_quick_terminal`).

**Terminal Behavior and Protocol Integration**
- R9. Scrollback history limit is configured to 50,000 lines (`scrollback-limit = 50000`).
- R10. Terminal audio bell is disabled (`bell-action = none`).
- R11. Window close confirmation is enabled for running processes (`confirm-close-surface = true`).
- R12. URL detection and interactive link launching are enabled (`link-url = true`, `open-url-on-click = true`, `url-launcher = auto`).
- R13. Kitty graphics protocol support is enabled and verified for terminal image rendering.
- R14. Font family and size continue to render dynamically from `.chezmoidata/fonts.yaml` (`fonts.families.mono` and `fonts.sizes.terminal`).

### Key Flows

- F1. **Split Pane Multitasking Flow**
  - **Trigger:** Developer needs adjacent terminal panels for server logs and CLI commands.
  - **Actors:** Developer, Ghostty Terminal.
  - **Steps:**
    1. Developer presses `Ctrl+Shift+D` to split the active window horizontally to the right.
    2. Developer presses `Ctrl+Shift+S` to split the right pane vertically downwards.
    3. Developer navigates between panes using `Alt+Left`/`Right`/`Up`/`Down`.
    4. Developer zooms into a single pane using `Ctrl+Shift+Z` and restores split layout by pressing `Ctrl+Shift+Z` again.
  - **Covered by:** R5, R6, R7.

- F2. **Interactive URL Launch Flow**
  - **Trigger:** Command output contains a web URL (e.g., git repo, pull request link).
  - **Actors:** Developer, Ghostty Terminal, Default Browser.
  - **Steps:**
    1. Ghostty detects URL pattern in terminal buffer and highlights/underlines on hover.
    2. Developer clicks the link.
    3. Ghostty launches the target URL directly in the system default web browser.
  - **Covered by:** R12.

### Acceptance Examples

- AE1. **Visual Styling Verification**
  - **Given:** Ghostty is launched on a desktop session.
  - **When:** Terminal renders prompt and text.
  - **Then:** Color palette matches Catppuccin Mocha, background displays 0.95 opacity with blur, interior padding is 12px from window edges, and cursor is a blinking solid block.
  - **Covers:** R1, R2, R3, R4.

- AE2. **Split and Surface Keybindings Verification**
  - **Given:** A single Ghostty window is open.
  - **When:** Developer presses `Ctrl+Shift+D` followed by `Alt+Left`.
  - **Then:** A new right pane opens in the same working directory and focus shifts back to the left pane.
  - **Covers:** R5, R6.

- AE3. **URL and Image Protocol Verification**
  - **Given:** Terminal displays text containing `https://github.com` and executes a Kitty graphics protocol image preview command.
  - **When:** User clicks the link or views graphic output.
  - **Then:** Link opens in browser and graphic renders directly in terminal cells.
  - **Covers:** R12, R13.

### Scope Boundaries

**Deferred for later**
- Dynamic light/dark theme switching synchronized with KDE Night Light (can be added once Ghostty upstream desktop-theme integration matures).
- Custom keybinds for font resizing or tab renaming.

**Outside this feature's identity**
- Modifying dotfiles global font definitions in `.chezmoidata/fonts.yaml`.
- Installing external shell prompt themes or third-party statusline extensions.

---

## Planning Contract

### Key Technical Decisions

- KTD1. **Template-Driven Ghostty Configuration**
  - Single authoritative source in `dot_config/ghostty/config.tmpl` deployed to `~/.config/ghostty/config` via chezmoi.
  - Governs R1, R2, R3, R4, R5, R6, R7, R8, R9, R10, R11, R12, R13, R14.
- KTD2. **Dynamic Font Coupling Preservation**
  - Font family and size directives continue to interpolate from `.chezmoidata/fonts.yaml` (`fonts.families.mono` and `fonts.sizes.terminal`).
  - Governs R14.
- KTD3. **Structured Grouped Directives in Template**
  - Directives are organized into clear sections with descriptive comments: Font, Theme, Window Geometry & Padding, Visual Styling, Cursor, Input & Clipboard, Keybindings (Tabs & Splits), URL & Web Links, Quick Terminal, and Terminal Behavior.
  - Governs R1-R13.

### High-Level Design

The implementation modifies `dot_config/ghostty/config.tmpl` to replace the minimal configuration with the fully customized set of options.

```
dot_config/ghostty/config.tmpl
  ├── Font: {{ .fonts.families.mono }}, {{ .fonts.sizes.terminal }}
  ├── Theme: catppuccin-mocha
  ├── Window Geometry & Padding: 128x24, padding-x/y=12, balance=true, color=extend
  ├── Visual Styling: opacity=0.95, blur=true
  ├── Cursor: style=block, blink=true
  ├── Input & Clipboard: copy-on-select=clipboard
  ├── Keybindings: Splits (Ctrl+Shift+D/S), Navigation (Alt+Arrows), Zoom (Ctrl+Shift+Z), Tabs
  ├── URLs & Protocols: link-url=true, open-url-on-click=true, url-launcher=auto, kitty graphics
  └── Behavior: scrollback=50000, bell=none, confirm-close=true
```

---

## Implementation Units

### U1. Update Ghostty Configuration Template

- **Goal:** Update `dot_config/ghostty/config.tmpl` with the complete Ghostty customization suite.
- **Requirements:** R1, R2, R3, R4, R5, R6, R7, R8, R9, R10, R11, R12, R13, R14.
- **Files:** `dot_config/ghostty/config.tmpl`.
- **Approach:**
  1. Open `dot_config/ghostty/config.tmpl`.
  2. Maintain existing font templating comments and directives.
  3. Add `theme = catppuccin-mocha`.
  4. Update background opacity to `0.95` and keep `background-blur = true`.
  5. Add window padding configurations (`window-padding-x = 12`, `window-padding-y = 12`, `window-padding-balance = true`, `window-padding-color = extend`).
  6. Add cursor configuration (`cursor-style = block`, `cursor-style-blink = true`).
  7. Add split pane creation, navigation, zoom, and equalization keybindings.
  8. Add URL handling options (`link-url = true`, `open-url-on-click = true`, `url-launcher = auto`).
  9. Add terminal behavior options (`scrollback-limit = 50000`, `bell-action = none`, `confirm-close-surface = true`).
- **Test Scenarios:**
  - Execute `chezmoi execute-template < dot_config/ghostty/config.tmpl` and confirm all keys render with correct syntax.
  - Verify that `font-family` and `font-size` interpolate from `.chezmoidata/fonts.yaml`.
- **Verification:**
  - `chezmoi execute-template --source "$PWD" < dot_config/ghostty/config.tmpl` succeeds with valid output.

---

## Verification Contract

| Test / Check | Command | Expected Outcome |
|---|---|---|
| Template Rendering | `chezmoi execute-template --source "$PWD" < dot_config/ghostty/config.tmpl` | Outputs valid Ghostty configuration with interpolated font settings |
| Git Cleanliness | `git diff --check` | No whitespace errors or malformed lines |

---

## Definition of Done

1. `dot_config/ghostty/config.tmpl` contains all customized settings (Theme, Opacity/Blur, Padding, Cursor, Keybindings, URLs, Scrollback, Bell).
2. Template renders successfully using `chezmoi execute-template --source "$PWD" < dot_config/ghostty/config.tmpl`.
3. All requirements R1-R14 are fully satisfied.
4. Git working tree is clean and ready for commit.
