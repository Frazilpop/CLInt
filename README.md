# CLInt

A fast, gamepad-driven, full-screen launcher for games and videos on
Windows. Pixel-art mascots, four tabs, and no mouse or keyboard needed —
point it at your libraries, press A, play.

## What it does

- **STEAM GAMES** — scans Steam's appmanifest files (no network) and
  launches via `steam://`. Non-Steam shortcuts from `shortcuts.vdf` work
  too.
- **LOCAL GAMES** — launches `.lnk` shortcuts from a configurable folder,
  tracking the game by its target exe.
- **VIDEOS** — a folder browser that plays files via VLC fullscreen.
- **SETTINGS** — video and game-shortcut folders, picked with the gamepad,
  persisted to `settings.json`.
- **Per-game TDP** (only on machines with GPD Motion Assistant) — RB
  cycles default → 12W → 15W → 18W → 5W per game, applied at launch with
  Motion Assistant's bundled `ryzenadj` (works unelevated because its
  driver is already loaded) and restored when the game exits. Stored in
  `tdp-settings.json`. Auto-detected: without Motion Assistant the
  feature stays completely hidden and CLInt is a plain launcher.

## Controls

D-pad up/down to move, left/right (or Y) to switch tabs, A/Enter to
launch, B to go back/quit, RB to cycle TDP for the highlighted game.

The controller is read **natively via XInput** — no key-remapping layer
needed. Keyboard works too, and everything degrades gracefully if the
controller disconnects mid-session.

## Files

| File | Purpose |
| --- | --- |
| `SteamMenu.ps1` | The menu itself. Runs under **conhost**, fullscreen. |
| `Launch.ps1` | Single-instance launcher the desktop shortcut runs: focus / minimize / start. |
| `SteamMenuKey.ahk` | Optional: binds a hardware key to the same toggle (key name read from `menu-key.txt`, default AppsKey). |
| `Install.ps1` / `Install.bat` | One-shot setup: desktop shortcut, plus an optional press-a-key hotkey binding (offers to install AutoHotkey v2 if you want it). |
| `Update.ps1` | The updater behind SETTINGS → Check for updates. |
| `version.txt` | Current version, shown bottom-right in the app. |
| `CLInt.ico` | The Happy Handheld. |

## Install

Put this folder anywhere (a removable drive is fine) and run
`Install.bat`. The installer copies the icon to `%LOCALAPPDATA%\CLInt` so
the desktop shortcut keeps its icon even when the folder's drive mounts
late at boot.

It then offers — entirely optionally — to bind a global hardware key
that opens/hides the menu from anywhere: it installs AutoHotkey v2 if
you agree, asks you to **press the key you want**, and wires it up. Skip
it and the desktop shortcut alone is a complete install.

## Updating

**SETTINGS → Check for updates**, then press A. Git installs update via
`git pull`; plain downloads compare `version.txt` against GitHub and
fetch the latest files. Your settings (folders, TDP, hotkey choice) are
separate files that updates never touch. The menu restarts itself after
a successful update, and the version in the bottom-right corner is the
quick way to see what you're on.

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
