# CLInt

```
   .---.
  / o o \    
  | \_/ |      "Hello. I'm your new friend, CLInt."
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

Download this folder as a ZIP. Extract anywhere and run `Install.bat`.
Answer its few questions with the arrow keys and Enter; it creates a
desktop shortcut (the icon is staged to `%LOCALAPPDATA%\CLInt`) and
opens CLInt when it finishes.

Tabs are set up on CLInt's first launch, with the same gamepad-driven
pickers the SETTINGS tab uses — nothing to type, and everything can be
changed later in SETTINGS.

## How to Uninstall

Run `Uninstall.bat`. It stops CLInt and the hotkey, removes the desktop
shortcut, startup entry and staged icon, and asks whether to keep your
settings and history (kept by default, so a reinstall picks them straight
back up). Delete the folder afterwards if you want CLInt gone completely.

## TDP – Motion Assistant support (for WIN GPD Devices)

  Built-in support for machines with GDP Motion Assistant. RB
  cycles between default and per-game wattage profile, applied with
  Motion Assistant's bundled `ryzenadj` (works unelevated because its
  driver is already loaded), re-asserted just after the game starts
  (Motion Assistant's own auto-TDP would otherwise override it moments
  in) and restored when the game exits. Stored in
  `tdp-settings.json`. 
  
  This feature is auto-detected and hidden if Motion Assistant is not installed.

## Controls

D-pad up/down to move, left/right (or Y) to switch tabs, A/Enter to
launch, B to go back/quit, RB to cycle TDP for the highlighted game.

The controller is read natively via XInput. Keyboard works too.

The mouse works as well: hover to highlight, click to launch, click a
tab name to switch to it, and scroll with the wheel. It can be turned
off with **SETTINGS → Mouse support**.

## HotKey

During installation there is the option to bind a global hardware key
that opens/hides the CLInt menu from anywhere: this requires AutoHotkey v2, which is installed if
you agree. This can be skipped if you're prefer, and CLInt can still be loaded from the desktop shortcut.

## Updating

**SETTINGS → Check for updates**, then press A. Git installs update via
git pull. Optionally check for new updates on launch.
