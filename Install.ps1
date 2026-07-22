# Install.ps1 - sets up CLInt on this machine.
# Run this from wherever you've put the CLInt folder;
# everything stays in this folder, shortcuts just point at it.

$ErrorActionPreference = 'Stop'
$here = $PSScriptRoot

Write-Host ""
Write-Host "  CLInt setup" -ForegroundColor Magenta
Write-Host "  Installing from: $here"
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
$desktopLnk.Arguments    = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$(Join-Path $here 'Launch.ps1')`""
$desktopLnk.IconLocation = "$(Join-Path $iconDir 'CLInt.ico'),0"
$desktopLnk.Save()
Write-Host "  Desktop shortcut created: CLInt" -ForegroundColor Green

# --- 3. First-run tab setup -------------------------------------------
# Only on a fresh install: an existing settings.json is left untouched.
# Everything chosen here can be changed later in the SETTINGS tab.

# Enter = default, B = Windows folder-browse dialog, '-' = skip (returns $null).
# Typing a path still works, but nobody should have to.
function Select-Folder([string]$Prompt, [string]$Default) {
    while ($true) {
        $ans = Read-Host "  $Prompt [Enter = $Default, B = browse, '-' = skip]"
        if ($ans -eq '-') { return $null }
        if (-not $ans) { return $Default }
        if ($ans -match '^[bB]$') {
            Add-Type -AssemblyName System.Windows.Forms
            $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
            $dlg.Description = $Prompt
            $dlg.ShowNewFolderButton = $true
            if (Test-Path $Default) { $dlg.SelectedPath = $Default }
            # TopMost owner keeps the dialog from opening behind the console.
            $owner = New-Object System.Windows.Forms.Form -Property @{ TopMost = $true; ShowInTaskbar = $false }
            $result = $dlg.ShowDialog($owner)
            $owner.Dispose()
            if ($result -eq 'OK') { return $dlg.SelectedPath }
            continue   # cancelled the dialog - ask again
        }
        return $ans
    }
}

$settingsPath = Join-Path $here 'settings.json'
if (-not (Test-Path $settingsPath)) {
    Write-Host ""
    Write-Host "  Let's set up your tabs (all changeable later in SETTINGS)." -ForegroundColor Cyan
    $tabs = @()

    $steamAns = Read-Host "  Include a Steam games tab? [Y/n]"
    if ($steamAns -notmatch '^[nN]') { $tabs += @{ Type = 'Steam' } }

    $shortDef = Join-Path ([Environment]::GetFolderPath('Desktop')) 'Game Shortcuts'
    $p = Select-Folder 'Folder for a game/app shortcuts tab' $shortDef
    if ($null -ne $p) {
        if (-not (Test-Path $p)) { New-Item -ItemType Directory -Force $p | Out-Null }
        $tabs += @{ Type = 'Shortcuts'; Path = $p }
        Write-Host "  Shortcuts tab: $p" -ForegroundColor Green
    }

    $vidDef = [Environment]::GetFolderPath('MyVideos')
    $p = Select-Folder 'Folder for a videos/files tab' $vidDef
    if ($null -ne $p) {
        $tabs += @{ Type = 'Files'; Path = $p }
        Write-Host "  Videos/files tab: $p" -ForegroundColor Green
    }

    # Launch-time update check: opt-in, matching the SETTINGS default.
    Write-Host ""
    $updAns = Read-Host "  Check for updates when CLInt starts? [y/N]"
    $autoUpd = $updAns -match '^[yY]'

    @{ Tabs = $tabs; AutoUpdateCheck = $autoUpd } | ConvertTo-Json -Depth 5 | Set-Content $settingsPath -Encoding utf8
    Write-Host "  Tabs saved: $($tabs.Count) configured." -ForegroundColor Green
    Write-Host "  Update check at launch: $(if ($autoUpd) { 'on' } else { 'off' })" -ForegroundColor Green
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
    $wantVlc = Read-Host "  Install VLC via winget now? [y/N]"
    if ($wantVlc -match '^[yY]') {
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
    $candidates = @(
        "$env:LOCALAPPDATA\Programs\AutoHotkey\v2\AutoHotkey64.exe",
        "$env:ProgramFiles\AutoHotkey\v2\AutoHotkey64.exe",
        "${env:ProgramFiles(x86)}\AutoHotkey\v2\AutoHotkey64.exe"
    )
    foreach ($c in $candidates) { if (Test-Path $c) { return $c } }
    return $null
}

Write-Host ""
$wantKey = Read-Host "  Bind a hardware key that opens/hides the menu from anywhere? [Y/n]"
if ($wantKey -notmatch '^[nN]') {

    $ahk = Find-Ahk
    if (-not $ahk) {
        $wantAhk = Read-Host "  That needs AutoHotkey v2, which isn't installed. Install it via winget? [Y/n]"
        if ($wantAhk -notmatch '^[nN]') {
            try {
                winget install --id AutoHotkey.AutoHotkey --accept-source-agreements --accept-package-agreements
            } catch {}
            $ahk = Find-Ahk
        }
        if (-not $ahk) {
            Write-Host "  AutoHotkey not available - skipping the hotkey. Install it from" -ForegroundColor Yellow
            Write-Host "  https://www.autohotkey.com (v2) and run Install.ps1 again any time." -ForegroundColor Yellow
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
                Write-Host "  you press it, everywhere. Re-run Install.ps1 to change it." -ForegroundColor Yellow
            }
        }
        Set-Content -Path (Join-Path $here 'menu-key.txt') -Value $keyName -Encoding Ascii

        $startupLnk = $wsh.CreateShortcut((Join-Path ([Environment]::GetFolderPath('Startup')) 'CLIntKey.lnk'))
        $startupLnk.TargetPath = $ahk
        $startupLnk.Arguments  = "`"$(Join-Path $here 'CLIntKey.ahk')`""
        $startupLnk.Save()
        Write-Host "  Startup entry created (hotkey loads on every boot)" -ForegroundColor Green

        Start-Process $ahk -ArgumentList "`"$(Join-Path $here 'CLIntKey.ahk')`""
        Write-Host "  Hotkey is active NOW - press it to test." -ForegroundColor Cyan
    }
} else {
    Write-Host "  Skipped. The desktop shortcut does everything; re-run Install.ps1" -ForegroundColor DarkGray
    Write-Host "  if you want the hotkey later." -ForegroundColor DarkGray
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
Read-Host "  Press Enter to close"
