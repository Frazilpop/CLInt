# Install.ps1 - sets up CLInt on this machine (run via Install.bat at the
# folder root). Everything stays in the CLInt folder, shortcuts just point
# at it: app code in app\, per-machine data in data\.

$ErrorActionPreference = 'Stop'
$here    = $PSScriptRoot                  # app\
$root    = Split-Path $here -Parent       # the CLInt folder
$dataDir = Join-Path $root 'data'
New-Item -ItemType Directory -Force $dataDir | Out-Null
# Reinstall over a pre-v0.2.10 layout: carry the data files into data\
# before anything below looks for them.
foreach ($f in @('settings.json', 'tdp-settings.json', 'menu-key.txt', 'recent.json',
                 'watch-history.json', 'update-available.txt', 'error.log')) {
    $old = Join-Path $root $f
    if ((Test-Path $old) -and -not (Test-Path (Join-Path $dataDir $f))) { Move-Item $old $dataDir }
}

Write-Host ""
Write-Host "  CLInt setup" -ForegroundColor Magenta
Write-Host "  Installing from: $root"
Write-Host ""

# --- 1. Icon copy on the system drive ---------------------------------
# If CLInt lives on a removable drive that mounts after logon, Explorer
# draws the desktop before the drive appears and caches a BLANK icon for
# that path. A copy on the system drive is always available at boot.
$iconDir = Join-Path $env:LOCALAPPDATA 'CLInt'
New-Item -ItemType Directory -Force $iconDir | Out-Null
Copy-Item (Join-Path $here 'CLInt.ico') (Join-Path $iconDir 'CLInt.ico') -Force
Write-Host "  Icon staged at $iconDir\CLInt.ico" -ForegroundColor Green

