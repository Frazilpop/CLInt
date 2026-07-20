# CLInt

```text
   /\      .---------.
  /##\     | .-----. |  .----------.    \|/       ___                            ____                      ___
 / o o \   |+| o o |b|  | (o)  (o) |   .---.    /o o o\    /\___/\    .---.    /      \        ___       .[___].
 | \_/ |   | | \_/ |a|  |   \__/   |  / o o \   \  -  /   ( o   o )  / o o \  |  o  o  |     / o o \     | o o |
/|#####|\  | '-----' |  | [======] |  | \_/ |  /=======\  (  \_/  )  | \_/ |  |  \__/  |  --(  \_/  )--  | \_/ |
  ^^ ^^    '---------'  '----------'   \___/    ~ ~ ~ ~    -------   |/\/\/|   \______/       \___/      '-----'
```

A full-screen launcher for games and videos on
Windows. Designed for speed and simplicity.

## Load the following

- **STEAM GAMES** — scans Steam's appmanifest files (no network) and
  launches via `steam://`. Non-Steam shortcuts from `shortcuts.vdf` work
  too.
- **LOCAL GAMES** — launches `.lnk` shortcuts from a configurable folder,
  tracking the game by its target exe.
- **VIDEOS** — a folder browser that plays files via VLC fullscreen.
- **SETTINGS** — video and game-shortcut folders, picked with the gamepad,
  persisted to `settings.json`.

## TDP – Motion Assistant

  Built-in support for machines with GDP Motion Assistant. RB
  cycles between default and per-game wattage profile, applied at launch with
  Motion Assistant's bundled `ryzenadj` (works unelevated because its
  driver is already loaded) and restored when the game exits. Stored in
  `tdp-settings.json`. Auto-detected: without Motion Assistant the
  feature is hidden and CLInt is a plain launcher.

## Controls

D-pad up/down to move, left/right (or Y) to switch tabs, A/Enter to
launch, B to go back/quit, RB to cycle TDP for the highlighted game.

The controller is read natively via XInput. Keyboard works too.

## Install

Put this folder anywhere and run
`Install.bat`. The installer copies the icon to `%LOCALAPPDATA%\CLInt`

## HotKey

On launch there is the option to bind a global hardware key
that opens/hides the CLInt menu from anywhere: this requires AutoHotkey v2, which is installed if
you agree, asks you to **press the shortkut key you want**, and wires it up. This can be skipped
and the desktop shortcut alone is a complete install.

## Updating

**SETTINGS → Check for updates**, then press A. Git installs update via
git pull.
