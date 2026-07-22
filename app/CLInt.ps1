# CLInt.ps1 - fast, gamepad-driven launcher for games and videos.
# Tabs are fully user-configurable (SETTINGS tab): any mix of Steam
# library tabs, shortcut-folder tabs, and file-browser tabs.
#
# Usage:  CLInt.ps1          (interactive menu: arrows/D-pad to move, Enter/A to launch)
#         CLInt.ps1 -List    (just print the Steam games, no menu)

param([switch]$List)

$ErrorActionPreference = 'Stop'

# Single instance: whichever way a second copy gets started (desktop
# shortcut, hotkey via CLIntKey.ahk, direct run), it defers to the
# running one - focus it, or minimize it if it's frontmost - and exits.
if (-not $List) {
    $script:instanceMutex = New-Object System.Threading.Mutex($false, 'Local\CLIntMenu')
    try { $owned = $script:instanceMutex.WaitOne(0) } catch { $owned = $true }   # abandoned mutex = ours now
    if (-not $owned) {
        Add-Type -Namespace Win32 -Name Native -MemberDefinition @'
[DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern IntPtr FindWindowW(string cls, string title);
[DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
[DllImport("user32.dll")] public static extern bool IsIconic(IntPtr h);
[DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int cmd);
[DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
'@
        $hwnd = [Win32.Native]::FindWindowW($null, 'CLInt')
        if ($hwnd -ne [IntPtr]::Zero) {
            # Minimized wins over "foreground" - see Launch.ps1.
            if ([Win32.Native]::IsIconic($hwnd)) {
                [Win32.Native]::ShowWindow($hwnd, 9) | Out-Null                  # SW_RESTORE
                [Win32.Native]::SetForegroundWindow($hwnd) | Out-Null
            } elseif ([Win32.Native]::GetForegroundWindow() -eq $hwnd) {
                [Win32.Native]::ShowWindow($hwnd, 6) | Out-Null                  # SW_MINIMIZE
            } else {
                [Win32.Native]::SetForegroundWindow($hwnd) | Out-Null
            }
        }
        exit 0
    }
}

$Host.UI.RawUI.WindowTitle = 'CLInt'   # matched by Launch.ps1, CLIntKey.ahk and claude-gamepad.ahk

# ------------------------------------------------------ Folder layout ---
# The app's code lives in app\, per-machine data in data\, and the root
# keeps only what a person runs (Install.bat, Uninstall.bat, Launch.ps1).
# A flat copy (the .claude\tests harness copies CLInt.ps1 on its own) has
# no app\ parent, so there the root is wherever this script sits.
$script:rootDir = if ((Split-Path $PSScriptRoot -Leaf) -eq 'app') { Split-Path $PSScriptRoot -Parent } else { $PSScriptRoot }
$script:dataDir = Join-Path $script:rootDir 'data'
if (-not (Test-Path $script:dataDir)) { New-Item -ItemType Directory -Force $script:dataDir | Out-Null }

# One-time migration from the pre-v0.2.10 flat layout, where the data
# files and every script sat at the root. Only acts when leftovers exist:
# moves data files into data\, sweeps stale root script copies (a ZIP
# overlay only adds files; git pull removes its own), and repoints the
# Startup hotkey shortcut at app\CLIntKey.ahk, swapping any running
# old-path hotkey instance so two handlers never race.
try {
    $legacyData = @(@('settings.json', 'tdp-settings.json', 'menu-key.txt', 'recent.json',
                      'watch-history.json', 'update-available.txt', 'error.log') |
        Where-Object { Test-Path (Join-Path $script:rootDir $_) })
    foreach ($f in $legacyData) {
        $old = Join-Path $script:rootDir $f
        if (Test-Path (Join-Path $script:dataDir $f)) { Remove-Item $old -Force }   # stale root copy; data\ wins
        else { Move-Item $old $script:dataDir -Force }
    }
    if ((Split-Path $PSScriptRoot -Leaf) -eq 'app') {
        $lnkPath = Join-Path ([Environment]::GetFolderPath('Startup')) 'CLIntKey.lnk'
        if (Test-Path $lnkPath) {
            $lnk = (New-Object -ComObject WScript.Shell).CreateShortcut($lnkPath)
            $oldAhkRx = [regex]::Escape((Join-Path $script:rootDir 'CLIntKey.ahk'))
            if ($lnk.Arguments -match $oldAhkRx) {
                $lnk.Arguments = "`"$(Join-Path $PSScriptRoot 'CLIntKey.ahk')`""
                $lnk.Save()
                foreach ($p in @(Get-CimInstance Win32_Process |
                        Where-Object { $_.Name -like 'AutoHotkey*' -and $_.CommandLine -match $oldAhkRx })) {
                    try { Stop-Process -Id $p.ProcessId -Force -Confirm:$false } catch {}
                }
                if (Test-Path $lnk.TargetPath) {
                    Start-Process $lnk.TargetPath -ArgumentList "`"$(Join-Path $PSScriptRoot 'CLIntKey.ahk')`""
                }
            }
        }
        foreach ($f in @('Install.ps1', 'Uninstall.ps1', 'Update.ps1', 'CLIntKey.ahk', 'CLInt.ico')) {
            Remove-Item (Join-Path $script:rootDir $f) -Force -ErrorAction SilentlyContinue
        }
    }
} catch {}   # a locked leftover must never stop the menu from starting

# App version: version.txt ships with the code and is bumped on every
# update, so the in-app corner display and the updater can compare.
$appVersion = try { (Get-Content (Join-Path $script:rootDir 'version.txt') -TotalCount 1).Trim() } catch { '?' }

# ------------------------------------------------------------- Steam ---
function Get-SteamPath {
    $p = (Get-ItemProperty "HKCU:\Software\Valve\Steam" -ErrorAction SilentlyContinue).SteamPath
    if (-not $p) { $p = (Get-ItemProperty "HKLM:\SOFTWARE\WOW6432Node\Valve\Steam" -ErrorAction SilentlyContinue).InstallPath }
    if (-not $p) { throw "Steam installation not found in the registry." }
    return $p -replace '/', '\'
}

function Start-SteamGame($launchId) {
    # Firing steam://rungameid/ while Steam is closed boots the full Steam
    # client UI on top of the menu. Cold-start steam.exe ourselves with
    # -silent (tray only) and hand it the same URL; the launch is queued
    # until the client is ready. With Steam already up, the plain URL is
    # the fastest path and changes nothing.
    if (Get-Process steam -ErrorAction SilentlyContinue) {
        Start-Process "steam://rungameid/$launchId"
    } else {
        try {
            Start-Process (Join-Path (Get-SteamPath) 'steam.exe') `
                -ArgumentList '-silent', "steam://rungameid/$launchId"
        } catch {
            Start-Process "steam://rungameid/$launchId"   # no registry path: old behaviour
        }
    }
}

function Get-InstalledGames {
    $steam = Get-SteamPath
    $vdfPath = Join-Path $steam 'steamapps\libraryfolders.vdf'
    $libs = @($steam)
    if (Test-Path $vdfPath) {
        $vdf = Get-Content $vdfPath -Raw
        $libs = [regex]::Matches($vdf, '"path"\s+"([^"]+)"') |
            ForEach-Object { $_.Groups[1].Value -replace '\\\\', '\' } |
            Select-Object -Unique
    }
    $games = foreach ($lib in $libs) {
        foreach ($m in (Get-ChildItem (Join-Path $lib 'steamapps\appmanifest_*.acf') -ErrorAction SilentlyContinue)) {
            $c = Get-Content $m.FullName -Raw
            $name  = [regex]::Match($c, '"name"\s+"([^"]+)"').Groups[1].Value
            $appid = [regex]::Match($c, '"appid"\s+"(\d+)"').Groups[1].Value
            $installdir = [regex]::Match($c, '"installdir"\s+"([^"]+)"').Groups[1].Value
            if ($name -and $appid -and $name -notmatch 'Redistributables|Steamworks Common') {
                $dir = if ($installdir) { Join-Path $lib "steamapps\common\$installdir" } else { $null }
                [pscustomobject]@{ Name = $name; AppId = $appid; LaunchId = $appid; Exe = $null; Dir = $dir }
            }
        }
    }
    return @($games | Sort-Object Name)
}

# Steam keeps a userdata folder for every account that has ever signed in
# on this machine, plus non-numeric stubs ('anonymous', 'ac', '0'). Reading
# config out of all of them is how long-deleted non-Steam shortcuts come
# back from the dead - and multiply, once per stale folder. Resolve the one
# live account instead: the running client's ActiveUser, else the most
# recently logged-in account in loginusers.vdf.
$script:steamUserDir = $null
function Get-SteamUserDir {
    if ($null -ne $script:steamUserDir) { return $script:steamUserDir }
    $script:steamUserDir = ''
    $steam = Get-SteamPath
    $ids = @()
    # 0 while the client is closed, so it's a hint and not the whole answer.
    $active = (Get-ItemProperty "HKCU:\Software\Valve\Steam\ActiveProcess" -ErrorAction SilentlyContinue).ActiveUser
    if ($active) { $ids += [string]$active }
    $login = Join-Path $steam 'config\loginusers.vdf'
    if (Test-Path $login) {
        $raw = Get-Content $login -Raw
        $ids += [regex]::Matches($raw, '(?s)"(7656\d{13})"\s*\{(.*?)\}') |
            ForEach-Object {
                $ts = [regex]::Match($_.Groups[2].Value, '"Timestamp"\s+"(\d+)"').Groups[1].Value
                [pscustomobject]@{
                    # The folder is named after the 32-bit account id, which is
                    # the SteamID64 minus the base of the individual-account range.
                    Id = [string]([uint64]$_.Groups[1].Value - 76561197960265728)
                    Ts = if ($ts) { [int64]$ts } else { 0 }
                }
            } | Sort-Object Ts -Descending | ForEach-Object { $_.Id }
    }
    foreach ($id in $ids) {
        $d = Join-Path $steam "userdata\$id"
        if (Test-Path $d) { $script:steamUserDir = $d; break }
    }
    return $script:steamUserDir
}

function Get-NonSteamGames {
    # Non-Steam shortcuts live in a binary VDF: userdata\<account>\config\shortcuts.vdf.
    # steam://rungameid/ needs the 64-bit shortcut id: (appid << 32) | 0x02000000.
    $dir = Get-SteamUserDir
    if (-not $dir) { return @() }
    $vdf = Join-Path $dir 'config\shortcuts.vdf'
    if (-not (Test-Path $vdf)) { return @() }
    $raw = [System.Text.Encoding]::GetEncoding(28591).GetString([System.IO.File]::ReadAllBytes($vdf))
    $seen = @{}
    $found = foreach ($entry in ($raw -split "\x08\x08")) {
        $name = [regex]::Match($entry, "(?i)\x01appname\x00([^\x00]*)\x00").Groups[1].Value
        $idm  = [regex]::Match($entry, "(?is)\x02appid\x00(.{4})")
        if (-not $name -or -not $idm.Success) { continue }   # pre-2019 entries have no appid field
        $idBytes = [byte[]]($idm.Groups[1].Value.ToCharArray() | ForEach-Object { [byte]$_ })
        $appid = [BitConverter]::ToUInt32($idBytes, 0)
        # Entries written before Steam stored a real appid keep a zero one and
        # the client derives the id at runtime; rungameid can't launch those,
        # so they would only ever be dead rows in the list.
        if ($appid -eq 0 -or $seen.ContainsKey($appid)) { continue }
        $seen[$appid] = $true
        $exe = [regex]::Match($entry, "(?i)\x01exe\x00([^\x00]*)\x00").Groups[1].Value -replace '"', ''
        [pscustomobject]@{
            Name     = $name
            AppId    = $appid
            LaunchId = ([uint64]$appid -shl 32) -bor 0x02000000
            Exe      = $exe
            Dir      = $null
        }
    }
    return @($found | Sort-Object Name)
}

# Steam collections (the library's groupings) live in per-account
# cloudstorage JSON: entries keyed "user-collections.<id>" whose value is
# itself stringified JSON with id, name, and the member appids in 'added'.
# Deleted collections are flagged; dynamic (filter-based) ones can't be
# evaluated offline and are skipped.
$script:steamCols = $null
function Get-SteamCollections {
    if ($null -ne $script:steamCols) { return $script:steamCols }
    $cols = @{}
    try {
        $dir = Get-SteamUserDir   # live account only - stale ones list collections that no longer exist
        foreach ($f in (Get-ChildItem (Join-Path $dir 'config\cloudstorage\cloud-storage-namespace-*.json') -ErrorAction SilentlyContinue)) {
            try {
                foreach ($e in (Get-Content $f.FullName -Raw | ConvertFrom-Json)) {
                    $key = if ($e -is [array]) { [string]$e[0] } else { [string]$e.key }
                    if ($key -notlike 'user-collections.*') { continue }
                    $rec = if ($e -is [array]) { $e[1] } else { $e }
                    if ($rec.is_deleted -or -not $rec.value) { continue }
                    $v = $rec.value | ConvertFrom-Json
                    if (-not $v.name -or $null -ne $v.filterSpec) { continue }
                    $cols[[string]$v.id] = [pscustomobject]@{
                        Id    = [string]$v.id
                        Name  = [string]$v.name
                        Added = @(@($v.added) | Where-Object { $null -ne $_ } | ForEach-Object { [string]$_ })
                    }
                }
            } catch {}
        }
    } catch {}
    $script:steamCols = @($cols.Values | Sort-Object Name)
    return $script:steamCols
}

# ----------------------------------------------------------- Settings ---
# settings.json holds the tab configuration: an array of
#   { "Type": "Steam" }                          - the whole Steam library
#   { "Type": "Steam", "Collection": "<name>",
#     "CollectionId": "<id>" }                   - one Steam collection only
#   { "Type": "Shortcuts", "Path": "..." }       - .lnk shortcuts in a folder
#   { "Type": "Files",     "Path": "..." }       - file browser (videos via VLC)
# in display order; a SETTINGS tab is always appended. Optional per-tab
# fields (both settable in-app): "Name" overrides the auto-derived title,
# "Icon" picks a mascot from the catalog. A top-level "Theme" selects the
# color theme.
$settingsFile = Join-Path $script:dataDir 'settings.json'
$settings = @{}
if (Test-Path $settingsFile) {
    (Get-Content $settingsFile -Raw | ConvertFrom-Json).PSObject.Properties |
        ForEach-Object { $settings[$_.Name] = $_.Value }
}
$firstRunSetup = $false
if (-not $settings.ContainsKey('Tabs')) {
    # (Key-existence check, not truthiness: an empty Tabs array is a valid
    # deliberate config - all tabs removed - and must not resurrect defaults.)
    if ($settings['LocalShortcutDir'] -or $settings['VideoRoot']) {
        # Migration from the fixed-tab era's two folder keys.
        $shortcutDir = if ($settings['LocalShortcutDir']) { $settings['LocalShortcutDir'] }
                       else { Join-Path ([Environment]::GetFolderPath('Desktop')) 'Game Shortcuts' }
        $filesDir    = if ($settings['VideoRoot']) { $settings['VideoRoot'] }
                       else { [Environment]::GetFolderPath('MyVideos') }
        $settings['Tabs'] = @(
            @{ Type = 'Steam' }
            @{ Type = 'Shortcuts'; Path = $shortcutDir }
            @{ Type = 'Files';     Path = $filesDir }
        )
    } else {
        # True first run (fresh install, or after a settings reset): seed a
        # Steam tab if Steam is on this machine, and let the in-app setup
        # offer the folder tabs once the UI is up - its gamepad pickers are
        # the right tool, not installer-console prompts.
        $script:firstRunSetup = $true
        $steamHere = $false
        try { $steamHere = [bool](Get-SteamPath) } catch {}
        $settings['Tabs'] = if ($steamHere) { ,@{ Type = 'Steam' } } else { @() }
    }
}
$settings.Remove('LocalShortcutDir'); $settings.Remove('VideoRoot')
# 'Fullscreen' was once persisted by the toggle; a stored 'false' made
# every launch start windowed (and skip the font setup). Launches always
# go fullscreen now - the SETTINGS button toggles the session only.
$settings.Remove('Fullscreen')
# JSON round-trips tab entries as PSCustomObjects; normalize to hashtables.
$settings['Tabs'] = @($settings['Tabs'] | ForEach-Object {
    if ($_ -is [hashtable]) { $_ }
    else { $t = @{}; $_.PSObject.Properties | ForEach-Object { $t[$_.Name] = $_.Value }; $t }
})

function Save-Settings {
    $settings | ConvertTo-Json -Depth 5 | Set-Content $settingsFile -Encoding utf8
}

# The Steam library is only scanned when a Steam tab is configured (or for
# -List); machines without Steam just don't get Steam tabs. Whether the
# library includes non-Steam shortcuts is a SETTINGS toggle (default on).
$nonSteamEnabled = $settings['NonSteam'] -ne $false
function Get-SteamLibrary {
    $g = @(Get-InstalledGames)
    if ($script:nonSteamEnabled) { $g += @(Get-NonSteamGames) }
    return @($g | Sort-Object Name)
}
$games = @()
$needSteam = $List -or @($settings['Tabs'] | Where-Object { $_.Type -eq 'Steam' }).Count -gt 0
if ($needSteam) {
    try { $games = @(Get-SteamLibrary) } catch {}
}

# Shortcut-folder tabs: .lnk files collected in one folder, launched via
# the shortcut itself; exit is tracked by the target exe.
function Get-ShortcutGames([string]$dir) {
    $wsh = New-Object -ComObject WScript.Shell
    @(Get-ChildItem (Join-Path $dir '*.lnk') -ErrorAction SilentlyContinue |
        Sort-Object BaseName | ForEach-Object {
            [pscustomobject]@{
                Name  = $_.BaseName
                AppId = "local:$($_.BaseName)"   # key for the per-game TDP store
                Path  = $_.FullName
                Exe   = $wsh.CreateShortcut($_.FullName).TargetPath
                Dir   = $null
            }
        })
}

# ---------------------------------------------------------------- TDP ---
# Per-game TDP override, applied through the same ryzenadj.exe that GPD's
# Motion Assistant uses (its WinRing0 driver is already loaded, so no
# elevation is needed). RB / F5 cycles: default -> 12W -> 15W -> 18W -> 5W.
# The pre-launch limits are captured and restored when the game closes.
#
# The whole feature only activates when Motion Assistant is actually
# installed on this machine; without it CLInt is a plain launcher and no
# TDP hint or keybind appears anywhere.

$maDir      = Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'MotionAssistant'
$ryzenAdj   = Join-Path $maDir 'amd\ryzenadj.exe'
$tdpEnabled = Test-Path $ryzenAdj
$tdpModes   = @(0, 12, 15, 18, 5)          # 0 = leave TDP alone
$tdpFile    = Join-Path $script:dataDir 'tdp-settings.json'
$tdpMap     = @{}
if (Test-Path $tdpFile) {
    (Get-Content $tdpFile -Raw | ConvertFrom-Json).PSObject.Properties |
        ForEach-Object { $tdpMap[$_.Name] = [int]$_.Value }
}

function Save-TdpMap {
    [pscustomobject]$tdpMap | ConvertTo-Json | Set-Content $tdpFile -Encoding utf8
}

function Get-GameTdp($game) {
    $w = $tdpMap[[string]$game.AppId]
    if ($w) { return [int]$w } else { return 0 }
}

function Get-CurrentTdp {
    $info = (& $ryzenAdj --info 2>$null) -join "`n"
    $m = @{}
    foreach ($pair in @(@('Stapm','STAPM LIMIT'), @('Fast','PPT LIMIT FAST'), @('Slow','PPT LIMIT SLOW'))) {
        $v = [regex]::Match($info, "$($pair[1])\s*\|\s*([\d.]+)").Groups[1].Value
        if (-not $v) { return $null }
        $m[$pair[0]] = [double]$v
    }
    return [pscustomobject]$m
}

function Set-Tdp([double]$stapmW, [double]$fastW, [double]$slowW) {
    & $ryzenAdj "--stapm-limit=$([int]($stapmW * 1000))" `
                "--fast-limit=$([int]($fastW * 1000))" `
                "--slow-limit=$([int]($slowW * 1000))" 2>$null | Out-Null
}

# Motion Assistant re-applies its *default* profile's TDP the moment it
# detects a new game process (the limits snap back within ~2s of the exe
# appearing), so a set-then-launch value never survives. It applies once
# per detection rather than continuously, so Wait-ForGameExit calls this
# for the first short stretch after the game appears to nudge the limits
# back, then leaves the hardware alone for the rest of the session.
function Assert-Tdp([int]$watts) {
    try {
        $cur = Get-CurrentTdp
        if ($cur -and [Math]::Abs($cur.Stapm - $watts) -gt 0.5) {
            Set-Tdp $watts ($watts + 1) $watts
        }
    } catch {}
}

# Motion Assistant applies its own TDP to processes it has a profile for
# (Profiles\Process\<exename>.ini) and would fight anything the menu sets.
# Flag those games by matching their exe names against the profile list,
# and lock the menu's TDP toggle for them.
$maProfileNames = @(Get-ChildItem (Join-Path $maDir 'Profiles\Process\*.ini') `
    -ErrorAction SilentlyContinue | ForEach-Object { $_.BaseName })

function Add-MaProfileTags($list) {
    foreach ($g in $list) {
        $match = $null
        if ($maProfileNames.Count -gt 0) {
            if ($g.Exe) {
                $base = [System.IO.Path]::GetFileNameWithoutExtension($g.Exe)
                if ($maProfileNames -contains $base) { $match = $base }
            } elseif ($g.Dir -and (Test-Path $g.Dir)) {
                $match = (Get-ChildItem $g.Dir -Filter '*.exe' -Recurse -Depth 2 -ErrorAction SilentlyContinue |
                    Where-Object { $maProfileNames -contains $_.BaseName } |
                    Select-Object -First 1).BaseName
            }
        }
        $g | Add-Member -NotePropertyName MaProfile -NotePropertyValue $match -Force
    }
}
Add-MaProfileTags $games

if ($List) {
    if ($games.Count -eq 0) { Write-Host "No installed Steam games found."; exit 1 }
    $games |
        Select-Object Name, AppId, @{n='TDP'; e={ $w = Get-GameTdp $_; if ($w) { "$($w)W" } }}, MaProfile |
        Format-Table -AutoSize
    exit 0
}

# ---------------------------------------------------------------- UI ---

# The menu runs under conhost (classic console host), NOT Windows Terminal:
# WT's WinUI tab bar reads the physical gamepad itself (XAML directional
# navigation) and steals focus, and that can't be disabled. Conhost has no
# WinUI at all, so it's immune. This turns the plain conhost window into a
# borderless fullscreen surface with a readable font. Safely no-ops under WT
# (its ConPTY console window is hidden) and on any API failure.
try {
    Add-Type -Namespace CLI -Name Native -MemberDefinition @'
[DllImport("kernel32.dll")] public static extern IntPtr GetStdHandle(int h);
[StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
public struct CONSOLE_FONT_INFOEX {
    public uint cbSize; public uint nFont; public short SizeX; public short SizeY;
    public uint FontFamily; public uint FontWeight;
    [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string FaceName;
}
[DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
public static extern bool SetCurrentConsoleFontEx(IntPtr hOut, bool max, ref CONSOLE_FONT_INFOEX info);
[DllImport("kernel32.dll", SetLastError = true)]
public static extern bool SetConsoleDisplayMode(IntPtr hOut, uint flags, out int coords);
[DllImport("kernel32.dll")] public static extern IntPtr GetConsoleWindow();
[DllImport("user32.dll")] public static extern int GetWindowLong(IntPtr h, int idx);
[DllImport("user32.dll")] public static extern bool ShowScrollBar(IntPtr h, int bar, bool show);
'@
} catch {}

# Conhost adds scrollbars during transient buffer/window mismatches (e.g.
# the default 120-wide buffer meeting a narrower fullscreen window at
# startup) and does NOT reliably remove them once the sizes agree again -
# the bar just lingers, dead, sometimes with the window style bits already
# cleared (so gating on GetWindowLong misses it). Hide unconditionally:
# ShowScrollBar(off) is cheap and a no-op when no bar exists.
function Hide-Scrollbars {
    try {
        $h = [CLI.Native]::GetConsoleWindow()
        [CLI.Native]::ShowScrollBar($h, 3, $false) | Out-Null   # SB_BOTH
    } catch {}
}

# Deliberately simple: set a readable font, ask conhost for its native
# fullscreen (the same mode Alt+Enter toggles), make buffer == window.
# On devices where the API is refused the window just stays as it is -
# Alt+Enter by hand still works there, and the elaborate programmatic
# fallbacks we tried caused more trouble than the gap they closed.
# Apply the user's chosen text size (see $textSizes / the SETTINGS entry).
function Set-ConsoleFontSize {
    try {
        $out = [CLI.Native]::GetStdHandle(-11)
        $font = New-Object CLI.Native+CONSOLE_FONT_INFOEX
        $font.cbSize = [System.Runtime.InteropServices.Marshal]::SizeOf($font)
        $font.SizeY = [int]$textSizes[$script:textSizeName]
        $font.FontFamily = 54; $font.FontWeight = 400
        $font.FaceName = 'Consolas'
        [CLI.Native]::SetCurrentConsoleFontEx($out, $false, [ref]$font) | Out-Null
    } catch {}
}

function Set-ConsoleFullscreen {
    try {
        $out = [CLI.Native]::GetStdHandle(-11)
        Set-ConsoleFontSize

        $coords = 0
        [CLI.Native]::SetConsoleDisplayMode($out, 1, [ref]$coords) | Out-Null
        Start-Sleep -Milliseconds 200

        # re-grow the grid (a windowed spell shrinks it), then
        # buffer == window so there are no scrollbars
        try {
            $maxW = [Console]::LargestWindowWidth
            $maxH = [Console]::LargestWindowHeight
            $Host.UI.RawUI.BufferSize = New-Object System.Management.Automation.Host.Size($maxW, $maxH)
            $Host.UI.RawUI.WindowSize = New-Object System.Management.Automation.Host.Size($maxW, $maxH)
        } catch {}
        $ws = $Host.UI.RawUI.WindowSize
        $Host.UI.RawUI.BufferSize = New-Object System.Management.Automation.Host.Size($ws.Width, $ws.Height)
        Hide-Scrollbars
        $script:isFullscreen = $true
    } catch {}
}

# Leave fullscreen: back to a plain window. Shrinking the GRID is what
# actually shrinks a conhost window - its size is dictated by the grid.
function Set-ConsoleWindowed {
    try {
        $out = [CLI.Native]::GetStdHandle(-11)
        $coords = 0
        [CLI.Native]::SetConsoleDisplayMode($out, 2, [ref]$coords) | Out-Null
        Set-ConsoleFontSize
        try {
            $cols = [Math]::Max(80, [int]([Console]::WindowWidth  * 0.75))
            $rows = [Math]::Max(25, [int]([Console]::WindowHeight * 0.75))
            $Host.UI.RawUI.WindowSize = New-Object System.Management.Automation.Host.Size($cols, $rows)
            $Host.UI.RawUI.BufferSize = New-Object System.Management.Automation.Host.Size($cols, $rows)
        } catch {}
        Hide-Scrollbars
        $script:isFullscreen = $false
    } catch {}
}

# Focus tracking: XInput delivers controller state regardless of which
# window has keyboard focus, so the menu must check it holds the
# foreground before acting - otherwise a still-focused app behind us
# (e.g. Windows Terminal, whose WinUI tab bar reacts to the gamepad and
# pops tooltips over everything) processes the same presses in parallel.
$script:conHwnd = [IntPtr]::Zero
try {
    Add-Type -Namespace CLIntFocus -Name Win -MemberDefinition @'
[DllImport("kernel32.dll")] public static extern IntPtr GetConsoleWindow();
[DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
[DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
[DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int cmd);
[DllImport("user32.dll")] public static extern bool IsIconic(IntPtr h);
'@
    $script:conHwnd = [CLIntFocus.Win]::GetConsoleWindow()
} catch {}

# A just-launched game can be denied activation by Windows' focus-steal
# protection and sit invisible BEHIND the fullscreen menu (seen when Steam
# is cold-started silently in the tray). We hold the foreground, so step
# aside: minimise ourselves and Windows activates the game window on top.
function Hide-MenuForGame {
    if ($script:conHwnd -eq [IntPtr]::Zero) { return }
    try {
        if ([CLIntFocus.Win]::GetForegroundWindow() -eq $script:conHwnd) {
            [CLIntFocus.Win]::ShowWindow($script:conHwnd, 6) | Out-Null   # SW_MINIMIZE
        }
    } catch {}
}

# Bring the menu back after a game/video: un-minimise only if we stepped
# aside (SW_RESTORE on a non-iconic window would drop the fullscreen
# display mode), then take the foreground back.
function Show-MenuWindow {
    if ($script:conHwnd -ne [IntPtr]::Zero) {
        try {
            if ([CLIntFocus.Win]::IsIconic($script:conHwnd)) {
                [CLIntFocus.Win]::ShowWindow($script:conHwnd, 9) | Out-Null   # SW_RESTORE
            }
            [CLIntFocus.Win]::SetForegroundWindow($script:conHwnd) | Out-Null
        } catch {}
    }
    try { (New-Object -ComObject WScript.Shell).AppActivate('CLInt') | Out-Null } catch {}
}

# --- Mouse input (optional, SETTINGS toggle) ----------------------------
# conhost reports mouse activity as INPUT_RECORDs in CELL coordinates -
# the same units everything is drawn in, so no pixel math and no DPI
# involvement. Quick-Edit mode must be off while mouse input is on (it
# swallows every event for text selection); it is put back when the
# toggle is turned off.
$script:mouseOk = $false
try {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
namespace CLIntMouse {
    [StructLayout(LayoutKind.Explicit)]
    public struct Rec {
        [FieldOffset(0)]  public ushort EventType;   // 1 = key, 2 = mouse
        [FieldOffset(4)]  public short  X;           // cell coords
        [FieldOffset(6)]  public short  Y;
        [FieldOffset(8)]  public uint   Btn;         // bit 0 = left; wheel delta in the high word
        [FieldOffset(12)] public uint   Ctrl;
        [FieldOffset(16)] public uint   Flags;       // 0 press/release, 1 move, 2 double-click, 4 wheel
    }
    public static class Win {
        [DllImport("kernel32.dll")] public static extern IntPtr GetStdHandle(int h);
        [DllImport("kernel32.dll")] public static extern bool GetConsoleMode(IntPtr h, out uint mode);
        [DllImport("kernel32.dll")] public static extern bool SetConsoleMode(IntPtr h, uint mode);
        [DllImport("kernel32.dll")] public static extern bool GetNumberOfConsoleInputEvents(IntPtr h, out uint n);
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode)] public static extern bool PeekConsoleInput(IntPtr h, out Rec r, uint len, out uint read);
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode)] public static extern bool ReadConsoleInput(IntPtr h, out Rec r, uint len, out uint read);
    }
}
'@
    $script:mouseOk = $true
} catch {}
$script:mouseLeftWas = $false   # last seen left-button state, for press-edge detection
$script:tabHit = @()            # tab-bar extents recorded by Draw-All: (x0, x1, index)
# Modal mouse map: a modal publishes where its list rows sit (top row,
# scroll offset, visible row count, entry count) and handles the
# 'MouseHover'/'MouseClick' pseudo-keys Read-MouseEvent returns, with the
# hit index in modalHover. modalTop -1 = no mouse map (keyboard-only modal).
$script:modalTop = -1; $script:modalOff = 0; $script:modalRows = 0
$script:modalCount = 0; $script:modalHover = -1

function Set-MouseMode([bool]$on) {
    if (-not $script:mouseOk) { return }
    try {
        # $hin, NOT $h: locals are visible to every function called beneath
        # them (dynamic scoping) and names are case-insensitive, so a $h
        # here would shadow the script's $H (window height) for callees -
        # that exact collision broke Get-Layout once. Same rule as $w/$W.
        $hin = [CLIntMouse.Win]::GetStdHandle(-10)
        $mode = [uint32]0
        if (-not [CLIntMouse.Win]::GetConsoleMode($hin, [ref]$mode)) { return }
        $mode = if ($on) { ($mode -bor 0x0090) -band 0xFFFFFFBF }   # +mouse +extended-flags, -quick-edit
                else     { ($mode -bor 0x00C0) -band 0xFFFFFFEF }   # -mouse, quick-edit back on
        [CLIntMouse.Win]::SetConsoleMode($hin, [uint32]$mode) | Out-Null
    } catch { $script:mouseOk = $false }
}

# The mascot catalog. Every tab shows one of these; a tab's icon can be
# chosen in SETTINGS (stored as "Icon": "<name>" in settings.json) or is
# auto-assigned: the classic face for the first tab of its type, then the
# first unused face from the pool. 'robot' is reserved for SETTINGS.
$mascots = [ordered]@{
    rocket = @(
    '    /\'
    '   /##\'
    '  / o o \'
    '  | \_/ |'
    ' /|#####|\'
    '   ^^ ^^'
    )
    handheld = @(
    '.---------.'
    '| .-----. |'
    '|+| o o |b|'
    '| | \_/ |a|'
    '| ''-----'' |'
    '''---------'''
    )
    vhs = @(
    '.----------.'
    '| (o)  (o) |'
    '|   \__/   |'
    '| [======] |'
    '''----------'''
    )
    alien = @(
    '    \|/'
    '   .---.'
    '  / o o \'
    '  | \_/ |'
    '   \___/'
    )
    ufo = @(
    '     ___'
    '   /o o o\'
    '   \  -  /'
    '  /=======\'
    '   ~ ~ ~ ~'
    )
    cat = @(
    '   /\___/\'
    '  ( o   o )'
    '  (  \_/  )'
    '   -------'
    )
    ghost = @(
    '   .---.'
    '  / o o \'
    '  | \_/ |'
    '  |/\/\/|'
    )
    slime = @(
    '     ____'
    '   /      \'
    '  |  o  o  |'
    '  |  \__/  |'
    '   \______/'
    )
    planet = @(
    '      ___'
    '    / o o \'
    ' --(  \_/  )--'
    '     \___/'
    )
    robot = @(
    '    ___'
    '  .[___].'
    '  | o o |'
    '  | \_/ |'
    '  ''-----'''
    )
}
$typeMascot   = @{ Steam = 'rocket'; Shortcuts = 'handheld'; Files = 'vhs'; Settings = 'robot' }
$extraMascots = @('alien', 'ufo', 'cat', 'ghost', 'slime', 'planet')

# Color themes: every drawing call reads $theme, so switching is instant.
# Selected in SETTINGS, stored as "Theme" in settings.json.
$themes = [ordered]@{
    classic = @{ Accent = 'Cyan';    Logo = 'Magenta';    Info = 'DarkCyan';    Hint = 'DarkGray'; Text = 'Gray'; Bright = 'White';  Notice = 'Yellow'; Scroll = 'DarkMagenta'; SelFg = 'Black' }
    vapor   = @{ Accent = 'Magenta'; Logo = 'Cyan';       Info = 'DarkMagenta'; Hint = 'DarkGray'; Text = 'Gray'; Bright = 'White';  Notice = 'Yellow'; Scroll = 'DarkCyan';    SelFg = 'Black' }
    matrix  = @{ Accent = 'Green';   Logo = 'DarkGreen';  Info = 'DarkGreen';   Hint = 'DarkGray'; Text = 'Gray'; Bright = 'Green';  Notice = 'Yellow'; Scroll = 'DarkGreen';   SelFg = 'Black' }
    amber   = @{ Accent = 'Yellow';  Logo = 'DarkYellow'; Info = 'DarkYellow';  Hint = 'DarkGray'; Text = 'Gray'; Bright = 'Yellow'; Notice = 'Red';    Scroll = 'DarkYellow';  SelFg = 'Black' }
    arctic  = @{ Accent = 'White';   Logo = 'Cyan';       Info = 'DarkCyan';    Hint = 'DarkGray'; Text = 'Gray'; Bright = 'White';  Notice = 'Yellow'; Scroll = 'DarkCyan';    SelFg = 'Black' }
}
$themeName = if ($settings['Theme'] -and $themes.Contains([string]$settings['Theme'])) { [string]$settings['Theme'] } else { 'classic' }
$theme = $themes[$themeName]

# Text size (SETTINGS): font heights in scaled pixels, so the visual size
# follows the user's display scale like every other app. Medium is the
# 28px the app has always used.
$textSizes = [ordered]@{ small = 20; medium = 28; large = 34 }
$textSizeName = if ($settings['TextSize'] -and $textSizes.Contains([string]$settings['TextSize'])) { [string]$settings['TextSize'] } else { 'medium' }

# Behaviour toggles (all in SETTINGS). Clock/battery/recently-played
# default on; the launch-time update check is opt-in.
$showClock     = $settings['ShowClock']       -ne $false
$showBattery   = $settings['ShowBattery']     -ne $false
$recentEnabled = $settings['Recent']          -ne $false
$autoCheck     = $settings['AutoUpdateCheck'] -eq $true
$mouseEnabled  = $settings['Mouse']           -ne $false
$inModal = $false        # modals suppress the idle clock/battery repaint
$batteryPct = -1
$batteryNext = 0
$tdpNowW = -1            # live TDP watts (Motion Assistant machines only)
$statusLast = ''
$statusDrawnLen = 0      # width of the last corner draw, for clean blanking
$statusReserved = 0      # corner columns the tab bar left free at last full draw
$updateNoticeShown = $false

# Recently played: recent.json maps a game key (AppId / local:<name>)
# to last-played time and total minutes. Only touched while the feature
# is enabled.
$recentFile = Join-Path $script:dataDir 'recent.json'
$recentMap = @{}
if (Test-Path $recentFile) {
    try {
        (Get-Content $recentFile -Raw | ConvertFrom-Json).PSObject.Properties |
            ForEach-Object { $recentMap[$_.Name] = $_.Value }
    } catch {}
}
function Save-RecentMap {
    try { [pscustomobject]$script:recentMap | ConvertTo-Json | Set-Content $script:recentFile -Encoding utf8 } catch {}
}
function Record-Play($game, [double]$mins) {
    $k = [string]$game.AppId
    $prevMins = 0.0
    if ($script:recentMap[$k]) { try { $prevMins = [double]$script:recentMap[$k].Mins } catch {} }
    $script:recentMap[$k] = [pscustomobject]@{
        Last = [DateTime]::Now.ToString('s')
        Mins = [Math]::Round($prevMins + [Math]::Max(0, $mins), 1)
    }
    Save-RecentMap
}
# Video history (Files tabs): play counts tracked here per machine, and
# partially-watched positions read straight from VLC's own resume state,
# so the [>>] tag shows the real continue-from timestamp.
$videoHistEnabled = $settings['VideoHistory'] -ne $false
$watchFile = Join-Path $script:dataDir 'watch-history.json'
$watchMap = @{}
if (Test-Path $watchFile) {
    try {
        (Get-Content $watchFile -Raw | ConvertFrom-Json).PSObject.Properties |
            ForEach-Object { $watchMap[$_.Name] = $_.Value }
    } catch {}
}
function Save-WatchMap {
    try { [pscustomobject]$script:watchMap | ConvertTo-Json | Set-Content $script:watchFile -Encoding utf8 } catch {}
}
function Record-VideoPlay([string]$path) {
    $k = $path.ToLower()
    $prev = 0
    if ($script:watchMap[$k]) { try { $prev = [int]$script:watchMap[$k].Plays } catch {} }
    $script:watchMap[$k] = [pscustomobject]@{ Plays = $prev + 1; Last = [DateTime]::Now.ToString('s') }
    Save-WatchMap
}
# VLC stores resume positions in [RecentsMRL] of vlc-qt-interface.ini:
# parallel 'list=' (file:/// URIs) and 'times=' (milliseconds; 0 = none).
function Get-VlcResumeSeconds {
    $map = @{}
    try {
        $ini = Join-Path $env:APPDATA 'vlc\vlc-qt-interface.ini'
        if (-not (Test-Path $ini)) { return $map }
        $inSect = $false; $list = $null; $times = $null
        foreach ($ln in (Get-Content $ini)) {
            if ($ln -match '^\[') { $inSect = ($ln.Trim() -eq '[RecentsMRL]'); continue }
            if (-not $inSect) { continue }
            if ($ln -like 'list=*')  { $list  = $ln.Substring(5) }
            elseif ($ln -like 'times=*') { $times = $ln.Substring(6) }
        }
        if ($list -and $times) {
            $files = @($list -split ',\s*')
            $ts    = @($times -split ',\s*')
            for ($i = 0; $i -lt [Math]::Min($files.Count, $ts.Count); $i++) {
                $u = $files[$i].Trim()
                if ($u -notlike 'file:///*') { continue }
                $p = ([Uri]::UnescapeDataString($u.Substring(8))) -replace '/', '\'
                $ms = [long]0
                if ([long]::TryParse($ts[$i].Trim(), [ref]$ms) -and $ms -gt 0) {
                    $map[$p.ToLower()] = [int]($ms / 1000)
                }
            }
        }
    } catch {}
    return $map
}

# Recently played games sit in their own titled section at the top (most
# recent first), with a gap before the A-Z list so the split is obvious.
# The title/spacer rows carry Unselectable = $true: the cursor slides past
# them and they can't be launched. No-op while the feature is off.
function Sort-Games($list) {
    $list = @($list | Where-Object { -not $_.Unselectable })   # strip old section rows before re-sorting
    if (-not $script:recentEnabled -or $script:recentMap.Count -eq 0) { return @($list) }
    $recent = @(); $rest = @()
    foreach ($g in $list) {
        if ($script:recentMap[[string]$g.AppId]) { $recent += $g } else { $rest += $g }
    }
    if ($recent.Count -eq 0) { return @($rest) }
    $recent = @($recent | Sort-Object {
        try { [DateTime]$script:recentMap[[string]$_.AppId].Last } catch { [DateTime]::MinValue }
    } -Descending)
    $out = @([pscustomobject]@{ Name = 'RECENTLY PLAYED'; Unselectable = $true })
    $out += $recent
    if ($rest.Count -gt 0) {
        $out += [pscustomobject]@{ Name = '';    Unselectable = $true }   # blank spacer row
        $out += [pscustomobject]@{ Name = 'A-Z'; Unselectable = $true }
        $out += $rest
    }
    return @($out)
}

$isFullscreen = $false   # what the window IS right now (owned by the Set-Console* functions)

# Cap on configurable tabs (SETTINGS not counted): the tab bar starts at
# column 15 and each named tab takes roughly 15-16 columns, so ~8 content
# tabs plus SETTINGS is what a fullscreen console row actually fits.
$MAX_TABS = 8

# VLC is optional-but-recommended: with it, videos play fullscreen and
# the menu waits for playback to end (and resume markers work); without
# it, videos open in the default player. Look beyond the standard install
# path: the registry App Paths entry, then common locations.
function Find-Vlc {
    $cands = @()
    try {
        $rp = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\vlc.exe' -ErrorAction SilentlyContinue).'(default)'
        if ($rp) { $cands += $rp }
    } catch {}
    foreach ($base in @($env:ProgramFiles, ${env:ProgramFiles(x86)}, "$env:LOCALAPPDATA\Programs")) {
        if ($base) { $cands += (Join-Path $base 'VideoLAN\VLC\vlc.exe') }
    }
    foreach ($c in $cands) {
        try { if ($c -and (Test-Path $c)) { return $c } } catch {}
    }
    return $null
}
$vlcExe     = Find-Vlc
$videoExtRe = '^\.(mp4|mkv|avi|webm|mov|m4v|wmv|mpg|mpeg|ts|flv)$'

# File-browser tabs: '..' first (in subfolders), then folders that contain
# at least one file somewhere below, then the files themselves. Videos
# play via VLC; anything else opens with its default app.
function Get-FileItems($t) {
    $dir = $t.Dir
    $list = @()
    if ($dir -ne $t.Root) {
        $list += [pscustomobject]@{ Name = '..'; Path = (Split-Path $dir -Parent); Type = 'Up' }
    }
    # Dot-prefixed names (.git, ._macos-droppings, ...) are hidden by
    # convention even when Windows doesn't flag them hidden - skip them.
    $list += @(Get-ChildItem $dir -Directory -ErrorAction SilentlyContinue | Sort-Object Name |
        Where-Object { -not $_.Name.StartsWith('.') } |
        Where-Object { @(Get-ChildItem $_.FullName -File -Recurse -ErrorAction SilentlyContinue |
            Select-Object -First 1).Count -gt 0 } |
        ForEach-Object { [pscustomobject]@{ Name = $_.Name + '\'; Path = $_.FullName; Type = 'Dir' } })
    $vlcResume = if ($script:videoHistEnabled) { Get-VlcResumeSeconds } else { @{} }
    $list += @(Get-ChildItem $dir -File -ErrorAction SilentlyContinue | Sort-Object Name |
        Where-Object { -not $_.Name.StartsWith('.') } |
        ForEach-Object {
            $k = $_.FullName.ToLower()
            $plays = 0
            if ($script:videoHistEnabled -and $script:watchMap[$k]) {
                try { $plays = [int]$script:watchMap[$k].Plays } catch {}
            }
            # .lnk/.url are implementation details - show the shortcut's name
            $disp = if ($_.Extension -in '.lnk', '.url') { $_.BaseName } else { $_.Name }
            [pscustomobject]@{
                Name = $disp; Path = $_.FullName; Type = 'File'
                Plays = $plays; Resume = $vlcResume[$k]
            }
        })
    return $list
}

# ---------------------------------------------------------------- Tabs ---
# Runtime tab objects built from $settings.Tabs (+ SETTINGS appended).
# Each carries its own items, cursor, and - for Files tabs - browse state.
function New-TabState($cfg) {
    $t = @{ Type = $cfg.Type; Path = $cfg.Path; Sel = 0; Off = 0 }
    $t.Name = if ($cfg.Name) { $cfg.Name } else {
        switch ($cfg.Type) {
            'Steam'     { if ($cfg.Collection) { ([string]$cfg.Collection).ToUpper() } else { 'STEAM GAMES' } }
            'Shortcuts' { if ($cfg.Path) { (Split-Path $cfg.Path -Leaf).ToUpper() } else { 'SHORTCUTS' } }
            'Files'     { if ($cfg.Path) { (Split-Path $cfg.Path -Leaf).ToUpper() } else { 'FILES' } }
            'Settings'  { 'SETTINGS' }
        }
    }
    switch ($cfg.Type) {
        'Steam'     {
            if ($cfg.CollectionId) {
                $col = @(Get-SteamCollections) | Where-Object { $_.Id -eq [string]$cfg.CollectionId } | Select-Object -First 1
                if ($col) {
                    $inCol = @{}
                    foreach ($a in $col.Added) { $inCol[$a] = $true }
                    $t.Items = @(Sort-Games @($games | Where-Object { $inCol[[string]$_.AppId] }))
                } else {
                    $t.Items = @()   # collection no longer exists in Steam
                }
            } else {
                $t.Items = @(Sort-Games $games)
            }
        }
        'Shortcuts' {
            $t.Items = @(Get-ShortcutGames $cfg.Path)
            Add-MaProfileTags $t.Items
            $t.Items = @(Sort-Games $t.Items)
        }
        'Files'     {
            $t.Root  = $cfg.Path
            $t.Dir   = $cfg.Path
            $t.Stack = New-Object System.Collections.Stack   # (dir, sel, off) per level
            $t.Items = @(Get-FileItems $t)
        }
        'Settings'  { $t.Items = @() }   # built fresh by Get-TabItems
    }
    return $t
}

function Build-Tabs {
    $script:tabs = @()
    $used = @{}
    # Hand-picked icons claim their mascot first, so auto-assignment
    # steers the remaining tabs around them.
    foreach ($cfg in $settings['Tabs']) {
        if ($cfg.Icon -and $mascots.Contains([string]$cfg.Icon)) { $used[[string]$cfg.Icon] = $true }
    }
    foreach ($cfg in $settings['Tabs']) {
        $t = New-TabState $cfg
        if ($cfg.Icon -and $mascots.Contains([string]$cfg.Icon)) {
            $t.Icon = [string]$cfg.Icon
        } else {
            $classic = $typeMascot[$t.Type]
            $t.Icon = if (-not $used[$classic]) { $classic }
                      else { @($extraMascots | Where-Object { -not $used[$_] })[0] }
            if (-not $t.Icon) { $t.Icon = $classic }   # every face taken: reuse the classic
            $used[$t.Icon] = $true
        }
        $t.Logo = $mascots[$t.Icon]
        $script:tabs += $t
    }
    $st = New-TabState @{ Type = 'Settings' }
    $st.Icon = 'robot'
    $st.Logo = $mascots['robot']
    $script:tabs += $st
}
Build-Tabs

$tab      = 0
$selected = 0
$offset   = 0    # first item index shown in the viewport

function Get-SettingsItems {
    $list = @()
    for ($i = 0; $i -lt $settings['Tabs'].Count; $i++) {
        $cfg = $settings['Tabs'][$i]
        $desc = switch ($cfg.Type) {
            'Steam'     { if ($cfg.Collection) { "Steam collection: $($cfg.Collection)" } else { 'Steam library' } }
            'Shortcuts' { "shortcuts in $($cfg.Path)" }
            'Files'     { "files in $($cfg.Path)" }
        }
        $list += [pscustomobject]@{ Key = 'Tab'; Index = $i
                                    Name = ("Tab $($i + 1): $($tabs[$i].Name)".PadRight(30) + $desc) }
    }
    $list += [pscustomobject]@{ Key = 'AddTab'; Name = '[ + add a tab ]' }
    $list += [pscustomobject]@{ Key = 'Fullscreen'; Name = 'Toggle fullscreen' }
    $list += [pscustomobject]@{ Key = 'ShowClock'
                                Name = ('Show clock'.PadRight(30) + $(if ($script:showClock) { 'on' } else { 'off' })) }
    $list += [pscustomobject]@{ Key = 'ShowBattery'
                                Name = ('Show battery'.PadRight(30) + $(if ($script:showBattery) { 'on' } else { 'off' })) }
    $list += [pscustomobject]@{ Key = 'NonSteam'
                                Name = ('Non-Steam apps in Steam tabs'.PadRight(30) + $(if ($script:nonSteamEnabled) { 'on' } else { 'off' })) }
    $list += [pscustomobject]@{ Key = 'Recent'
                                Name = ('Recently played first'.PadRight(30) + $(if ($script:recentEnabled) { 'on' } else { 'off' })) }
    $list += [pscustomobject]@{ Key = 'VideoHist'
                                Name = ('Video history'.PadRight(30) + $(if ($script:videoHistEnabled) { 'on' } else { 'off' })) }
    $list += [pscustomobject]@{ Key = 'AutoCheck'
                                Name = ('Check updates at launch'.PadRight(30) + $(if ($script:autoCheck) { 'on' } else { 'off' })) }
    $list += [pscustomobject]@{ Key = 'Mouse'
                                Name = ('Mouse support'.PadRight(30) + $(if ($script:mouseEnabled) { 'on' } else { 'off' })) }
    $list += [pscustomobject]@{ Key = 'TextSize'
                                Name = ('Text size'.PadRight(30) + $script:textSizeName) }
    $list += [pscustomobject]@{ Key = 'Theme'
                                Name = ('Color theme'.PadRight(30) + $script:themeName) }
    $updName = 'Check for updates'.PadRight(30) + "current: v$appVersion"
    $marker = Join-Path $script:dataDir 'update-available.txt'
    if (Test-Path $marker) {
        $nv = ''
        try { $nv = ([string](Get-Content $marker -TotalCount 1)).Trim() } catch {}
        if ($nv) { $updName += "  ->  v$nv available" }
    }
    if (-not $vlcExe) {
        $list += [pscustomobject]@{ Key = 'VlcInfo'
                                    Name = 'VLC not detected - videos will open in the default player' }
    }
    $list += [pscustomobject]@{ Key = 'Update'; Name = $updName }
    $list += [pscustomobject]@{ Key = 'ClearHist'; Name = '[ clear history ]' }
    $list += [pscustomobject]@{ Key = 'ResetAll'; Name = '[ reset all settings ]' }
    $list += [pscustomobject]@{ Key = 'Quit'; Name = '[ quit CLInt ]' }
    return $list
}

function Get-TabItems([int]$t) {
    if ($tabs[$t].Type -eq 'Settings') { return @(Get-SettingsItems) }
    return $tabs[$t].Items
}

function Switch-Tab([int]$delta) {
    $tabs[$script:tab].Sel = $script:selected
    $tabs[$script:tab].Off = $script:offset
    $script:tab = ($script:tab + $delta + $tabs.Count) % $tabs.Count
    $script:items    = @(Get-TabItems $script:tab)
    $script:selected = [Math]::Min($tabs[$script:tab].Sel, [Math]::Max(0, $script:items.Count - 1))
    Snap-Selection
    $script:offset   = $tabs[$script:tab].Off
    Draw-All
}

# Rebuild everything after a tab-config change and land on the SETTINGS tab.
function Apply-TabConfig {
    Save-Settings
    Build-Tabs
    $script:tab      = $tabs.Count - 1
    $script:items    = @(Get-TabItems $script:tab)
    $script:selected = 0
    $script:offset   = 0
    Draw-All
}

function Enter-FileDir($t, [string]$path) {
    $t.Stack.Push(@($t.Dir, $script:selected, $script:offset))
    $t.Dir   = $path
    $t.Items = @(Get-FileItems $t)
    $script:items    = $t.Items
    $script:selected = 0
    $script:offset   = 0
    Draw-All
}

# Go up one folder; returns $false when already at the tab's root.
function Exit-FileDir($t) {
    if ($t.Dir -eq $t.Root) { return $false }
    if ($t.Stack.Count -gt 0) {
        $prev = $t.Stack.Pop()
        $t.Dir = $prev[0]; $sel = $prev[1]; $off = $prev[2]
    } else {
        $t.Dir = Split-Path $t.Dir -Parent; $sel = 0; $off = 0
    }
    $t.Items = @(Get-FileItems $t)
    $script:items    = $t.Items
    $script:selected = [Math]::Min($sel, [Math]::Max(0, $script:items.Count - 1))
    $script:offset   = $off
    Draw-All
    return $true
}

# Section rows (the RECENTLY PLAYED / A-Z titles and their spacer) are
# drawn in the list but can never hold the cursor.
function Get-FirstSelectable {
    for ($i = 0; $i -lt $script:items.Count; $i++) {
        if (-not $script:items[$i].Unselectable) { return $i }
    }
    return 0
}
# After a list rebuild a restored cursor position can land on a section
# row - nudge it down to the nearest real item (up from the very end).
function Snap-Selection {
    if ($script:items.Count -eq 0) { return }
    $i = [Math]::Min([Math]::Max(0, $script:selected), $script:items.Count - 1)
    while ($i -lt $script:items.Count - 1 -and $script:items[$i].Unselectable) { $i++ }
    while ($i -gt 0 -and $script:items[$i].Unselectable) { $i-- }
    $script:selected = $i
}

$items = @(Get-TabItems 0)
Snap-Selection

function Write-At([int]$x, [int]$y, [string]$text, $fg, $bg) {
    [Console]::SetCursorPosition($x, $y)
    if ($bg) { Write-Host $text -ForegroundColor $fg -BackgroundColor $bg -NoNewline }
    else     { Write-Host $text -ForegroundColor $fg -NoNewline }
}

function Pad([string]$s, [int]$width) {
    if ($width -lt 1) { return '' }
    if ($s.Length -gt $width) {
        if ($width -le 3) { return $s.Substring(0, $width) }
        return $s.Substring(0, $width - 3) + '...'
    }
    return $s.PadRight($width)
}

function Get-Layout {
    $script:W = [Console]::WindowWidth
    $script:H = [Console]::WindowHeight
    # No scrollbars, ever: conhost shows them whenever the buffer outgrows
    # the window (any resize does it - a game switching resolution, a drag
    # of the windowed frame), so re-pin buffer == window on every layout.
    try {
        if ([Console]::BufferWidth -ne $W -or [Console]::BufferHeight -ne $H) {
            $Host.UI.RawUI.BufferSize = New-Object System.Management.Automation.Host.Size($W, $H)
        }
    } catch {}
    $script:listTop  = 7                       # header block height (6-row logos + gap)
    # $script: qualified on the READS too: an unqualified $H here resolves
    # dynamically and can be shadowed by a caller's local (a $h handle
    # variable did exactly that) - the geometry must come from script scope.
    $script:visible  = [Math]::Max(1, $script:H - $script:listTop - 1)
}

function Draw-GameLine([int]$i) {
    $y = $listTop + ($i - $offset)
    if ($i -lt $offset -or $i -ge $offset + $visible) { return }
    $lineW = $W - 3   # not $w: case-insensitively shadows $W (see Pick-Folder)
    if ($items[$i].Unselectable) {
        # section title (or blank spacer) - muted, slightly outdented
        Write-At 1 $y (Pad ("   " + $items[$i].Name) $lineW) $theme.Hint
        return
    }
    $label = $items[$i].Name
    $type = $tabs[$tab].Type
    if ($type -in 'Steam', 'Shortcuts') {
        $tdp = Get-GameTdp $items[$i]
        if ($items[$i].MaProfile) { $label += "  [MA profile]" }
        elseif ($tdp)             { $label += "  [$($tdp)W]" }
        if ($script:recentEnabled) {
            $rp = $script:recentMap[[string]$items[$i].AppId]
            if ($rp) {
                $m = 0.0; try { $m = [double]$rp.Mins } catch {}
                if ($m -ge 60) { $label += "  [$([int]($m / 60))h]" }
            }
        }
    } elseif ($type -eq 'Files' -and $items[$i].Type -eq 'File' -and $script:videoHistEnabled) {
        if ($items[$i].Resume) {
            $ts = [TimeSpan]::FromSeconds([double]$items[$i].Resume)
            $pos = if ($ts.Hours -gt 0) { $ts.ToString('h\:mm\:ss') } else { $ts.ToString('m\:ss') }
            $label += "  [>> $pos]"
        }
        if ($items[$i].Plays -ge 1) { $label += "  [x$($items[$i].Plays)]" }
    }
    if ($i -eq $selected) {
        Write-At 1 $y (Pad ("  >> " + $label + "  ") $lineW) $theme.SelFg $theme.Accent
    } else {
        $fg = if ($type -eq 'Files' -and $items[$i].Type -ne 'File') { $theme.Bright } else { $theme.Text }
        Write-At 1 $y (Pad ("     " + $label + "  ") $lineW) $fg
    }
}

# Clock / battery, right-aligned on the header's spare row. Battery is
# hidden automatically when the machine reports none.
function Get-StatusText {
    $parts = @()
    if ($tdpEnabled -and $script:tdpNowW -gt 0) { $parts += "$($script:tdpNowW)W" }
    if ($script:showBattery -and $script:batteryPct -ge 0) { $parts += "$($script:batteryPct)%" }
    if ($script:showClock) { $parts += [DateTime]::Now.ToString('HH:mm') }   # clock rightmost, in the corner
    return ($parts -join ' ')
}
function Draw-Status {
    try {
        if ($W -le 44) { return }
        # top-right corner, on the tab-bar row; drawn at exactly the text's
        # width so the tabs can use everything to its left
        $txt = Get-StatusText
        $script:statusLast = $txt
        if ($script:statusDrawnLen -gt $txt.Length) {
            # a previously longer readout left characters behind: blank them
            Write-At ($W - $script:statusDrawnLen - 1) 0 (' ' * ($script:statusDrawnLen - $txt.Length)) $theme.Info
        }
        if ($txt) { Write-At ($W - $txt.Length - 1) 0 $txt $theme.Info }   # one column of breathing room
        $script:statusDrawnLen = $txt.Length
    } catch {}
}

$noticeShown = $false
$pendingNotice = $null   # set by modals; shown after the next full redraw
function Show-Notice([string]$text) {
    Write-At 15 4 (Pad $text ($W - 16)) $theme.Notice
    $script:noticeShown = $true
}
function Clear-Notice {
    if ($script:noticeShown) {
        Write-At 15 4 (' ' * ($W - 16)) $theme.Text
        $script:noticeShown = $false
    }
}

function Draw-All {
    Clear-Host
    Get-Layout
    $script:inModal = $false   # every modal exits through a full redraw
    $script:noticeShown = $false
    $cur = $tabs[$tab]
    $logo = if ($cur.Logo) { $cur.Logo } else { $mascots[$typeMascot[$cur.Type]] }
    for ($i = 0; $i -lt $logo.Count; $i++) {
        Write-At 2 $i $logo[$i] $theme.Logo
    }
    # Tab bar: fit ALL tabs on the row. Tighten padding first, then trim
    # the names themselves so every tab stays visible and nothing can ever
    # write past the row's end (which would wrap or scroll).
    $x = 15
    # keep clear of the TDP/clock/battery in the top-right corner -
    # reserving exactly what the current readout needs, no more
    $st = Get-StatusText
    $statusReserve = if ($st) { $st.Length + 2 } else { 0 }
    $script:statusReserved = $statusReserve
    $avail = [Math]::Max(10, $W - $x - 1 - $statusReserve)
    $names = @($tabs | ForEach-Object { [string]$_.Name })
    $nameLen = ($names | ForEach-Object { $_.Length } | Measure-Object -Sum).Sum
    $padLen = 2; $gap = 2
    if ($nameLen + $names.Count * 2 * $padLen + ($names.Count - 1) * $gap -gt $avail) { $padLen = 1; $gap = 1 }
    if ($nameLen + $names.Count * 2 * $padLen + ($names.Count - 1) * $gap -gt $avail) {
        $budget = $avail - $names.Count * 2 * $padLen - ($names.Count - 1) * $gap
        $maxLen = [Math]::Max(2, [int][Math]::Floor($budget / $names.Count))
        $names = @($names | ForEach-Object {
            if ($_.Length -gt $maxLen) { $_.Substring(0, [Math]::Max(1, $maxLen - 1)) + '~' } else { $_ }
        })
    }
    $padStr = ' ' * $padLen
    $script:tabHit = @()   # extents for mouse hit-testing, cell coords
    for ($t = 0; $t -lt $tabs.Count; $t++) {
        $txt = $padStr + $names[$t] + $padStr
        if ($x + $txt.Length -ge $W) { break }   # belt and braces
        if ($t -eq $tab) { Write-At $x 0 $txt $theme.SelFg $theme.Accent }
        else             { Write-At $x 0 $txt $theme.Hint }
        # parens matter: PS's comma binds tighter than +/- ("$a, $a + 1"
        # builds an array THEN adds), which broke startup here once
        $script:tabHit += ,@($x, ($x + $txt.Length - 1), $t)
        $x += $txt.Length + $gap
    }
    $nReal = @($items | Where-Object { -not $_.Unselectable }).Count   # section rows aren't games
    $count = switch ($cur.Type) {
        'Steam'     { "$nReal Steam games installed" }
        'Shortcuts' { "$nReal shortcuts" }
        'Files'     { Pad "$($cur.Dir)  ($($items.Count) items)" ($W - 16) }
        'Settings'  { 'settings are saved automatically' }
    }
    Write-At 15 1 $count $theme.Info
    $help = if ($cur.Type -eq 'Settings') { "[ D-pad: move    </>: switch tab    A: change    B: quit ]" }
            elseif ($tdpEnabled -and $cur.Type -in 'Steam', 'Shortcuts') { "[ D-pad: move    </>: switch tab    A: launch    RB: TDP    B: quit ]" }
            else { "[ D-pad: move    </>: switch tab    A: launch    B: quit ]" }
    Write-At 15 3 $help $theme.Hint
    Draw-Status
    if ($items.Count -eq 0) {
        $msg = if ($cur.Type -eq 'Shortcuts') { 'No .lnk shortcuts in this folder - press A to choose another folder or remove this tab.' }
               else { 'Nothing found here.' }
        Write-At 6 $listTop (Pad $msg ($W - 8)) $theme.Hint
    }
    Draw-List
    Hide-Scrollbars   # full redraws follow the moments bars sneak in (launch, game return, tab config)
    if ($script:autoCheck -and -not $script:updateNoticeShown -and
        (Test-Path (Join-Path $script:dataDir 'update-available.txt'))) {
        $script:updateNoticeShown = $true
        Show-Notice 'Update available  -  SETTINGS -> Check for updates'
    }
}

# Repaint only the list viewport, without Clear-Host, so scrolling doesn't
# flash the whole screen. Lines are padded to full width and overwrite in
# place; only the indicators' last column falls outside that and needs
# explicit blanking.
function Draw-List {
    for ($i = $offset; $i -lt [Math]::Min($offset + $visible, $items.Count); $i++) {
        Draw-GameLine $i
    }
    for ($y = $listTop + [Math]::Max(0, $items.Count - $offset); $y -lt $listTop + $visible; $y++) {
        Write-At 1 $y (' ' * ($W - 3)) $theme.Text
    }
    Draw-ScrollHints
}

# The viewport's edge rows double as the '/\ more' / '\/ more' indicator
# rows, and a game line paints right up to the indicator's second-last
# column - so ANY repaint of an edge row (the selection bar landing there,
# a TDP tag update) must re-stamp the indicators afterwards, or all that
# survives of 'more' is its final 'e'.
function Draw-ScrollHints {
    Write-At ($W - 2) $listTop ' ' $theme.Text
    Write-At ($W - 2) ($listTop + $visible - 1) ' ' $theme.Text
    if ($offset -gt 0)                       { Write-At ($W - 8) $listTop '/\ more' $theme.Scroll }
    if ($offset + $visible -lt $items.Count) { Write-At ($W - 8) ($listTop + $visible - 1) '\/ more' $theme.Scroll }
}

# --- Native gamepad input (XInput) -------------------------------------
# The menu reads the controller directly through XInput, so no AutoHotkey
# key translation is needed while CLInt is focused. Buttons map onto the
# same ConsoleKey values the keyboard switch statements already handle,
# and a disconnected controller is simply "no buttons pressed"
# (XInputGetState returns non-zero) - nothing to crash.
$script:padOk = $true
try {
    Add-Type -Namespace CLIntPad -Name XInput -MemberDefinition @'
[StructLayout(LayoutKind.Sequential)]
private struct XINPUT_GAMEPAD { public ushort wButtons; public byte bLeftTrigger; public byte bRightTrigger; public short sThumbLX; public short sThumbLY; public short sThumbRX; public short sThumbRY; }
[StructLayout(LayoutKind.Sequential)]
private struct XINPUT_STATE { public uint dwPacketNumber; public XINPUT_GAMEPAD Gamepad; }
[DllImport("xinput1_4.dll")]
private static extern uint XInputGetState(uint dwUserIndex, ref XINPUT_STATE pState);
public static int GetButtons() {
    int b = 0;
    var s = new XINPUT_STATE();
    for (uint i = 0; i < 4; i++) {
        try { if (XInputGetState(i, ref s) == 0) b |= s.Gamepad.wButtons; }
        catch (DllNotFoundException) { return -1; }
    }
    return b;
}
'@
} catch { $script:padOk = $false }

# Button masks -> menu keys; d-pad directions auto-repeat while held.
$PAD_BUTTONS = @(
    @{ Mask = 0x0001; Key = [ConsoleKey]::UpArrow;    Repeat = $true  }   # d-pad up
    @{ Mask = 0x0002; Key = [ConsoleKey]::DownArrow;  Repeat = $true  }   # d-pad down
    # Left/right only switch tabs, so they must NOT auto-repeat: an empty
    # tab redraws instantly, and a brief hold would repeat and skip past it.
    @{ Mask = 0x0004; Key = [ConsoleKey]::LeftArrow;  Repeat = $false }   # d-pad left
    @{ Mask = 0x0008; Key = [ConsoleKey]::RightArrow; Repeat = $false }   # d-pad right
    @{ Mask = 0x1000; Key = [ConsoleKey]::Enter;      Repeat = $false }   # A = launch/open
    @{ Mask = 0x2000; Key = [ConsoleKey]::Escape;     Repeat = $false }   # B = back/quit
    @{ Mask = 0x8000; Key = [ConsoleKey]::RightArrow; Repeat = $false }   # Y = next tab
    @{ Mask = 0x0200; Key = [ConsoleKey]::F5;         Repeat = $false }   # RB = cycle TDP
    @{ Mask = 0x0100; Key = [ConsoleKey]::PageDown;   Repeat = $true  }   # LB = jump a page
)
$script:padPrev = 0
$script:padHeld = $null
$PAD_DELAY  = 350    # ms a direction must be held before it starts repeating
$PAD_REPEAT = 50     # ms between repeats while held

function Get-PadKey {
    if (-not $script:padOk) { return $null }
    $b = [CLIntPad.XInput]::GetButtons()
    if ($b -lt 0) { $script:padOk = $false; return $null }   # no XInput DLL on this system
    if ($script:conHwnd -ne [IntPtr]::Zero -and
        [CLIntFocus.Win]::GetForegroundWindow() -ne $script:conHwnd) {
        # Another window has focus: those presses belong to it. Track the
        # state anyway so nothing fires spuriously when focus returns.
        $script:padPrev = $b
        $script:padHeld = $null
        return $null
    }
    $fresh = $b -band (-bnot $script:padPrev)
    $script:padPrev = $b
    foreach ($m in $PAD_BUTTONS) {
        if ($fresh -band $m.Mask) {
            $script:padHeld = if ($m.Repeat) {
                @{ Mask = $m.Mask; Key = $m.Key; Until = [Environment]::TickCount + $PAD_DELAY }
            } else { $null }
            return $m.Key
        }
    }
    if ($script:padHeld) {
        if (-not ($b -band $script:padHeld.Mask)) { $script:padHeld = $null }
        elseif ([Environment]::TickCount -ge $script:padHeld.Until) {
            $script:padHeld.Until = [Environment]::TickCount + $PAD_REPEAT
            return $script:padHeld.Key
        }
    }
    return $null
}

# Blocking wait for the next input, whichever device it comes from.
# Returns a [ConsoleKey], so callers switch on it exactly like .Key.
$script:bufferCheckNext = 0
# Cell row -> selectable item index, moving the selection bar there.
# Returns the index, or -1 when the row holds no selectable item. Edge
# rows double as the scroll-hint rows, so any repaint re-stamps them.
function Select-RowAt([int]$y) {
    $i = $script:offset + ($y - $script:listTop)
    if ($y -lt $script:listTop -or $y -ge $script:listTop + $script:visible -or
        $i -ge $script:items.Count -or $script:items[$i].Unselectable) { return -1 }
    if ($i -ne $script:selected) {
        $old = $script:selected
        $script:selected = $i
        Draw-GameLine $old
        Draw-GameLine $i
        Draw-ScrollHints
    }
    return $i
}

# Drain queued mouse events. They share the input buffer with key events -
# and [Console]::KeyAvailable silently throws away whatever non-key events
# sit in front of it - so this must run FIRST in the input loop. Hover
# moves the selection, a left click activates (returned as 'Enter'), a
# click on the tab bar switches tabs, the wheel maps onto the arrows.
# Inside modals events are consumed and dropped: the main-screen geometry
# used here does not apply there.
function Read-MouseEvent {
    if (-not ($script:mouseOk -and $script:mouseEnabled)) { return $null }
    try {
        # $hin, NOT $h: a $h local here shadows the script's $H (window
        # height) for every function called below - Switch-Tab -> Draw-All
        # -> Get-Layout once computed visible = handle - 8 and every draw
        # after that wrote far outside the buffer (blank/broken screen).
        $hin = [CLIntMouse.Win]::GetStdHandle(-10)
        while ($true) {
            $n = [uint32]0
            if (-not [CLIntMouse.Win]::GetNumberOfConsoleInputEvents($hin, [ref]$n) -or $n -eq 0) { return $null }
            $r = New-Object CLIntMouse.Rec
            $got = [uint32]0
            if (-not [CLIntMouse.Win]::PeekConsoleInput($hin, [ref]$r, 1, [ref]$got) -or $got -eq 0) { return $null }
            if ($r.EventType -ne 2) { return $null }   # a key is in front: ReadKey's turn
            [CLIntMouse.Win]::ReadConsoleInput($hin, [ref]$r, 1, [ref]$got) | Out-Null
            if ($r.Flags -band 4) {   # wheel: plain arrows, so it works in modals too
                $down = [bool]($r.Btn -band 0x80000000)
                # collapse a queued burst of same-direction notches - a fast
                # flick queues faster than a big-library redraw drains
                while ($true) {
                    $n2 = [uint32]0
                    if (-not [CLIntMouse.Win]::GetNumberOfConsoleInputEvents($hin, [ref]$n2) -or $n2 -eq 0) { break }
                    $p = New-Object CLIntMouse.Rec
                    $g2 = [uint32]0
                    if (-not [CLIntMouse.Win]::PeekConsoleInput($hin, [ref]$p, 1, [ref]$g2) -or $g2 -eq 0) { break }
                    if ($p.EventType -ne 2 -or -not ($p.Flags -band 4) -or
                        ([bool]($p.Btn -band 0x80000000)) -ne $down) { break }
                    [CLIntMouse.Win]::ReadConsoleInput($hin, [ref]$p, 1, [ref]$g2) | Out-Null
                }
                if ($down) { return 'DownArrow' } else { return 'UpArrow' }
            }
            $leftNow = [bool]($r.Btn -band 1)
            $isMove  = [bool]($r.Flags -band 1)
            # a press is a fresh left-down on a plain button event (flags 0,
            # or 2 for the double-click repeat - already down, so no edge)
            $press   = -not $isMove -and $leftNow -and -not $script:mouseLeftWas
            $script:mouseLeftWas = $leftNow
            if ($script:inModal) {
                # inside a modal the published mouse map decides what a row
                # means; the modal's own input loop acts on the pseudo-keys
                $mi = $script:modalOff + ($r.Y - $script:modalTop)
                if ($script:modalTop -lt 0 -or $r.Y -lt $script:modalTop -or
                    $r.Y -ge $script:modalTop + $script:modalRows -or
                    $mi -ge $script:modalCount) { continue }
                if ($isMove) {
                    if ($mi -ne $script:modalHover) { $script:modalHover = $mi; return 'MouseHover' }
                } elseif ($press) { $script:modalHover = $mi; return 'MouseClick' }
                continue
            }
            if ($isMove) {   # movement: hover-select the row under the cursor
                Select-RowAt $r.Y | Out-Null
                continue
            }
            if (-not $press) { continue }
            if ($r.Y -eq 0) {   # tab bar
                foreach ($hit in $script:tabHit) {
                    if ($r.X -ge $hit[0] -and $r.X -le $hit[1]) {
                        if ($hit[2] -ne $script:tab) { Switch-Tab ($hit[2] - $script:tab) }
                        break
                    }
                }
                continue
            }
            if ((Select-RowAt $r.Y) -ge 0) { return 'Enter' }
        }
    } catch {
        try {
            "$(Get-Date -Format s)  mouse: $($_.Exception.Message)`n$($_.ScriptStackTrace)`n" |
                Add-Content (Join-Path $script:dataDir 'error.log')
        } catch {}
        return $null
    }
}

# Keyboard auto-repeat queues arrows faster than a big-library scroll
# redraw drains them; the backlog then replays absurdly fast and outlives
# the key release. After reading an arrow, consume any auto-repeat
# keydowns of the SAME arrow still queued (peeked, so nothing else is
# eaten). A key-up stops the drain, so deliberate rapid taps all count.
function Drain-RepeatArrows([string]$arrow) {
    if (-not $script:mouseOk) { return }   # same P/Invoke class as the mouse
    $vk = if ($arrow -eq 'UpArrow') { 0x26 } else { 0x28 }
    try {
        $hin = [CLIntMouse.Win]::GetStdHandle(-10)
        while ($true) {
            $n = [uint32]0
            if (-not [CLIntMouse.Win]::GetNumberOfConsoleInputEvents($hin, [ref]$n) -or $n -eq 0) { return }
            $r = New-Object CLIntMouse.Rec
            $got = [uint32]0
            if (-not [CLIntMouse.Win]::PeekConsoleInput($hin, [ref]$r, 1, [ref]$got) -or $got -eq 0) { return }
            # KEY_EVENT overlaps the mouse fields: X = bKeyDown (low half),
            # Btn high word = wVirtualKeyCode
            if ($r.EventType -ne 1 -or $r.X -eq 0 -or
                ((($r.Btn -shr 16) -band 0xFFFF) -ne $vk)) { return }
            [CLIntMouse.Win]::ReadConsoleInput($hin, [ref]$r, 1, [ref]$got) | Out-Null
        }
    } catch {}
}

function Read-InputKey {
    while ($true) {
        $mk = Read-MouseEvent
        if ($mk) { return $mk }
        if ([Console]::KeyAvailable) {
            $k = ([Console]::ReadKey($true)).Key
            if ("$k" -in 'UpArrow', 'DownArrow') { Drain-RepeatArrows "$k" }
            return $k
        }
        $k = Get-PadKey
        if ($null -ne $k) { return $k }
        # The window can resize while we sit here waiting (the fullscreen
        # transition settles a beat after launch, frames get dragged), and
        # a buffer wider than the window means a scrollbar until the next
        # keypress triggered a redraw. Re-pin the buffer promptly instead.
        # Buffer only - no redraw, because modals share this loop.
        if ([Environment]::TickCount -ge $script:bufferCheckNext) {
            $script:bufferCheckNext = [Environment]::TickCount + 300
            try {
                $cw = [Console]::WindowWidth
                $ch = [Console]::WindowHeight
                if ([Console]::BufferWidth -ne $cw -or [Console]::BufferHeight -ne $ch) {
                    $Host.UI.RawUI.BufferSize = New-Object System.Management.Automation.Host.Size($cw, $ch)
                }
            } catch {}
            Hide-Scrollbars   # conhost leaves stale bars behind after transient mismatches
            # clock/battery refresh (suppressed while a modal owns the screen)
            if (-not $script:inModal) {
                if ([Environment]::TickCount -ge $script:batteryNext) {
                    $script:batteryNext = [Environment]::TickCount + 60000
                    $b = $null
                    try { $b = (Get-CimInstance -ClassName Win32_Battery -ErrorAction SilentlyContinue |
                                Select-Object -First 1).EstimatedChargeRemaining } catch {}
                    $script:batteryPct = if ($null -ne $b) { [int]$b } else { -1 }
                    if ($tdpEnabled) {
                        $script:tdpNowW = -1
                        try { $t = Get-CurrentTdp; if ($t) { $script:tdpNowW = [int][Math]::Round($t.Stapm) } } catch {}
                    }
                }
                $stNow = Get-StatusText
                if ($stNow -ne $script:statusLast) {
                    # grown past the reserved corner (TDP first appearing,
                    # battery hitting 100%)? re-fit the tabs with a full
                    # redraw; otherwise update the corner in place.
                    if ($stNow.Length + 2 -gt $script:statusReserved) { Draw-All }
                    else { Draw-Status }
                }
            }
        }
        Start-Sleep -Milliseconds 16
    }
}

function Get-PickerEntries($dir) {
    $list = @()
    if ($null -eq $dir) {   # drive list
        # A drive can be present but dying (card readers, USB drives mid-
        # disconnect) - probing it may throw, and with EAP=Stop that used
        # to take the whole app down. Skip anything that won't answer.
        foreach ($d in (Get-PSDrive -PSProvider FileSystem -ErrorAction SilentlyContinue | Sort-Object Name)) {
            $alive = $false
            try { $alive = Test-Path $d.Root -ErrorAction SilentlyContinue } catch {}
            if ($alive) {
                $list += [pscustomobject]@{ Name = $d.Root; Path = $d.Root; Type = 'Dir' }
            }
        }
    } else {
        $list += [pscustomobject]@{ Name = '[ use this folder ]'; Path = $dir; Type = 'Pick' }
        $list += [pscustomobject]@{ Name = '..'; Path = $null; Type = 'Up' }
        # Get-ChildItem already skips attribute-hidden folders; also skip
        # dot-prefixed ones (.git, .vscode, ...), hidden by convention.
        $list += @(Get-ChildItem $dir -Directory -ErrorAction SilentlyContinue | Sort-Object Name |
            Where-Object { -not $_.Name.StartsWith('.') } |
            ForEach-Object { [pscustomobject]@{ Name = $_.Name + '\'; Path = $_.FullName; Type = 'Dir' } })
    }
    return $list
}

# Modal folder browser: A opens a folder or picks the current one via the
# top entry, B goes up a level (above a drive root: the drive list, then
# cancel). Returns the chosen path, or $null if cancelled.
function Pick-Folder([string]$label, [string]$start) {
    $script:inModal = $true
    $dir = $start
    if (-not $dir -or -not (Test-Path $dir -ErrorAction SilentlyContinue)) { $dir = $env:USERPROFILE }
    $sel = 0; $off = 0
    $entries = @()
    $needList = $true
    Clear-Host
    Get-Layout
    while ($true) {
        if ($needList) {
            $entries = @(Get-PickerEntries $dir)
            if ($sel -ge $entries.Count) { $sel = [Math]::Max(0, $entries.Count - 1) }
            $needList = $false
        }
        Write-At 2 0 (Pad "CHOOSE FOLDER  --  $label" ($W - 4)) $theme.Accent
        Write-At 2 1 (Pad ("Now: " + $(if ($dir) { $dir } else { 'select a drive' })) ($W - 4)) $theme.Info
        Write-At 2 3 '[ D-pad: move    A: open / choose    B: up / cancel ]' $theme.Hint
        $top = 5
        $rows = [Math]::Max(1, $H - $top - 1)
        if ($sel -lt $off) { $off = $sel }
        if ($sel -ge $off + $rows) { $off = $sel - $rows + 1 }
        # NB: the row width must NOT be named $w - PowerShell variables are
        # case-insensitive, so a local "$w = $W - 3" reads its own previous
        # value from the second iteration on, shrinking the width by 3 per
        # drawn row until string ops throw. That crashed the picker once.
        $rowW = $W - 3
        for ($r = 0; $r -lt $rows; $r++) {
            $i = $off + $r
            if ($i -lt $entries.Count) {
                if ($i -eq $sel) { Write-At 1 ($top + $r) (Pad ('  >> ' + $entries[$i].Name + '  ') $rowW) $theme.SelFg $theme.Accent }
                else             { Write-At 1 ($top + $r) (Pad ('     ' + $entries[$i].Name + '  ') $rowW) $theme.Text }
            } else {
                Write-At 1 ($top + $r) (' ' * $rowW) $theme.Text
            }
        }
        # republish the mouse map every frame: the list scrolls ($off) and
        # changes length as folders are entered
        $script:modalTop = $top; $script:modalOff = $off
        $script:modalRows = $rows; $script:modalCount = $entries.Count
        $key = Read-InputKey
        switch ($key) {
            'UpArrow'    { if ($entries.Count) { $sel = ($sel - 1 + $entries.Count) % $entries.Count } }
            'DownArrow'  { if ($entries.Count) { $sel = ($sel + 1) % $entries.Count } }
            'MouseHover' { $sel = $script:modalHover }
            { "$_" -in 'Enter', 'MouseClick' } {
                if ("$_" -eq 'MouseClick') { $sel = $script:modalHover }
                if ($entries.Count -gt 0) {
                    $e = $entries[$sel]
                    if ($e.Type -eq 'Pick') { return $e.Path }
                    elseif ($e.Type -eq 'Dir') { $dir = $e.Path; $sel = 0; $off = 0; $needList = $true }
                    else {   # '..'
                        $parent = Split-Path $dir -Parent
                        $dir = if ([string]::IsNullOrEmpty($parent)) { $null } else { $parent }
                        $sel = 0; $off = 0; $needList = $true
                    }
                }
            }
            'Escape'    {
                if ($null -eq $dir) { return $null }   # B in the drive list cancels
                $parent = Split-Path $dir -Parent
                $dir = if ([string]::IsNullOrEmpty($parent)) { $null } else { $parent }
                $sel = 0; $off = 0; $needList = $true
            }
            'Q'         { return $null }
        }
    }
}

# Small modal list of choices; returns the chosen index, or -1 on cancel.
function Pick-Option([string]$title, [string[]]$options) {
    $script:inModal = $true
    $sel = 0
    $script:modalTop = 4; $script:modalOff = 0
    $script:modalRows = $options.Count; $script:modalCount = $options.Count
    $script:modalHover = 0
    Clear-Host
    Get-Layout
    while ($true) {
        Write-At 2 0 (Pad $title ($W - 4)) $theme.Accent
        Write-At 2 2 '[ D-pad: move    A: choose    B: cancel ]' $theme.Hint
        for ($i = 0; $i -lt $options.Count; $i++) {
            if ($i -eq $sel) { Write-At 1 (4 + $i) (Pad ('  >> ' + $options[$i] + '  ') ($W - 3)) $theme.SelFg $theme.Accent }
            else             { Write-At 1 (4 + $i) (Pad ('     ' + $options[$i] + '  ') ($W - 3)) $theme.Text }
        }
        switch (Read-InputKey) {
            'UpArrow'    { $sel = ($sel - 1 + $options.Count) % $options.Count }
            'DownArrow'  { $sel = ($sel + 1) % $options.Count }
            'MouseHover' { $sel = $script:modalHover }
            { "$_" -in 'Enter', 'MouseClick' } {
                if ("$_" -eq 'MouseClick') { $sel = $script:modalHover }
                return $sel
            }
            'Escape'    { return -1 }
            'Q'         { return -1 }
        }
    }
}

# Icon picker: mascot list on the left, live art preview on the right.
# Returns a mascot name, '::auto' for automatic assignment, $null on cancel.
function Pick-Mascot([string]$title, [string]$current) {
    $script:inModal = $true
    $names = @($mascots.Keys | Where-Object { $_ -ne 'robot' })   # robot belongs to SETTINGS
    $entries = @('(automatic)') + $names
    $sel = [Math]::Max(0, [array]::IndexOf($entries, $current))
    $script:modalTop = 4; $script:modalOff = 0
    $script:modalRows = $entries.Count; $script:modalCount = $entries.Count
    $script:modalHover = $sel
    Clear-Host
    Get-Layout
    while ($true) {
        Write-At 2 0 (Pad $title ($W - 4)) $theme.Accent
        Write-At 2 2 '[ D-pad: move    A: choose    B: cancel ]' $theme.Hint
        for ($i = 0; $i -lt $entries.Count; $i++) {
            $label = $entries[$i] + $(if ($entries[$i] -eq $current) { '  (current)' } else { '' })
            if ($i -eq $sel) { Write-At 1 (4 + $i) (Pad ('  >> ' + $label + '  ') 30) $theme.SelFg $theme.Accent }
            else             { Write-At 1 (4 + $i) (Pad ('     ' + $label + '  ') 30) $theme.Text }
        }
        $art = if ($sel -gt 0) { $mascots[$entries[$sel]] } else { $null }
        for ($r = 0; $r -lt 7; $r++) {
            $line = if ($art -and $r -lt $art.Count) { $art[$r] } else { '' }
            Write-At 36 (4 + $r) (Pad $line 24) $theme.Logo
        }
        switch (Read-InputKey) {
            'UpArrow'    { $sel = ($sel - 1 + $entries.Count) % $entries.Count }
            'DownArrow'  { $sel = ($sel + 1) % $entries.Count }
            'MouseHover' { $sel = $script:modalHover }
            { "$_" -in 'Enter', 'MouseClick' } {
                if ("$_" -eq 'MouseClick') { $sel = $script:modalHover }
                if ($sel -eq 0) { return '::auto' } else { return $entries[$sel] }
            }
            'Escape'    { return $null }
            'Q'         { return $null }
        }
    }
}

# Modal text prompt: type on the keyboard, Enter/A saves, Esc/B cancels.
# Returns the text, or $null if cancelled. An empty result means "no
# override" - callers treat it as "back to the automatic value".
function Read-TextInput([string]$title, [string]$current) {
    $script:inModal = $true
    $script:modalTop = -1   # keyboard-only modal: no mouse map
    Clear-Host
    Get-Layout
    Write-At 2 0 (Pad $title ($W - 4)) $theme.Accent
    Write-At 2 2 '[ type on the keyboard    Enter/A: save    Esc/B: cancel    empty: automatic name ]' $theme.Hint
    $text = $current
    while ($true) {
        Write-At 2 4 (Pad ('> ' + $text + '_') ($W - 4)) $theme.Bright
        if ([Console]::KeyAvailable) {
            $k = [Console]::ReadKey($true)
            switch ($k.Key) {
                'Enter'     { return $text }
                'Escape'    { return $null }
                'Backspace' { if ($text.Length) { $text = $text.Substring(0, $text.Length - 1) } }
                default     { if ($k.KeyChar -and -not [char]::IsControl($k.KeyChar)) { $text += $k.KeyChar } }
            }
        } else {
            $p = Get-PadKey
            if ($p -eq [ConsoleKey]::Enter)  { return $text }
            if ($p -eq [ConsoleKey]::Escape) { return $null }
            Start-Sleep -Milliseconds 16
        }
    }
}

# SETTINGS actions on a configured tab: rename, reorder, retarget, remove.
function Edit-TabConfig([int]$i) {
    $cfg = $settings['Tabs'][$i]
    $opts = @()
    if ($cfg.Type -eq 'Steam') { $opts += 'Change collection' }
    else                       { $opts += 'Change folder' }
    $opts += @('Rename tab', 'Change icon', 'Move left', 'Move right', 'Remove tab', 'Cancel')
    $choice = Pick-Option "TAB $($i + 1): $($tabs[$i].Name)" $opts
    if ($choice -lt 0) { return }
    switch ($opts[$choice]) {
        'Change folder' {
            $p = Pick-Folder "new folder for this tab" $cfg.Path
            if ($p) { $cfg.Path = $p; $cfg.Remove('Name') }   # re-derive the title
        }
        'Change collection' {
            $cols = @(Get-SteamCollections)
            $names = @('Whole library') + @($cols | ForEach-Object { "$($_.Name)  ($(@($_.Added).Count) games)" })
            $c = Pick-Option "TAB $($i + 1)  --  WHICH STEAM GAMES?" ($names + @('Cancel'))
            if ($c -eq 0) {
                $cfg.Remove('Collection'); $cfg.Remove('CollectionId'); $cfg.Remove('Name')
            } elseif ($c -gt 0 -and $c -le $cols.Count) {
                $col = $cols[$c - 1]
                $cfg.Collection = $col.Name; $cfg.CollectionId = $col.Id
                $cfg.Remove('Name')   # re-derive the title from the collection
            }
        }
        'Rename tab' {
            # Prefill with the current title (auto-derived or custom), so
            # renaming means editing what's already there, not retyping it.
            $n = Read-TextInput "RENAME TAB: $($tabs[$i].Name)" ([string]$tabs[$i].Name)
            if ($null -ne $n) {
                $n = $n.Trim()
                if ($n) { $cfg.Name = $n } else { $cfg.Remove('Name') }   # empty = automatic
            }
        }
        'Change icon' {
            $m = Pick-Mascot "ICON FOR: $($tabs[$i].Name)" $tabs[$i].Icon
            if ($m -eq '::auto') { $cfg.Remove('Icon') }
            elseif ($m)          { $cfg.Icon = $m }
        }
        'Move left' {
            if ($i -gt 0) {
                $tmp = $settings['Tabs'][$i - 1]
                $settings['Tabs'][$i - 1] = $cfg
                $settings['Tabs'][$i] = $tmp
            }
        }
        'Move right' {
            if ($i -lt $settings['Tabs'].Count - 1) {
                $tmp = $settings['Tabs'][$i + 1]
                $settings['Tabs'][$i + 1] = $cfg
                $settings['Tabs'][$i] = $tmp
            }
        }
        'Remove tab' {
            $settings['Tabs'] = @($settings['Tabs'] | Where-Object { $_ -ne $cfg })
        }
        'Cancel' { return }
    }
    Apply-TabConfig
}

function Add-TabConfig {
    if ($settings['Tabs'].Count -ge $MAX_TABS) {
        $script:pendingNotice = "Tab limit reached ($MAX_TABS) - remove a tab first"
        return
    }
    $choice = Pick-Option 'ADD A TAB' @(
        'Steam games      - Steam library, incl. non-Steam shortcuts',
        'Shortcuts folder - .lnk shortcuts launched as games/apps',
        'Files folder     - browse and play videos, open any file',
        'Cancel')
    switch ($choice) {
        0 {
            if ($games.Count -eq 0) {
                try { $script:games = @(Get-SteamLibrary) } catch {}
                Add-MaProfileTags $games
            }
            $newTab = @{ Type = 'Steam' }
            $proceed = $true
            $cols = @(Get-SteamCollections)
            if ($cols.Count -gt 0) {
                $names = @('Whole library') + @($cols | ForEach-Object { "$($_.Name)  ($(@($_.Added).Count) games)" })
                $c = Pick-Option 'STEAM TAB  --  WHICH GAMES?' ($names + @('Cancel'))
                if ($c -lt 0 -or $c -ge $names.Count) { $proceed = $false }
                elseif ($c -gt 0) {
                    $col = $cols[$c - 1]
                    $newTab.Collection = $col.Name
                    $newTab.CollectionId = $col.Id
                }
            }
            if ($proceed) {
                $settings['Tabs'] += $newTab
                Apply-TabConfig
            }
        }
        1 {
            $p = Pick-Folder 'folder with .lnk shortcuts' ([Environment]::GetFolderPath('Desktop'))
            if ($p) { $settings['Tabs'] += @{ Type = 'Shortcuts'; Path = $p }; Apply-TabConfig }
        }
        2 {
            $p = Pick-Folder 'folder to browse' ([Environment]::GetFolderPath('MyVideos'))
            if ($p) { $settings['Tabs'] += @{ Type = 'Files'; Path = $p }; Apply-TabConfig }
        }
    }
}

# First launch with no tab config (fresh install, or right after a full
# settings reset): offer the two folder tabs using the same pickers
# SETTINGS uses. A Steam tab is already seeded when Steam is installed;
# everything here is skippable and available later via SETTINGS > add a tab.
function Invoke-FirstRunSetup {
    $desk = Join-Path ([Environment]::GetFolderPath('Desktop')) 'Game Shortcuts'
    $c = Pick-Option 'WELCOME TO CLINT  --  ADD A SHORTCUTS TAB?  (launches .lnk shortcuts you drop in a folder)' @(
        "Yes - use $desk",
        'Yes - pick a folder',
        'No  (tabs can be added any time in SETTINGS)')
    if ($c -eq 0) {
        if (-not (Test-Path $desk)) { New-Item -ItemType Directory -Force $desk | Out-Null }
        $settings['Tabs'] += @{ Type = 'Shortcuts'; Path = $desk }
    } elseif ($c -eq 1) {
        $p = Pick-Folder 'folder with .lnk shortcuts' ([Environment]::GetFolderPath('Desktop'))
        if ($p) { $settings['Tabs'] += @{ Type = 'Shortcuts'; Path = $p } }
    }
    $vids = [Environment]::GetFolderPath('MyVideos')
    $c = Pick-Option 'WELCOME TO CLINT  --  ADD A VIDEOS / FILES TAB?  (browse a folder, play videos)' @(
        "Yes - use $vids",
        'Yes - pick a folder',
        'No  (tabs can be added any time in SETTINGS)')
    if ($c -eq 0) {
        $settings['Tabs'] += @{ Type = 'Files'; Path = $vids }
    } elseif ($c -eq 1) {
        $p = Pick-Folder 'folder to browse' $vids
        if ($p) { $settings['Tabs'] += @{ Type = 'Files'; Path = $p } }
    }
    # Persist even all-skips: settings.json gains the Tabs key, so this
    # setup runs exactly once.
    Save-Settings
    Build-Tabs
    $script:tab      = 0
    $script:items    = @(Get-TabItems 0)
    $script:selected = 0
    $script:offset   = 0
    Snap-Selection
}

function Wait-ForGameExit($game, [int]$holdTdpW = 0, [int]$startTimeoutS = 90) {
    if ($game.Exe) {
        # Non-Steam shortcut: Steam doesn't track these in the registry,
        # so watch the exe's process instead.
        $proc = [System.IO.Path]::GetFileNameWithoutExtension($game.Exe)
        $deadline = [DateTime]::Now.AddSeconds($startTimeoutS)
        while ([DateTime]::Now -lt $deadline) {
            if (Get-Process -Name $proc -ErrorAction SilentlyContinue) { break }
            Start-Sleep -Milliseconds 500
        }
        $holdUntil = [DateTime]::Now.AddSeconds(45)
        $graceEnd  = [DateTime]::Now.AddSeconds(8)   # let the game claim focus itself first
        while (Get-Process -Name $proc -ErrorAction SilentlyContinue) {
            if ([DateTime]::Now -lt $holdUntil) {
                if ($holdTdpW) { Assert-Tdp $holdTdpW }
                if ([DateTime]::Now -ge $graceEnd) { Hide-MenuForGame }
            }
            Start-Sleep -Seconds 2
        }
        return
    }
    # Steam flips this registry value to 1 while the game is running.
    $key = "HKCU:\Software\Valve\Steam\Apps\$($game.AppId)"
    $deadline = [DateTime]::Now.AddSeconds($startTimeoutS)
    while ([DateTime]::Now -lt $deadline) {
        if ((Get-ItemProperty $key -ErrorAction SilentlyContinue).Running -eq 1) { break }
        Start-Sleep -Milliseconds 500
    }
    $holdUntil = [DateTime]::Now.AddSeconds(45)
    $graceEnd  = [DateTime]::Now.AddSeconds(8)   # let the game claim focus itself first
    while ((Get-ItemProperty $key -ErrorAction SilentlyContinue).Running -eq 1) {
        if ([DateTime]::Now -lt $holdUntil) {
            if ($holdTdpW) { Assert-Tdp $holdTdpW }
            if ([DateTime]::Now -ge $graceEnd) { Hide-MenuForGame }
        }
        Start-Sleep -Seconds 2
    }
}

function Move-Selection([int]$delta) {
    if ($items.Count -eq 0) { return }
    Clear-Notice
    $old = $script:selected
    $new = ($script:selected + $delta + $items.Count) % $items.Count
    # Section rows can't hold the cursor: keep sliding the way we were
    # going (wrapping, just like the move itself) until a real item.
    $step = if ($delta -lt 0) { -1 } else { 1 }
    $guard = $items.Count
    while ($items[$new].Unselectable -and $guard-- -gt 0) {
        $new = ($new + $step + $items.Count) % $items.Count
    }
    $script:selected = $new
    if ($script:selected -lt $script:offset) {
        $script:offset = $script:selected
        Draw-List
    } elseif ($script:selected -ge $script:offset + $script:visible) {
        $script:offset = $script:selected - $script:visible + 1
        Draw-List
    } else {
        Draw-GameLine $old        # repaint only the two lines that changed
        Draw-GameLine $script:selected
        Draw-ScrollHints          # in case either line was an indicator row
    }
}

try {
    [Console]::CursorVisible = $false
    # Claim the foreground FIRST: launched from a hotkey or shortcut while
    # another app is focused, a new conhost can be denied focus by Windows.
    # Fullscreen comes after - its Alt+Enter rungs work best on a window
    # that genuinely holds focus.
    if ($script:conHwnd -ne [IntPtr]::Zero) {
        try { [CLIntFocus.Win]::SetForegroundWindow($script:conHwnd) | Out-Null } catch {}
    }
    try { (New-Object -ComObject WScript.Shell).AppActivate('CLInt') | Out-Null } catch {}
    Set-ConsoleFullscreen   # always: launching CLInt means fullscreen
    Set-MouseMode $mouseEnabled
    # Opt-in quiet update check: a hidden helper compares versions and
    # leaves update-available.txt for the UI to notice. Never blocks.
    if ($script:autoCheck) {
        try {
            Start-Process powershell.exe -WindowStyle Hidden -ArgumentList `
                "-NoProfile -ExecutionPolicy Bypass -File `"$(Join-Path $PSScriptRoot 'Update.ps1')`" -CheckOnly"
        } catch {}
    }
    Draw-All
    # Drop any keypress still buffered from launching the shortcut (e.g. the
    # Enter that opened it), otherwise it instantly launches the first game.
    Start-Sleep -Milliseconds 400
    while ([Console]::KeyAvailable) { [Console]::ReadKey($true) | Out-Null }
    if ($script:firstRunSetup) {
        $script:firstRunSetup = $false
        Invoke-FirstRunSetup
        Draw-All
    }
    while ($true) {
        $key = Read-InputKey
        $cur = $tabs[$tab]
        # Safety net: with EAP=Stop, any unexpected error (a dying drive, a
        # file with no association, ...) would otherwise unwind straight out
        # of the loop and close the app. Log it, tell the user, carry on.
        try {
        switch ($key) {
            'UpArrow'   { Move-Selection -1 }
            'DownArrow' { Move-Selection 1 }
            'PageDown'  {   # LB: a page at a time, clamped to the end -
                            # free-running modulo math on a list barely
                            # longer than a page LOOKS like reverse cycling
                if ($items.Count -gt 0) {
                    if ($selected -ge $items.Count - 1) { Move-Selection ((Get-FirstSelectable) - $selected) }   # at the end: wrap to top
                    else { Move-Selection ([Math]::Min($visible, $items.Count - 1 - $selected)) }
                }
            }
            'PageUp'    {
                if ($items.Count -gt 0) {
                    $first = Get-FirstSelectable
                    if ($selected -le $first) { Move-Selection ($items.Count - 1 - $selected) }   # at the top: wrap to end
                    else { Move-Selection (-([Math]::Min($visible, $selected - $first))) }
                }
            }
            'Home'      { Move-Selection ((Get-FirstSelectable) - $selected) }
            'End'       { Move-Selection ($items.Count - 1 - $selected) }
            'LeftArrow'  { Switch-Tab -1 }
            'RightArrow' { Switch-Tab 1 }
            'Enter'     {
                if ($items.Count -eq 0) {
                    # An empty Shortcuts tab is almost always a wrong or
                    # not-yet-created folder: offer to repoint or remove it.
                    if ($cur.Type -eq 'Shortcuts' -and $tab -lt $settings['Tabs'].Count) {
                        $cfg = $settings['Tabs'][$tab]
                        $c = Pick-Option "THIS TAB HAS NO SHORTCUTS  --  $($cfg.Path)" @(
                            'Choose a different folder', 'Remove this tab', 'Cancel')
                        switch ($c) {
                            0 {
                                $p = Pick-Folder 'folder with .lnk shortcuts' $cfg.Path
                                if ($p) {
                                    $cfg.Path = $p; $cfg.Remove('Name')
                                    Save-Settings; Build-Tabs
                                    $script:items = @(Get-TabItems $tab)
                                    $script:selected = 0; $script:offset = 0
                                    Snap-Selection
                                }
                            }
                            1 {
                                $settings['Tabs'] = @($settings['Tabs'] | Where-Object { $_ -ne $cfg })
                                Save-Settings; Build-Tabs
                                $script:tab = [Math]::Min($tab, $tabs.Count - 1)
                                $script:items = @(Get-TabItems $tab)
                                $script:selected = 0; $script:offset = 0
                                Snap-Selection
                            }
                        }
                        Draw-All
                    }
                    break
                }
                if ($cur.Type -eq 'Settings') {
                    $s = $items[$selected]
                    switch ($s.Key) {
                        'Tab'    { Edit-TabConfig $s.Index }
                        'AddTab' { Add-TabConfig }
                        'Quit'   { Clear-Host; exit 0 }
                        'ResetAll' {
                            $c = Pick-Option 'RESET ALL SETTINGS - ARE YOU SURE?' @(
                                'Yes - reset tabs, theme and options to defaults (restarts CLInt)', 'Cancel')
                            if ($c -eq 0) {
                                # tabs, theme, text size, toggles - all of
                                # settings.json. History files stay (that is
                                # what clear history is for).
                                Remove-Item (Join-Path $script:dataDir 'settings.json') -Force -ErrorAction SilentlyContinue
                                if ($script:instanceMutex) {
                                    try { $script:instanceMutex.ReleaseMutex() } catch {}
                                    $script:instanceMutex.Dispose()
                                }
                                Start-Process "$env:SystemRoot\System32\conhost.exe" -ArgumentList `
                                    "powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"$PSScriptRoot\CLInt.ps1`""
                                exit 0
                            }
                        }
                        'VlcInfo' {
                            $script:pendingNotice = 'With VLC (videolan.org): fullscreen playback, the menu returns when a video ends, and resume markers work.'
                        }
                        'ClearHist' {
                            $c = Pick-Option 'CLEAR HISTORY' @(
                                'Recently played (games)', 'Video play counts', 'Both', 'Cancel')
                            if ($c -ge 0 -and $c -le 2) {
                                $what = @('RECENTLY PLAYED', 'VIDEO PLAY COUNTS', 'BOTH HISTORIES')[$c]
                                $sure = Pick-Option "CLEAR $what - ARE YOU SURE?" @('Yes - clear it', 'Cancel')
                                if ($sure -eq 0) {
                                    if ($c -eq 0 -or $c -eq 2) {
                                        $script:recentMap = @{}
                                        Remove-Item (Join-Path $script:dataDir 'recent.json') -Force -ErrorAction SilentlyContinue
                                    }
                                    if ($c -eq 1 -or $c -eq 2) {
                                        $script:watchMap = @{}
                                        Remove-Item (Join-Path $script:dataDir 'watch-history.json') -Force -ErrorAction SilentlyContinue
                                    }
                                    Build-Tabs
                                    $script:pendingNotice = 'History cleared'
                                }
                            }
                        }
                        'Fullscreen' {
                            # Session-only: nothing is persisted, so the next
                            # launch always starts fullscreen again.
                            if ($script:isFullscreen) { Set-ConsoleWindowed } else { Set-ConsoleFullscreen }
                        }
                        'ShowClock' {
                            $script:showClock = -not $script:showClock
                            $settings['ShowClock'] = $script:showClock
                            Save-Settings
                        }
                        'ShowBattery' {
                            $script:showBattery = -not $script:showBattery
                            $settings['ShowBattery'] = $script:showBattery
                            Save-Settings
                        }
                        'Recent' {
                            $script:recentEnabled = -not $script:recentEnabled
                            $settings['Recent'] = $script:recentEnabled
                            Save-Settings
                            Build-Tabs   # apply or undo the recent-first sorting
                        }
                        'NonSteam' {
                            $script:nonSteamEnabled = -not $script:nonSteamEnabled
                            $settings['NonSteam'] = $script:nonSteamEnabled
                            Save-Settings
                            try { $script:games = @(Get-SteamLibrary) } catch { $script:games = @() }
                            Add-MaProfileTags $games
                            Build-Tabs   # rebuild Steam tabs with/without non-Steam apps
                        }
                        'AutoCheck' {
                            $script:autoCheck = -not $script:autoCheck
                            $settings['AutoUpdateCheck'] = $script:autoCheck
                            Save-Settings
                        }
                        'Mouse' {
                            $script:mouseEnabled = -not $script:mouseEnabled
                            $settings['Mouse'] = $script:mouseEnabled
                            Save-Settings
                            Set-MouseMode $script:mouseEnabled
                        }
                        'VideoHist' {
                            $script:videoHistEnabled = -not $script:videoHistEnabled
                            $settings['VideoHistory'] = $script:videoHistEnabled
                            Save-Settings
                            Build-Tabs   # rebuild file tabs with/without tags
                        }
                        'TextSize' {
                            $names = @($textSizes.Keys)
                            $c = Pick-Option 'TEXT SIZE' ($names + @('Cancel'))
                            if ($c -ge 0 -and $c -lt $names.Count) {
                                $script:textSizeName = $names[$c]
                                $settings['TextSize'] = $script:textSizeName
                                Save-Settings
                                Set-ConsoleFontSize
                                # cell size changed: re-fit the grid to the screen
                                if ($script:isFullscreen) { Set-ConsoleFullscreen }
                                Hide-Scrollbars
                            }
                        }
                        'Theme'  {
                            $names = @($themes.Keys)
                            $c = Pick-Option 'COLOR THEME' ($names + @('Cancel'))
                            if ($c -ge 0 -and $c -lt $names.Count) {
                                $script:themeName = $names[$c]
                                $script:theme     = $themes[$script:themeName]
                                $settings['Theme'] = $script:themeName
                                Save-Settings
                            }
                        }
                        'Update' {
                            Clear-Host
                            Write-Host ""
                            Write-Host "   CHECKING FOR UPDATES..." -ForegroundColor $theme.Accent
                            Write-Host ""
                            powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'Update.ps1')
                            if ($LASTEXITCODE -eq 0) {
                                Write-Host ""
                                Write-Host "   Updated - restarting the menu..." -ForegroundColor Green
                                Start-Sleep -Seconds 2
                                if ($script:instanceMutex) {
                                    try { $script:instanceMutex.ReleaseMutex() } catch {}
                                    $script:instanceMutex.Dispose()
                                }
                                Start-Process "$env:SystemRoot\System32\conhost.exe" -ArgumentList `
                                    "powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"$PSScriptRoot\CLInt.ps1`""
                                exit 0
                            }
                            Write-Host ""
                            Write-Host "   press any button to go back" -ForegroundColor $theme.Hint
                            # the menu geometry is gone from this screen, so
                            # stray clicks/hovers must not hit-test against it
                            # (Draw-All below resets the flag)
                            $script:inModal = $true
                            Read-InputKey | Out-Null
                        }
                    }
                    $script:items    = @(Get-TabItems $tab)
                    $script:selected = [Math]::Min($selected, [Math]::Max(0, $items.Count - 1))
                    Draw-All
                    if ($script:pendingNotice) {
                        Show-Notice $script:pendingNotice
                        $script:pendingNotice = $null
                    }
                    break
                }
                if ($cur.Type -eq 'Files') {
                    $v = $items[$selected]
                    if ($v.Type -eq 'Dir') { Enter-FileDir $cur $v.Path; break }
                    if ($v.Type -eq 'Up')  { Exit-FileDir $cur | Out-Null; break }
                    $isVideo = [System.IO.Path]::GetExtension($v.Path) -match $videoExtRe
                    Clear-Host
                    Write-Host ""
                    Write-Host "     _____" -ForegroundColor $theme.Accent
                    Write-Host "    | |>  |    NOW PLAYING" -ForegroundColor $theme.Accent
                    Write-Host "    |_|___|    $($v.Name)" -ForegroundColor $theme.Logo
                    Write-Host ""
                    if ($script:videoHistEnabled -and $isVideo) { Record-VideoPlay $v.Path }
                    if ($isVideo -and $vlcExe) {
                        Start-Process $vlcExe -ArgumentList '--fullscreen', '--play-and-exit', "`"$($v.Path)`""
                        Wait-ForGameExit ([pscustomobject]@{ Exe = 'vlc.exe' })
                    } else {
                        Start-Process $v.Path   # default app for this file type
                        Start-Sleep -Seconds 5
                    }
                    Show-MenuWindow
                    if ($script:videoHistEnabled) {
                        # refresh tags: VLC has just written its resume state
                        $keep = $selected
                        $cur.Items = @(Get-FileItems $cur)
                        $script:items = $cur.Items
                        $script:selected = [Math]::Min($keep, [Math]::Max(0, $items.Count - 1))
                    }
                    while ([Console]::KeyAvailable) { [Console]::ReadKey($true) | Out-Null }
                    Draw-All
                    break
                }
                $g = $items[$selected]
                if ($g.Unselectable) { break }   # section row: nothing to launch
                Clear-Host
                Write-Host ""
                Write-Host "      _" -ForegroundColor $theme.Accent
                Write-Host "     /^\      LAUNCHING" -ForegroundColor $theme.Accent
                Write-Host "    |___|" -ForegroundColor $theme.Accent
                Write-Host "    |   |     $($g.Name)" -ForegroundColor $theme.Logo
                Write-Host "    |___|" -ForegroundColor $theme.Accent
                Write-Host "   /|   |\    GLHF o7" -ForegroundColor $theme.Info
                Write-Host "    ^^^^^" -ForegroundColor $theme.Info
                Write-Host ""
                $tdpWatts = Get-GameTdp $g
                $prevTdp = $null
                if ($g.MaProfile) {
                    # Motion Assistant owns this game's TDP; a stale saved
                    # setting from before the profile existed is ignored.
                    $tdpWatts = 0
                    Write-Host "   TDP: managed by Motion Assistant ($($g.MaProfile).ini)" -ForegroundColor DarkYellow
                }
                if ($tdpEnabled -and $tdpWatts) {
                    $prevTdp = Get-CurrentTdp
                    Set-Tdp $tdpWatts ($tdpWatts + 1) $tdpWatts
                    Write-Host "   TDP: $($tdpWatts)W (reverts on exit)" -ForegroundColor $theme.Notice
                }
                $steamCold = $cur.Type -eq 'Steam' -and
                             -not (Get-Process steam -ErrorAction SilentlyContinue)
                if ($steamCold) {
                    Write-Host ""
                    Write-Host "   Steam is starting in the background. Hang on a second..." -ForegroundColor $theme.Notice
                }
                $t0 = [DateTime]::Now
                if ($cur.Type -eq 'Shortcuts') { Start-Process $g.Path }   # run the .lnk itself
                else                           { Start-SteamGame $g.LaunchId }
                Wait-ForGameExit $g $(if ($prevTdp) { $tdpWatts } else { 0 }) $(if ($steamCold) { 240 } else { 90 })
                if ($prevTdp) { Set-Tdp $prevTdp.Stapm $prevTdp.Fast $prevTdp.Slow }
                if ($script:recentEnabled) {
                    Record-Play $g (([DateTime]::Now - $t0).TotalMinutes)
                    # bubble the just-played game to the top of every game tab
                    foreach ($gt in $tabs) {
                        if ($gt.Type -in 'Steam', 'Shortcuts') { $gt.Items = @(Sort-Games $gt.Items) }
                    }
                    $script:items    = $cur.Items
                    $script:selected = [Math]::Max(0, [array]::IndexOf($cur.Items, $g))
                    Snap-Selection
                    $script:offset   = 0
                }
                # bring the menu window back to the front, drop any keys
                # pressed while the game was running, and redraw
                Show-MenuWindow
                $script:batteryNext = 0   # TDP was restored: refresh the corner readout promptly
                while ([Console]::KeyAvailable) { [Console]::ReadKey($true) | Out-Null }
                Draw-All
            }
            'F5'        {   # RB on the gamepad (read natively via XInput)
                if ($tdpEnabled -and $cur.Type -in 'Steam', 'Shortcuts' -and $items.Count -gt 0) {
                    $g = $items[$selected]
                    if ($g.Unselectable) { break }   # section row: no TDP to cycle
                    if ($g.MaProfile) {
                        Show-Notice "TDP locked: Motion Assistant has its own profile for this game ($($g.MaProfile).ini)"
                    } else {
                        Clear-Notice
                        $next = $tdpModes[($tdpModes.IndexOf((Get-GameTdp $g)) + 1) % $tdpModes.Count]
                        if ($next -eq 0) { $tdpMap.Remove([string]$g.AppId) }
                        else             { $tdpMap[[string]$g.AppId] = $next }
                        Save-TdpMap
                        Draw-GameLine $selected
                        Draw-ScrollHints   # in case the selected line is an indicator row
                    }
                }
            }
            'Escape'    {   # in a file-tab subfolder: go up a level; otherwise quit
                if ($cur.Type -eq 'Files' -and (Exit-FileDir $cur)) { break }
                Clear-Host; exit 0
            }
            'Q'         { Clear-Host; exit 0 }
        }
        } catch {
            try {
                "$(Get-Date -Format s)  $($_.Exception.Message)`n$($_.ScriptStackTrace)`n" |
                    Add-Content (Join-Path $script:dataDir 'error.log')
            } catch {}
            try {
                Draw-All
                Show-Notice "Oops - that failed ($($_.Exception.Message -replace '\s+', ' ')). Logged to error.log"
            } catch {}
        }
        # redraw if the window was resized
        if ($W -ne [Console]::WindowWidth -or $H -ne [Console]::WindowHeight) { Draw-All }
    }
} finally {
    [Console]::CursorVisible = $true
}