# --- 2. Desktop shortcut (single-instance launcher) -------------------
# Launch.ps1 behaves like a taskbar button: launch if closed, minimize
# if frontmost, focus otherwise. Hidden window style so no console
# flashes up before conhost takes over.
$wsh = New-Object -ComObject WScript.Shell
$desktopLnk = $wsh.CreateShortcut((Join-Path ([Environment]::GetFolderPath('Desktop')) 'CLInt.lnk'))
$desktopLnk.TargetPath   = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
$desktopLnk.Arguments    = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$(Join-Path $root 'Launch.ps1')`""
$desktopLnk.IconLocation = "$(Join-Path $iconDir 'CLInt.ico'),0"
$desktopLnk.Save()
Write-Host "  Desktop shortcut created: CLInt" -ForegroundColor Green

# --- 3. First-run options ----------------------------------------------
# Tab and folder setup happens inside CLInt itself on first launch - its
# gamepad-driven pickers beat typed console prompts. The installer only
# asks what makes sense before the app ever runs.

# Arrow-key chooser: up/down moves, Enter picks. Returns the index.
# Typed y/n answers tripped people up - a visible selector can't.
function Read-Choice([string]$Prompt, [string[]]$Options, [int]$Default = 0) {
    Write-Host "  $Prompt " -ForegroundColor Cyan -NoNewline
    Write-Host "(up/down + Enter)" -ForegroundColor DarkGray
    # Print the option lines once so the buffer scrolls if it has to,
    # then repaint them in place as the selection moves.
    $Options | ForEach-Object { Write-Host "" }
    $top = [Console]::CursorTop - $Options.Count
    $sel = $Default
    while ($true) {
        for ($i = 0; $i -lt $Options.Count; $i++) {
            [Console]::SetCursorPosition(0, ($top + $i))
            if ($i -eq $sel) { Write-Host "    > $($Options[$i])" -ForegroundColor Magenta -NoNewline }
            else             { Write-Host "      $($Options[$i])" -ForegroundColor DarkGray -NoNewline }
        }
        switch (([Console]::ReadKey($true)).Key) {
            'UpArrow'   { $sel = ($sel - 1 + $Options.Count) % $Options.Count }
            'DownArrow' { $sel = ($sel + 1) % $Options.Count }
            'Enter'     { [Console]::SetCursorPosition(0, ($top + $Options.Count)); return $sel }
        }
    }
}
function Read-YesNo([string]$Prompt, [bool]$DefaultYes = $true) {
    return (Read-Choice $Prompt @('Yes', 'No') $(if ($DefaultYes) { 0 } else { 1 })) -eq 0
}

$settingsPath = Join-Path $dataDir 'settings.json'
if (-not (Test-Path $settingsPath)) {
    Write-Host ""
    # Opt-in, matching the SETTINGS default. Written without a Tabs key
    # so CLInt's own first-launch setup still runs.
    $autoUpd = Read-YesNo 'Check for updates when CLInt starts?' $false
    @{ AutoUpdateCheck = $autoUpd } | ConvertTo-Json | Set-Content $settingsPath -Encoding utf8
    Write-Host "  Update check at launch: $(if ($autoUpd) { 'on' } else { 'off' })" -ForegroundColor Green
    Write-Host "  Tabs get set up in CLInt itself, on first launch." -ForegroundColor Green
} else {
    Write-Host "  Existing settings.json found - keeping your current tabs." -ForegroundColor Green
}

# --- 4. VLC (optional, recommended) -----------------------------------
$vlcFound = $null
try {
    $rp = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\vlc.exe' -ErrorAction SilentlyContinue).'(default)'
    if ($rp -and (Test-Path $rp)) { $vlcFound = $rp }
} catch {}
if (-not $vlcFound) {
    foreach ($base in @($env:ProgramFiles, ${env:ProgramFiles(x86)}, "$env:LOCALAPPDATA\Programs")) {
        if ($base -and (Test-Path (Join-Path $base 'VideoLAN\VLC\vlc.exe'))) { $vlcFound = Join-Path $base 'VideoLAN\VLC\vlc.exe'; break }
    }
}
if ($vlcFound) {
    Write-Host "  VLC found: videos get fullscreen playback and resume markers." -ForegroundColor Green
} else {
    Write-Host ""
    Write-Host "  VLC not detected. CLInt works without it, but with VLC videos" -ForegroundColor Yellow
    Write-Host "  play fullscreen, the menu returns when a video ends, and" -ForegroundColor Yellow
    Write-Host "  partially-watched markers work. (videolan.org)" -ForegroundColor Yellow
    if (Read-YesNo 'Install VLC via winget now?' $false) {
        try {
            winget install --id VideoLAN.VLC --accept-source-agreements --accept-package-agreements
        } catch {}
    }
}

# --- 5. Optional: bind a hardware key to toggle the menu --------------
# Entirely skippable - the desktop shortcut is a complete install on its
# own. The binding needs AutoHotkey v2 (tiny, free), because a global
# hotkey has to live in something that's always running.
#
# The mechanics live in Hotkey.ps1, shared with CLInt's own SETTINGS ->
# Menu key screen, which is where CHANGING the key belongs now. Doing that
# from here meant typing at a console that the old key could bury under a
# fresh copy of CLInt - see the header of Hotkey.ps1.
. (Join-Path $here 'Hotkey.ps1')

Write-Host ""
# Nothing in this section may take the installer down with it: a hotkey is
# the optional extra, and the install that came before it is what actually
# matters. (It used to abort the whole script - see the Run key below.)
try {
if (Read-YesNo 'Bind a hardware key that opens/hides the menu from anywhere?') {

    # A shortcut from a pre-v0.2.18 install would start a second copy of
    # the hotkey at logon, racing this one for the same key.
    $startupDir = [Environment]::GetFolderPath('Startup')
    if (-not $startupDir) { $startupDir = Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\Startup' }
    Remove-Item (Join-Path $startupDir 'CLIntKey.lnk') -Force -ErrorAction SilentlyContinue

    $ahk = Find-AhkExe
    if (-not $ahk) {
        if (Read-YesNo "That needs AutoHotkey v2, which isn't installed. Install it via winget?") {
            try {
                winget install --id AutoHotkey.AutoHotkey --accept-source-agreements --accept-package-agreements
            } catch {}
            $ahk = Find-AhkExe
        }
        if (-not $ahk) {
            Write-Host "  AutoHotkey not available - skipping the hotkey. Install it from" -ForegroundColor Yellow
            Write-Host "  https://www.autohotkey.com (v2), then set the key in CLInt:" -ForegroundColor Yellow
            Write-Host "  SETTINGS -> Menu key." -ForegroundColor Yellow
        }
    }

    if ($ahk) {
        Write-Host "  AutoHotkey found: $ahk" -ForegroundColor Green
        Write-Host ""
        # Reinstalling over a working hotkey: switch the old binding off
        # first, or the key you are about to press launches CLInt over this
        # window mid-setup.
        $sus = Suspend-MenuKey $root
        if (-not $sus.Ok) { Write-Host "  $($sus.Message)" -ForegroundColor Yellow }

        $keyName = 'AppsKey'
        $mode = Read-Choice 'How do you want to choose the key?' @(
            'Pick from a list',
            'Press the key I want to use',
            'Use AppsKey  (the menu key next to right Ctrl)')
        if ($mode -eq 0) {
            # Two steps, because a console chooser can only show a screenful
            # and the full list is longer than that.
            $groups = @(Get-MenuKeyGroups)
            Write-Host ""
            $g = Read-Choice 'Which kind of key?' $groups
            $picks = @(Get-MenuKeyChoices | Where-Object { $_.Group -eq $groups[$g] })
            Write-Host ""
            $p = Read-Choice $groups[$g] @($picks | ForEach-Object { $_.Label.PadRight(18) + $_.Hint })
            $keyName = $picks[$p].Key
        } elseif ($mode -eq 1) {
            Write-Host ""
            Write-Host "  Press the key you want to use, now." -ForegroundColor Cyan
            Write-Host "  Hold Fn as well if the key needs it. Esc keeps AppsKey." -ForegroundColor DarkGray
            $k = [Console]::ReadKey($true)
            if ($k.Key -ne [ConsoleKey]::Escape) {
                $captured = Convert-KeyPressToAhk $k
                if ($captured) { $keyName = $captured }
            }
            if (Test-MenuKeyIsTypingKey $keyName) {
                Write-Host "  Heads-up: that's a typing key - it will open the menu EVERY time" -ForegroundColor Yellow
                Write-Host "  you press it, everywhere. Change it in SETTINGS -> Menu key." -ForegroundColor Yellow
            }
        }

        # Set-MenuKey writes the binding, registers the logon entry (HKCU
        # ...\Run, not a Startup shortcut: GetFolderPath('Startup') returns
        # an EMPTY string when that shell folder points somewhere that no
        # longer exists, and the Join-Path failure that followed used to
        # kill this installer outright), starts the script, and waits for it
        # to confirm the key is really registered.
        Write-Host ""
        # Register the logon entry outright. Set-MenuKey only touches it
        # when it has to start the script, and a script that happens to be
        # running already would otherwise leave a fresh install with no way
        # back after a reboot.
        try { Register-HotkeyStartup $root $ahk } catch {}
        Write-Host "  Setting $(Get-MenuKeyLabel $keyName)..." -ForegroundColor DarkGray
        $res = Set-MenuKey $root $keyName
        if ($res.Ok) {
            Write-Host "  $($res.Message)" -ForegroundColor Cyan
            Write-Host "  Loads on every boot. Change it any time in SETTINGS -> Menu key." -ForegroundColor Green
        } else {
            Write-Host "  $($res.Message)" -ForegroundColor Yellow
            Write-Host "  Try another key in CLInt: SETTINGS -> Menu key." -ForegroundColor Yellow
        }
    }
} else {
    Write-Host "  Skipped. The desktop shortcut does everything; SETTINGS -> Menu key" -ForegroundColor DarkGray
    Write-Host "  sets one up later if you want it." -ForegroundColor DarkGray
}
} catch {
    Write-Host ""
    Write-Host "  Hotkey setup didn't complete: $($_.Exception.Message)" -ForegroundColor Yellow
    Write-Host "  Everything else is installed and working - SETTINGS -> Menu key" -ForegroundColor Yellow
    Write-Host "  inside CLInt sets the key up without re-running this installer." -ForegroundColor Yellow
}

Write-Host ""
Write-Host "  Done." -ForegroundColor Magenta
Write-Host ""
Write-Host "     .---."   -ForegroundColor Cyan
Write-Host "    / o o \"  -ForegroundColor Cyan
Write-Host "    | \_/ |"  -ForegroundColor Cyan
Write-Host "    |/\/\/|"  -ForegroundColor Cyan
Write-Host ""
Write-Host "  Your new friend CLInt says hello" -ForegroundColor Magenta
Write-Host ""
# Let the hello land before anything else happens - CLInt's fullscreen
# window covers this one the moment it opens.
Start-Sleep -Seconds 2
Write-Host "  Opening CLInt..." -ForegroundColor DarkGray
# Same invocation as the desktop shortcut: Launch.ps1 under a hidden
# powershell, which starts conhost fullscreen and foregrounds it. The
# installer window closes by itself right after (no pause in Install.bat).
Start-Process powershell.exe -WindowStyle Hidden -ArgumentList `
    "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$(Join-Path $root 'Launch.ps1')`""
