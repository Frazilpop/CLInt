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
- **VIDEOS** — a folder browser that plays video files, in CLInt's own
  player or whatever you normally use. Half-watched videos are remembered
  and rise to the top.
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

Tabs are set up on CLInt's first launch, and can be configured or changed 
later in SETTINGS.

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

## Video player

Videos open in your usual player unless you switch to CLInt's own under
**SETTINGS → Video settings → Video player**.

The built-in one needs VLC installed — it plays through VLC's engine
without ever opening the VLC window. No VLC and that row says so, and
videos keep opening the way they do now. Nothing else to install.

Fullscreen and controller-driven: A pauses, B returns to CLInt, the D-pad
seeks and sets volume (up to 150%), X cycles subtitles, Y audio tracks,
and LB/RB step through the folder's other episodes. It remembers where you
stopped.

Subtitles start off. **SETTINGS → Video settings → Subtitles on by
default** turns them on, and works both for an `.srt` sitting beside the
video and for tracks built into the file itself. X switches between them
either way.

## Controls

D-pad or left stick up/down to move, left/right to switch tabs,
A/Enter to launch, B to go back/quit, RB to cycle TDP for the
highlighted game, and Y for the highlighted item's options.

The controller is read natively via XInput. Keyboard works too — the
on-screen prompts name gamepad buttons, and **SETTINGS → Button hints**
switches them to keyboard keys.

The mouse works as well: hover to highlight, click to launch, right-click
for the highlighted item's options, click a tab name to switch to it.
Mouse can be turned off, if required, under: **SETTINGS → Mouse support**.

## Item options

**Y** on the controller, **M** (or the keyboard's own menu key) and
**right-click** all open a short menu of things you can do to whatever is
highlighted. It only ever lists what actually applies to that row.

For a Steam game that is **Uninstall**, which hands over to Steam's own
confirmation — CLInt steps out of the way so the prompt isn't hidden
behind the menu, then refreshes the library once you're done.

Rows with nothing to offer — a non-Steam shortcut, a folder, a settings
row — do nothing at all when you press it.

For a video it is the play count — **+1**, **-1**, or **reset to 0** — and,
when you stopped partway through something, **reset play position**, which
clears the resume marker and drops it out of CURRENTLY WATCHING. The menu
stays open while you adjust, so a count can be nudged more than once.

## HotKey

A global hardware key that opens/hides the CLInt menu from anywhere. Can
be set up when running the installer or found ynder **SETTINGS → Menu key**
It requires AutoHotkey v2, which either side willinstall for you. Skipping 
it entirely is fine; the desktop shortcut does the same job.

Press it and nothing happens? **SETTINGS → Menu key** shows whether it is
bound; the tray icon's tooltip names the key too.

## Updating

**SETTINGS → Check for updates**, then press A. Git installs update via
git pull. Optionally check for new updates on launch.
