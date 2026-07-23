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
  persisted to `data\settings.json`.
  
## How to Install

Download this folder as a ZIP. Extract anywhere and run `Install.bat`.
Answer its few questions with the arrow keys and Enter; it creates a
desktop shortcut (the icon is staged to `%LOCALAPPDATA%\CLInt`) and
opens CLInt when it finishes.

The folder stays simple: everything you'd run yourself sits at the top
(`Install.bat`, `Uninstall.bat`, and `Launch.ps1`, which starts CLInt
without the shortcut). The app's code lives in `app\` and your settings
and history in `data\` — nothing there needs touching by hand.

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
  `data\tdp-settings.json`. 
  
  This feature is auto-detected and hidden if Motion Assistant is not installed.

## Controls

D-pad or left stick up/down to move, left/right (or Y) to switch tabs,
A/Enter to launch, B to go back/quit, RB to cycle TDP for the
highlighted game.

The controller is read natively via XInput. Keyboard works too.

The mouse works as well: hover to highlight, click to launch, click a
tab name to switch to it. The wheel scrolls the page like a scrollbar —
three rows a notch, further for a flick — and the highlight follows
whatever ends up under the pointer. It can all be turned off with
**SETTINGS → Mouse support**.

## HotKey

A global hardware key that opens/hides the CLInt menu from anywhere. The
installer offers to set one up, and **SETTINGS → Menu key** is where it
lives from then on — choose a key, change it, or switch it off, without
going near the installer. It needs AutoHotkey v2, which either side will
install for you. Skipping it entirely is fine; the desktop shortcut does
the same job.

Two ways to choose the key:

- **From a list** — F13–F24, the F-keys, the menu key, media and macro
  keys, or a Ctrl+Alt combination. This is the one to use if the key you
  want sits on an Fn layer: it binds by name, so it doesn't matter how
  (or whether) your keyboard reports the Fn press itself.
- **By pressing it** — the current key is switched off first, so pressing
  it can't open CLInt over the top of the screen asking for it. What was
  detected is shown for confirmation before anything is bound.

Changing the key never restarts anything: the binding is a single file
(`data\menu-key.txt`) that the hotkey script watches. That matters,
because restarting it was where rebinding used to break — AutoHotkey's
"could not close the existing instance", two scripts fighting for one
key, or none left at all. The script reports back what it actually bound,
so SETTINGS shows you the truth (`F13`, or `F13 (not working)`) instead
of what was merely asked for.

The key press itself does nothing but read `data\clint.hwnd` — the window
handle CLInt records at startup — so it stays instant, and there is no
process scanning to be slow or fail. It loads at logon from
`HKCU\...\Run` and prefers AutoHotkey's UI Access build, so the key still
fires when something elevated is in front.

Press it and nothing happens? **SETTINGS → Menu key** shows whether it is
bound; the tray icon's tooltip names the key too.

## Updating

**SETTINGS → Check for updates**, then press A. Git installs update via
git pull. Optionally check for new updates on launch.
