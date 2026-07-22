# Uninstall.ps1 - removes everything Install.ps1 set up on this machine.
# The CLInt folder itself is yours to delete afterwards (or keep -
# re-running Install.bat brings everything back).

$ErrorActionPreference = 'Stop'
$here = $PSScriptRoot                  # app\
$root = Split-Path $here -Parent       # the CLInt folder

Write-Host ""
Write-Host "  CLInt uninstall" -ForegroundColor Magenta
Write-Host "  Removing the pieces installed from: $root"
Write-Host ""

# Arrow-key chooser, same helper as Install.ps1: up/down moves, Enter picks.
function Read-Choice([string]$Prompt, [string[]]$Options, [int]$Default = 0) {
    Write-Host "  $Prompt " -ForegroundColor Cyan -NoNewline
    Write-Host "(up/down + Enter)" -ForegroundColor DarkGray
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

if (-not (Read-YesNo 'Uninstall CLInt from this machine?')) {
    Write-Host ""
    Write-Host "  Nothing touched." -ForegroundColor Green
    Read-Host "  Press Enter to close"
    exit 0
}
Write-Host ""

# --- 1. Stop anything running ------------------------------------------
# CLInt itself (a powershell running this folder's CLInt.ps1/Launch.ps1)
# and the global hotkey script. Matched by command line, not window title,
# so a hidden or minimized instance is caught too; killing the powershell
# closes its conhost window with it.
$rootRx = [regex]::Escape($root)
foreach ($p in @(Get-CimInstance Win32_Process -Filter "Name = 'powershell.exe'" |
        Where-Object { $_.CommandLine -match $rootRx -and $_.CommandLine -match '(CLInt|Launch)\.ps1' })) {
    try { Stop-Process -Id $p.ProcessId -Force -Confirm:$false } catch {}
    Write-Host "  Stopped running CLInt (PID $($p.ProcessId))" -ForegroundColor Green
}
foreach ($p in @(Get-CimInstance Win32_Process |
        Where-Object { $_.Name -like 'AutoHotkey*' -and $_.CommandLine -match 'CLIntKey\.ahk' })) {
    try { Stop-Process -Id $p.ProcessId -Force -Confirm:$false } catch {}
    Write-Host "  Stopped the hotkey script (PID $($p.ProcessId))" -ForegroundColor Green
}

# --- 2. Shortcuts, startup entry and the staged icon -------------------
# GetFolderPath returns an EMPTY string when a shell folder points
# somewhere that no longer exists, and Join-Path throws on it - which
# under ErrorActionPreference 'Stop' would end this uninstall halfway
# through. Resolve Startup by hand for the same reason Install.ps1 does.
$startupDir = [Environment]::GetFolderPath('Startup')
if (-not $startupDir) { $startupDir = Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\Startup' }
$desktopDir = [Environment]::GetFolderPath('Desktop')
if (-not $desktopDir) { $desktopDir = Join-Path $env:USERPROFILE 'Desktop' }

$pieces = @(
    @{ Path = Join-Path $desktopDir 'CLInt.lnk';    What = 'Desktop shortcut' }
    @{ Path = Join-Path $startupDir 'CLIntKey.lnk'; What = 'Startup hotkey shortcut (pre-v0.2.18)' }
    @{ Path = Join-Path $env:LOCALAPPDATA 'CLInt';  What = 'Staged icon folder' }
)
foreach ($piece in $pieces) {
    if (Test-Path $piece.Path) {
        Remove-Item $piece.Path -Recurse -Force -Confirm:$false
        Write-Host "  Removed: $($piece.What)" -ForegroundColor Green
    }
}
$runKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
if ((Get-ItemProperty $runKey -Name 'CLIntKey' -ErrorAction SilentlyContinue)) {
    Remove-ItemProperty $runKey -Name 'CLIntKey' -Force
    Write-Host "  Removed: Startup hotkey entry" -ForegroundColor Green
}

# --- 3. Personal data (optional) ---------------------------------------
# Settings, histories, per-game TDP, the hotkey binding, error log - the
# data\ folder, plus root leftovers from the pre-v0.2.10 flat layout.
# Kept by default so a reinstall picks up right where you left off.
Write-Host ""
if (Read-YesNo 'Also delete your settings and history?' $false) {
    Remove-Item (Join-Path $root 'data') -Recurse -Force -Confirm:$false -ErrorAction SilentlyContinue
    foreach ($f in @('settings.json', 'tdp-settings.json', 'recent.json',
                     'watch-history.json', 'menu-key.txt', 'error.log',
                     'update-available.txt')) {
        Remove-Item (Join-Path $root $f) -Force -Confirm:$false -ErrorAction SilentlyContinue
    }
    Write-Host "  Settings and history deleted." -ForegroundColor Green
} else {
    Write-Host "  Kept - a reinstall will pick them straight back up." -ForegroundColor Green
}

# --- 4. Done ------------------------------------------------------------
Write-Host ""
Write-Host "  Uninstalled. You can now delete this folder if you want" -ForegroundColor Magenta
Write-Host "  CLInt gone completely." -ForegroundColor Magenta
Write-Host ""
Write-Host "  (VLC and AutoHotkey stay - other things may use them. Remove" -ForegroundColor DarkGray
Write-Host "  them in Windows' installed-apps list if you don't want them.)" -ForegroundColor DarkGray
Write-Host ""
Write-Host "     .---."   -ForegroundColor Cyan
Write-Host "    / o o \"  -ForegroundColor Cyan
Write-Host "    | \_/ |"  -ForegroundColor Cyan
Write-Host "    |/\/\/|"  -ForegroundColor Cyan
Write-Host ""
Write-Host "  CLInt says goodbye" -ForegroundColor Magenta
Write-Host ""
Read-Host "  Press Enter to close"
