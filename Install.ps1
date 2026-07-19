# Install.ps1 - sets up CLInt on this machine.
# Run this from wherever you've put the CLInt folder;
# everything stays in this folder, shortcuts just point at it.

$ErrorActionPreference = 'Stop'
$here = $PSScriptRoot

Write-Host ""
Write-Host "  CLInt setup" -ForegroundColor Magenta
Write-Host "  Installing from: $here"
Write-Host ""

# --- 1. Find (or install) AutoHotkey v2 -------------------------------
function Find-Ahk {
    $candidates = @(
        "$env:LOCALAPPDATA\Programs\AutoHotkey\v2\AutoHotkey64.exe",
        "$env:ProgramFiles\AutoHotkey\v2\AutoHotkey64.exe",
        "${env:ProgramFiles(x86)}\AutoHotkey\v2\AutoHotkey64.exe"
    )
    foreach ($c in $candidates) { if (Test-Path $c) { return $c } }
    return $null
}

$ahk = Find-Ahk
if (-not $ahk) {
    Write-Host "  AutoHotkey v2 not found - installing via winget..." -ForegroundColor Yellow
    try {
        winget install --id AutoHotkey.AutoHotkey --accept-source-agreements --accept-package-agreements
    } catch {}
    $ahk = Find-Ahk
}
if (-not $ahk) {
    Write-Host "  Could not install AutoHotkey automatically." -ForegroundColor Red
    Write-Host "  Install it from https://www.autohotkey.com (v2), then run Install.ps1 again."
    Write-Host "  (The menu itself still works - see the desktop shortcut - only the"
    Write-Host "   hardware-key binding needs AutoHotkey.)"
} else {
    Write-Host "  AutoHotkey found: $ahk" -ForegroundColor Green
}

# --- 2. Icon copy on the system drive ---------------------------------
# If CLInt lives on a removable drive that mounts after logon, Explorer
# draws the desktop before the drive appears and caches a BLANK icon for
# that path. A copy on the system drive is always available at boot.
$iconDir = Join-Path $env:LOCALAPPDATA 'CLInt'
New-Item -ItemType Directory -Force $iconDir | Out-Null
Copy-Item (Join-Path $here 'CLInt.ico') (Join-Path $iconDir 'CLInt.ico') -Force
Write-Host "  Icon staged at $iconDir\CLInt.ico" -ForegroundColor Green

# --- 3. Desktop shortcut (single-instance launcher) -------------------
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

# --- 4. Startup entry + start the hotkey now --------------------------
if ($ahk) {
    $startupLnk = $wsh.CreateShortcut((Join-Path ([Environment]::GetFolderPath('Startup')) 'SteamMenuKey.lnk'))
    $startupLnk.TargetPath = $ahk
    $startupLnk.Arguments  = "`"$(Join-Path $here 'SteamMenuKey.ahk')`""
    $startupLnk.Save()
    Write-Host "  Startup entry created (hotkey loads on every boot)" -ForegroundColor Green

    Start-Process $ahk -ArgumentList "`"$(Join-Path $here 'SteamMenuKey.ahk')`""
    Write-Host "  Hotkey is active NOW - press the menu (page-icon) key to test." -ForegroundColor Cyan
}

Write-Host ""
Write-Host "  Done. Menu key: launch fullscreen / minimize / restore." -ForegroundColor Magenta
Write-Host ""
Read-Host "  Press Enter to close"
