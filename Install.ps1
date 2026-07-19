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

# --- 3. Optional: bind a hardware key to toggle the menu --------------
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
        Write-Host "  the menu key next to right Ctrl / the GPD 'page icon' key)." -ForegroundColor DarkGray
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

        $startupLnk = $wsh.CreateShortcut((Join-Path ([Environment]::GetFolderPath('Startup')) 'SteamMenuKey.lnk'))
        $startupLnk.TargetPath = $ahk
        $startupLnk.Arguments  = "`"$(Join-Path $here 'SteamMenuKey.ahk')`""
        $startupLnk.Save()
        Write-Host "  Startup entry created (hotkey loads on every boot)" -ForegroundColor Green

        Start-Process $ahk -ArgumentList "`"$(Join-Path $here 'SteamMenuKey.ahk')`""
        Write-Host "  Hotkey is active NOW - press it to test." -ForegroundColor Cyan
    }
} else {
    Write-Host "  Skipped. The desktop shortcut does everything; re-run Install.ps1" -ForegroundColor DarkGray
    Write-Host "  if you want the hotkey later." -ForegroundColor DarkGray
}

Write-Host ""
Write-Host "  Done." -ForegroundColor Magenta
Write-Host ""
Read-Host "  Press Enter to close"
