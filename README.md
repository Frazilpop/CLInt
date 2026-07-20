# CLInt

```
   .---.
  / o o \    
  | \_/ |      "Hello, I'm your new friend CLInt."
  |/\/\/|
```

Meet CLInt. He's a full-screen launcher for games and videos on
Windows. Designed for speed and simplicity, he's here to help.

## A content loader that won't make you sick and kill you

A minimalist interface with configurable tabs to load the following:

- **STEAM GAMES** — scans Steam's appmanifest and
  launches via `steam://`. Non-Steam shortcuts from `shortcuts.vdf` work
  too.
- **LOCAL GAMES** — launches `.lnk` shortcuts from a configurable folder,
  tracking the game by its target exe.
- **VIDEOS** — a folder browser that plays video files. VLC reccomended for play count tracking and auto resume. Other players supported too.
- **SETTINGS** — deep app customisation,
  persisted to `settings.json`.
  
## How to Install

Download this folder as a ZIP. Extract anywhere and run
`Install.bat`. The installer copies the icon to `%LOCALAPPDATA%\CLInt`

## TDP – Motion Assistant support (for WIN GPD Devices)

  Built-in support for machines with GDP Motion Assistant. RB
  cycles between default and per-game wattage profile, applied at launch with
  Motion Assistant's bundled `ryzenadj` (works unelevated because its
  driver is already loaded) and restored when the game exits. Stored in
  `tdp-settings.json`. 
  
  This feature is auto-detected and hidden if Motion Assistant is not installed.

## Controls

D-pad up/down to move, left/right (or Y) to switch tabs, A/Enter to
launch, B to go back/quit, RB to cycle TDP for the highlighted game.

The controller is read natively via XInput. Keyboard works too.

## HotKey

During installation there is the option to bind a global hardware key
that opens/hides the CLInt menu from anywhere: this requires AutoHotkey v2, which is installed if
you agree. This can be skipped if you're prefer, and CLInt can still be loaded from the desktop shortcut.

## Updating

**SETTINGS → Check for updates**, then press A. Git installs update via
git pull. Optionally check for new updates on launch.
