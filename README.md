# CLInt

A gamepad-driven, full-screen terminal launcher for games and videos on
Windows handhelds (built on a GPD Win Mini). Pixel-art mascots, four tabs,
no mouse or keyboard needed — the name is a pun on CLI, because the whole
thing runs in a console window.

## What it does

- **STEAM GAMES** — scans Steam's appmanifest files (no network) and
  launches via `steam://`. Non-Steam shortcuts from `shortcuts.vdf` work
  too.
- **LOCAL GAMES** — launches `.lnk` shortcuts from a configurable folder,
  tracking the game by its target exe.
- **VIDEOS** — a folder browser that plays files via VLC fullscreen.
- **SETTINGS** — video and game-shortcut folders, picked with the gamepad,
  persisted to `settings.json`.
- **Per-game TDP** — RB cycles default → 12W → 15W → 18W → 5W per game,
  applied at launch with GPD Motion Assistant's bundled `ryzenadj` (works
  unelevated because Motion Assistant's driver is already loaded) and
  restored when the game exits. Stored in `tdp-settings.json`.

## Controls

D-pad up/down to move, left/right (or Y) to switch tabs, A/Enter to
launch, B to go back/quit, RB to cycle TDP for the highlighted game.

## Files

| File | Purpose |
| --- | --- |
| `SteamMenu.ps1` | The menu itself. Runs under **conhost**, fullscreen. |
| `Launch.ps1` | Single-instance launcher the desktop shortcut runs: focus / minimize / start. |
| `SteamMenuKey.ahk` | Binds the GPD menu ("page icon") key to the same toggle. |
| `Install.ps1` / `Install.bat` | One-shot setup: AutoHotkey v2, desktop shortcut, startup entry. |
| `CLInt.ico` | The Happy Handheld. |

## Install

Put this folder anywhere (a removable drive is fine) and run
`Install.bat`. The installer copies the icon to `%LOCALAPPDATA%\CLInt` so
the desktop shortcut keeps its icon even when the folder's drive mounts
late at boot.

## Why conhost and not Windows Terminal?

Windows Terminal's WinUI tab row reads the physical gamepad itself (XAML
directional navigation, [not disableable](https://github.com/microsoft/microsoft-ui-xaml/issues/1496))
and steals focus onto the tabs. Conhost has no WinUI, so it's immune, and
`SetConsoleDisplayMode` gives a clean borderless fullscreen.

## Single instance

Every launch path funnels into one window: `SteamMenu.ps1` holds a named
mutex (`Local\CLIntMenu`); a losing second instance just focuses or
minimizes the existing window (matched by the window title `CLInt`) and
exits.
