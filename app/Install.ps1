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
function Find-Ahk {
    # _UIA first. That build runs with UI Access, and without it a global
    # hotkey silently stops working whenever anything elevated is in front
    # (a game with anti-cheat, an admin console): Windows won't deliver the
    # key to a lower-privilege process, and won't let it pull a window to
    # the foreground either. It only exists in an admin-installed
    # AutoHotkey, hence the plain build right behind it.
    $roots = @("$env:ProgramFiles\AutoHotkey\v2", "${env:ProgramFiles(x86)}\AutoHotkey\v2",
               "$env:LOCALAPPDATA\Programs\AutoHotkey\v2")
    foreach ($exe in @('AutoHotkey64_UIA.exe', 'AutoHotkey64.exe', 'AutoHotkey32.exe', 'AutoHotkey.exe')) {
        foreach ($r in $roots) { if (Test-Path (Join-Path $r $exe)) { return (Join-Path $r $exe) } }
    }
    return $null
}

# Is the hotkey script actually running? The only answer that matters -
# every earlier failure here was silent.
function Test-HotkeyLive {
    return [bool]@(Get-CimInstance Win32_Process |
        Where-Object { $_.Name -like 'AutoHotkey*' -and $_.CommandLine -match 'CLIntKey\.ahk' })
}

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

    $ahk = Find-Ahk
    if (-not $ahk) {
        if (Read-YesNo "That needs AutoHotkey v2, which isn't installed. Install it via winget?") {
            try {
                winget install --id AutoHotkey.AutoHotkey --accept-source-agreements --accept-package-agreements
            } catch {}
            $ahk = Find-Ahk
        }
        if (-not $ahk) {
            Write-Host "  AutoHotkey not available - skipping the hotkey. Install it from" -ForegroundColor Yellow
            Write-Host "  https://www.autohotkey.com (v2) and run Install.bat again any time." -ForegroundColor Yellow
        }
    }

    if ($ahk) {
        Write-Host "  AutoHotkey found: $ahk" -ForegroundColor Green
        Write-Host ""
        Write-Host "  Press the key you want to use, now." -ForegroundColor Cyan
        Write-Host "  Best picks are keys you never type with: a handheld's menu/page" -ForegroundColor DarkGray
        Write-Host "  key, a spare F-key, a macro key. Esc keeps the default (AppsKey," -ForegroundColor DarkGray
        Write-Host "  the menu key found next to right Ctrl on full keyboards)." -ForegroundColor DarkGray
        $k = $Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown')
        $vk = $k.VirtualKeyCode

        # Translate the virtual-key code into an AutoHotkey key name.
        $keyName = 'AppsKey'
        if ($vk -eq 0x1B) {
            Write-Host "  Keeping the default: AppsKey" -ForegroundColor Green
        } elseif ($vk -eq 0x5D) {
            Write-Host "  Bound: AppsKey (menu key)" -ForegroundColor Green
        } elseif ($vk -ge 0x70 -and $vk -le 0x87) {
            $keyName = "F$($vk - 0x6F)"
            Write-Host "  Bound: $keyName" -ForegroundColor Green
        } else {
            # Any other key by raw virtual-key code - AutoHotkey accepts vkXX.
            $keyName = 'vk{0:X2}' -f $vk
            $shown = if ($k.Character -and -not [char]::IsControl($k.Character)) { "'$($k.Character)' ($keyName)" } else { $keyName }
            Write-Host "  Bound: $shown" -ForegroundColor Green
            if ($k.Character -match '[a-zA-Z0-9 ]') {
                Write-Host "  Heads-up: that's a typing key - it will open the menu EVERY time" -ForegroundColor Yellow
                Write-Host "  you press it, everywhere. Re-run Install.bat to change it." -ForegroundColor Yellow
            }
        }
        Set-Content -Path (Join-Path $dataDir 'menu-key.txt') -Value $keyName -Encoding Ascii

        # Load at logon from HKCU ...\Run, not a shortcut in the Startup
        # folder. GetFolderPath('Startup') returns an EMPTY string whenever
        # that shell folder points somewhere that no longer exists - and the
        # Join-Path failure that followed killed this installer outright,
        # right here, leaving no startup entry, no running hotkey and no
        # error anyone would see. A registry value has nothing to resolve.
        $ahkArgs = "`"$(Join-Path $here 'CLIntKey.ahk')`""
        $runKey  = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
        if (-not (Test-Path $runKey)) { New-Item $runKey -Force | Out-Null }
        Set-ItemProperty $runKey -Name 'CLIntKey' -Value "`"$ahk`" $ahkArgs"
        Write-Host "  Startup entry created (hotkey loads on every boot)" -ForegroundColor Green

        # Replace any copy already running, then confirm ours stayed up -
        # the _UIA build refuses to start on some systems, and a hotkey that
        # died on launch is indistinguishable from one that was never set up.
        foreach ($p in @(Get-CimInstance Win32_Process |
                Where-Object { $_.Name -like 'AutoHotkey*' -and $_.CommandLine -match 'CLIntKey\.ahk' })) {
            try { Stop-Process -Id $p.ProcessId -Force -Confirm:$false } catch {}
        }
        Start-Process $ahk -ArgumentList $ahkArgs
        Start-Sleep -Milliseconds 900
        if (-not (Test-HotkeyLive) -and $ahk -match '_UIA' -and (Test-Path ($ahk -replace '_UIA', ''))) {
            $ahk = $ahk -replace '_UIA', ''
            Write-Host "  UI Access build wouldn't start - using $(Split-Path $ahk -Leaf)." -ForegroundColor Yellow
            Set-ItemProperty $runKey -Name 'CLIntKey' -Value "`"$ahk`" $ahkArgs"
            Start-Process $ahk -ArgumentList $ahkArgs
            Start-Sleep -Milliseconds 900
        }
        if (Test-HotkeyLive) {
            Write-Host "  Hotkey is active NOW - press $keyName to test." -ForegroundColor Cyan
        } else {
            Write-Host "  The hotkey script did not stay running. Start it by hand to" -ForegroundColor Yellow
            Write-Host "  see the error: `"$ahk`" $ahkArgs" -ForegroundColor Yellow
        }
    }
} else {
    Write-Host "  Skipped. The desktop shortcut does everything; re-run Install.bat" -ForegroundColor DarkGray
    Write-Host "  if you want the hotkey later." -ForegroundColor DarkGray
}
} catch {
    Write-Host ""
    Write-Host "  Hotkey setup didn't complete: $($_.Exception.Message)" -ForegroundColor Yellow
    Write-Host "  Everything else is installed and working - re-run Install.bat" -ForegroundColor Yellow
    Write-Host "  to try the hotkey again." -ForegroundColor Yellow
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
