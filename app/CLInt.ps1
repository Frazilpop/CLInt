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
[DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
[DllImport("user32.dll")] public static extern bool IsIconic(IntPtr h);
[DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int cmd);
[DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
'@
        # Find the running menu by OWNER, not window title - other consoles
        # sitting in a folder named CLInt carry the identical title (see
        # Launch.ps1). The menu is the powershell running CLInt.ps1.
        $hwnd = [IntPtr]::Zero
        try {
            foreach ($p in Get-CimInstance Win32_Process -Filter "Name='powershell.exe'") {
                if ($p.ProcessId -ne $PID -and $p.CommandLine -like '*CLInt.ps1*') {
                    $wnd = (Get-Process -Id $p.ProcessId -ErrorAction SilentlyContinue).MainWindowHandle
                    if ([int64]$wnd -ne 0) { $hwnd = $wnd; break }
                }
            }
        } catch {}
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

$Host.UI.RawUI.WindowTitle = 'CLInt'   # matched by claude-gamepad.ahk, and the second half of the hotkey's window check (see clint.hwnd below)

# ------------------------------------------------------ Folder layout ---
# The app's code lives in app\, per-machine data in data\, and the root
# keeps only what a person runs (Install.bat, Uninstall.bat, Launch.ps1).
# A flat copy (the .claude\tests harness copies CLInt.ps1 on its own) has
# no app\ parent, so there the root is wherever this script sits.
$script:rootDir = if ((Split-Path $PSScriptRoot -Leaf) -eq 'app') { Split-Path $PSScriptRoot -Parent } else { $PSScriptRoot }
$script:dataDir = Join-Path $script:rootDir 'data'
if (-not (Test-Path $script:dataDir)) { New-Item -ItemType Directory -Force $script:dataDir | Out-Null }

# Announce our own console window, so the hotkey (CLIntKey.ahk) and the
# desktop shortcut (Launch.ps1) can find the menu with one existence check
# instead of scanning every process's command line. Both verify the title
# as well as the handle, so a stale file left by a crash resolves to
# nothing rather than to some unrelated window Windows has since recycled
# the handle for.
try {
    Set-Content (Join-Path $script:dataDir 'clint.hwnd') `
        ([int64](Get-Process -Id $PID).MainWindowHandle) -Encoding Ascii
} catch {}   # read-only data folder must never stop the menu from starting

# One-time migration from older layouts. Only acts when leftovers exist:
# moves pre-v0.2.10 root data files into data\, sweeps stale root script
# copies (a ZIP overlay only adds files; git pull removes its own), and
# carries a pre-v0.2.18 Startup shortcut for the hotkey over to the
# registry Run entry that replaced it.
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
        # Resolve Startup the long way round: GetFolderPath returns an EMPTY
        # string whenever that shell folder points somewhere that no longer
        # exists, and the resulting Join-Path failure is what used to break
        # both this migration and the installer's hotkey setup.
        $startup = [Environment]::GetFolderPath('Startup')
        if (-not $startup) { $startup = Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\Startup' }
        $lnkPath = Join-Path $startup 'CLIntKey.lnk'
        if (Test-Path $lnkPath) {
            $ahkExe = (New-Object -ComObject WScript.Shell).CreateShortcut($lnkPath).TargetPath
            $ahkArg = "`"$(Join-Path $PSScriptRoot 'CLIntKey.ahk')`""
            if (Test-Path $ahkExe) {
                Set-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run' `
                    -Name 'CLIntKey' -Value "`"$ahkExe`" $ahkArg"
            }
            Remove-Item $lnkPath -Force
            # Swap any instance running from the old path so two handlers
            # never race for the same key (#SingleInstance only replaces a
            # copy of the SAME script file).
            $running = @(Get-CimInstance Win32_Process |
                Where-Object { $_.Name -like 'AutoHotkey*' -and $_.CommandLine -match 'CLIntKey\.ahk' })
            foreach ($p in $running | Where-Object { $_.CommandLine -notmatch [regex]::Escape($PSScriptRoot) }) {
                try { Stop-Process -Id $p.ProcessId -Force -Confirm:$false } catch {}
            }
            if ($running.Count -and (Test-Path $ahkExe)) { Start-Process $ahkExe -ArgumentList $ahkArg }
        }
        foreach ($f in @('Install.ps1', 'Uninstall.ps1', 'Update.ps1', 'CLIntKey.ahk', 'CLInt.ico')) {
            Remove-Item (Join-Path $script:rootDir $f) -Force -ErrorAction SilentlyContinue
        }
    }
} catch {}   # a locked leftover must never stop the menu from starting

# App version: version.txt ships with the code and is bumped on every
# update, so the in-app corner display and the updater can compare.
$appVersion = try { (Get-Content (Join-Path $script:rootDir 'version.txt') -TotalCount 1).Trim() } catch { '?' }

# Global menu key (SETTINGS -> Menu key). Shared with Install.ps1 and
# Uninstall.ps1 so all three talk to CLIntKey.ahk the same way. A flat copy
# of CLInt.ps1 has no app\ folder to load it from - the menu still runs, the
# one row that needs it says so.
$script:hotkeyReady = $false
try {
    $hk = Join-Path $PSScriptRoot 'Hotkey.ps1'
    if (Test-Path $hk) { . $hk; $script:hotkeyReady = $true }
} catch {}

# The hotkey script now watches its own file and reloads itself when an
# update swaps it (see CLIntKey.ahk) - but the copy running on a machine
# that has just updated is, by definition, from before that existed. So
# the first CLInt start after an update still cycles a running script by
# hand, once. The v1.2.5 version of this went through a liveness
# handshake and swallowed every failure, then stamped over the evidence -
# which on at least one machine left the old script holding the key with
# nothing anywhere saying why. Hence the two rules here: any AutoHotkey
# presence at all is reason to cycle (Stop has its own cheap exits when
# every copy belongs to someone else), and a failed cycle is SAID (the
# notice) and NOT stamped, so the next start tries again instead of
# pretending it worked.
$script:hotkeyUpdateNotice = $null
try {
    $hkStamp = Join-Path $script:dataDir 'hotkey-version.txt'
    $stamped = ''
    try { $stamped = ([string](Get-Content $hkStamp -TotalCount 1 -ErrorAction SilentlyContinue)).Trim() } catch {}
    if ($script:hotkeyReady -and $appVersion -ne '?' -and $stamped -ne $appVersion) {
        $cycled = $true
        # Evidence gate: the key file or the status handshake existing is
        # what says CLInt's hotkey was ever set up here. Without it, the
        # AutoHotkey seen running is someone else's (a keyboard remapper,
        # whatever) and there is nothing of ours to cycle - or to nag
        # about failing to.
        $ours = (Get-MenuKeyName $script:rootDir) -or (Test-Path (Get-HotkeyPaths $script:rootDir).Status)
        if ($ours -and (Test-AnyAhkProcess)) {
            if (Stop-HotkeyScript $script:rootDir) {
                if ((Get-MenuKeyName $script:rootDir) -ne 'off') {
                    $err = Start-HotkeyScript $script:rootDir
                    if ($err) {
                        $cycled = $false
                        $script:hotkeyUpdateNotice = "The menu key script did not restart after the update. $err"
                    }
                }
            } else {
                $cycled = $false
                $script:hotkeyUpdateNotice = 'An older menu key script is still running and CLInt could not replace it. Sign out and back in to finish the update.'
            }
        }
        if ($cycled) { Set-Content $hkStamp $appVersion -Encoding Ascii }
    }
} catch {}

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

# Every library root Steam knows about - the install itself plus whatever
# libraryfolders.vdf lists. Falls back to the install when that file is
# missing or lists nothing, so a library is never scanned as empty.
function Get-SteamLibraryPaths {
    $steam = Get-SteamPath
    $vdfPath = Join-Path $steam 'steamapps\libraryfolders.vdf'
    if (Test-Path $vdfPath) {
        $vdf = Get-Content $vdfPath -Raw
        $libs = @([regex]::Matches($vdf, '"path"\s+"([^"]+)"') |
            ForEach-Object { $_.Groups[1].Value -replace '\\\\', '\' } |
            Select-Object -Unique)
        if ($libs.Count -gt 0) { return $libs }
    }
    return @($steam)
}

# Where Steam records that an app is installed. Watching this file vanish
# is how the uninstall menu knows the user went through with it.
function Get-AppManifestPath([string]$appid) {
    try {
        foreach ($lib in (Get-SteamLibraryPaths)) {
            $p = Join-Path $lib "steamapps\appmanifest_$appid.acf"
            if (Test-Path $p) { return $p }
        }
    } catch {}
    return $null
}

function Get-InstalledGames {
    $games = foreach ($lib in (Get-SteamLibraryPaths)) {
        foreach ($m in (Get-ChildItem (Join-Path $lib 'steamapps\appmanifest_*.acf') -ErrorAction SilentlyContinue)) {
            $c = Get-Content $m.FullName -Raw
            $name  = [regex]::Match($c, '"name"\s+"([^"]+)"').Groups[1].Value
            $appid = [regex]::Match($c, '"appid"\s+"(\d+)"').Groups[1].Value
            $installdir = [regex]::Match($c, '"installdir"\s+"([^"]+)"').Groups[1].Value
            if ($name -and $appid -and $name -notmatch 'Redistributables|Steamworks Common') {
                $dir = if ($installdir) { Join-Path $lib "steamapps\common\$installdir" } else { $null }
                # Steam = a real store app, so it has playtime on record.
                # Non-Steam shortcuts below are marked $false: Steam counts
                # no time for those, and CLInt no longer counts its own.
                [pscustomobject]@{ Name = $name; AppId = $appid; LaunchId = $appid; Exe = $null; Dir = $dir; Steam = $true }
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
            Steam    = $false
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

# Steam's own playtime, from the live account's localconfig.vdf. Each app
# is a "<appid>" block under "apps" holding two counters, both in minutes:
# "Playtime" is what the server knows about, "PlaytimeDisconnected" is time
# played offline that hasn't synced yet. Steam totals the pair, so we do too
# - otherwise an offline session looks like it never happened.
#
# Read in one regex pass: an appid is a numeric key followed by a brace, and
# every Playtime line after it belongs to that app until the next one starts.
# The counters only ever appear inside this section, so there is no need to
# find the section first.
#
# Steam flushes this file periodically rather than on every exit, so a
# just-finished session can take a moment to land. The cache is dropped
# after each game to pick up the new figure as soon as it is written.
$script:steamPlaytime = $null
function Get-SteamPlaytime {
    if ($null -ne $script:steamPlaytime) { return $script:steamPlaytime }
    $map = @{}
    try {
        $dir = Get-SteamUserDir
        if ($dir) {
            $lc = Join-Path $dir 'config\localconfig.vdf'
            if (Test-Path $lc) {
                # ReadAllText, not Get-Content -Raw: this file runs to a few
                # hundred KB and the cmdlet's overhead on it is visible in the
                # first paint.
                $raw = [System.IO.File]::ReadAllText($lc)
                $cur = $null
                foreach ($m in [regex]::Matches($raw,
                        '"(\d+)"\s*\r?\n\s*\{|"(?:Playtime|PlaytimeDisconnected)"\s+"(\d+)"')) {
                    if ($m.Groups[1].Success) { $cur = $m.Groups[1].Value }
                    elseif ($cur)             { $map[$cur] = [int]$map[$cur] + [int]$m.Groups[2].Value }
                }
            }
        }
    } catch {}
    $script:steamPlaytime = $map
    return $map
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
#
# ...but only when the target IS an exe. A .lnk in that folder can point at
# anything Explorer can open - a folder, a document, a .bat - and those get
# no process of their own to watch: a folder opens in the always-running
# explorer.exe, a PDF inside whatever reader is already up. Watching for a
# process named after the target then never succeeded, so the menu sat on
# LAUNCHING for the whole 90s start timeout, ignoring input, before finally
# giving up (v1.1.3 bug). Those are marked Track = 'Window' here and followed
# by the window they open instead - see Wait-ForOpenedWindow.
function Test-TrackableExe([string]$path) {
    if (-not $path) { return $false }
    try {
        if (Test-Path -LiteralPath $path -PathType Container) { return $false }
        return ([System.IO.Path]::GetExtension($path) -in '.exe', '.com')
    } catch { return $false }
}

function Get-ShortcutGames([string]$dir) {
    $wsh = New-Object -ComObject WScript.Shell
    @(Get-ChildItem (Join-Path $dir '*.lnk') -ErrorAction SilentlyContinue |
        Sort-Object BaseName | ForEach-Object {
            $target = $wsh.CreateShortcut($_.FullName).TargetPath
            [pscustomobject]@{
                Name  = $_.BaseName
                AppId = "local:$($_.BaseName)"   # key for the per-game TDP store
                Path  = $_.FullName
                Exe   = $target
                Track = $(if (Test-TrackableExe $target) { 'Exe' } else { 'Window' })
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
[DllImport("kernel32.dll", SetLastError = true)]
public static extern bool GetConsoleDisplayMode(out uint flags);
[DllImport("kernel32.dll")] public static extern IntPtr GetConsoleWindow();
[DllImport("user32.dll")] public static extern int GetWindowLong(IntPtr h, int idx);
[DllImport("user32.dll")] public static extern bool ShowScrollBar(IntPtr h, int bar, bool show);
[DllImport("user32.dll")] public static extern bool RedrawWindow(IntPtr h, IntPtr rect, IntPtr rgn, uint flags);
'@
} catch {}

# Conhost adds scrollbars during transient buffer/window mismatches (e.g.
# the default 120-wide buffer meeting a narrower fullscreen window at
# startup) and does NOT reliably remove them once the sizes agree again -
# the bar just lingers, dead, sometimes with the window style bits already
# cleared (so gating on GetWindowLong misses it). Hide unconditionally:
# ShowScrollBar(off) is cheap and a no-op when no bar exists.
#
# Removing a bar is not enough, though: nothing repaints the strip of
# pixels it covered, and on the fullscreen surface nothing else ever
# invalidates that strip - the IMAGE of the bar lingers as a ghost that
# no scrollbar API can touch, because there is no scrollbar any more
# (seen live: style bits clear, buffer pinned, bar still on screen; a
# forced window repaint was what finally erased it). So repaint after
# actually removing a bar, and -Repaint forces one at the transitions
# where a ghost can be born with the style bits already cleared.
function Hide-Scrollbars([switch]$Repaint) {
    try {
        $h = [CLI.Native]::GetConsoleWindow()
        $had = [CLI.Native]::GetWindowLong($h, -16) -band 0x00300000    # WS_HSCROLL | WS_VSCROLL
        [CLI.Native]::ShowScrollBar($h, 3, $false) | Out-Null   # SB_BOTH
        if ($Repaint -or $had -ne 0) {
            # RDW_INVALIDATE | RDW_ERASE | RDW_FRAME - conhost repaints the
            # whole surface from its own buffer, ghost strips included.
            [CLI.Native]::RedrawWindow($h, [IntPtr]::Zero, [IntPtr]::Zero, 0x405) | Out-Null
        }
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
        # The transition settles asynchronously, and a fixed sleep sometimes
        # measured the window mid-transition - the grid below was then fitted
        # against a size the window shrank away from, leaving a horizontal
        # scrollbar over the freshly drawn menu (seen live 2026-08-03: the
        # first frame went up against the pre-settle width, with the default
        # font's metrics). Wait until the measurements stop moving instead:
        # 4 stable 50ms samples, 2s cap - a settled window costs the same
        # 200ms the old sleep did.
        $lastMax = ''
        $stable  = 0
        for ($i = 0; $i -lt 40 -and $stable -lt 4; $i++) {
            Start-Sleep -Milliseconds 50
            $max = '{0}x{1}' -f [Console]::LargestWindowWidth, [Console]::LargestWindowHeight
            if ($max -eq $lastMax) { $stable++ } else { $stable = 0; $lastMax = $max }
        }

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
        Hide-Scrollbars -Repaint
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
        Hide-Scrollbars -Repaint
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
[StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left; public int Top; public int Right; public int Bottom; }
[DllImport("kernel32.dll")] public static extern IntPtr GetConsoleWindow();
[DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
[DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
[DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int cmd);
[DllImport("user32.dll")] public static extern bool IsIconic(IntPtr h);
[DllImport("user32.dll")] public static extern bool IsWindow(IntPtr h);
[DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
[DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr h, IntPtr after, int x, int y, int cx, int cy, uint flags);
[DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
[DllImport("user32.dll")] public static extern IntPtr MonitorFromWindow(IntPtr h, uint flags);
'@
    $script:conHwnd = [CLIntFocus.Win]::GetConsoleWindow()
    # Hosts other than conhost (Windows Terminal above all) hand back a
    # hidden pseudo-console window here, which is no use for ordering or
    # focus. The process's own main window is the one on screen - it is
    # what clint.hwnd records for the hotkey already.
    if ($script:conHwnd -eq [IntPtr]::Zero) {
        try { $script:conHwnd = (Get-Process -Id $PID).MainWindowHandle } catch {}
    }
} catch {}

# Is the console genuinely off-screen? Losing the foreground is NOT
# enough: Steam's small "preparing to launch" dialog takes the foreground
# while the fullscreen console is still visible behind it (painting then
# flashed WELCOME BACK over the LAUNCHING screen mid-launch, v0.2.14 bug).
# Off-screen = minimised, or the foreground window's rect fully covers
# ours. Comparing two rects from the same DPI-virtualised space is a pure
# read - no pixel placement math; 8px slack absorbs borderless quirks.
function Test-MenuCovered {
    if ($script:conHwnd -eq [IntPtr]::Zero) { return $false }
    try {
        if ([CLIntFocus.Win]::IsIconic($script:conHwnd)) { return $true }
        $fg = [CLIntFocus.Win]::GetForegroundWindow()
        if ($fg -eq $script:conHwnd -or $fg -eq [IntPtr]::Zero) { return $false }
        $rf = New-Object CLIntFocus.Win+RECT
        $rc = New-Object CLIntFocus.Win+RECT
        if (-not [CLIntFocus.Win]::GetWindowRect($fg, [ref]$rf))              { return $false }
        if (-not [CLIntFocus.Win]::GetWindowRect($script:conHwnd, [ref]$rc)) { return $false }
        return ($rf.Left -le $rc.Left + 8 -and $rf.Top    -le $rc.Top    + 8 -and
                $rf.Right + 8 -ge $rc.Right -and $rf.Bottom + 8 -ge $rc.Bottom)
    } catch { return $false }
}

# A just-launched game can be denied activation by Windows' focus-steal
# protection and sit invisible BEHIND the fullscreen menu (seen when Steam
# is cold-started silently in the tray). We hold the foreground, so step
# aside: minimise ourselves and Windows activates the game window on top.
#
# Returns whether it actually stepped aside, and the callers stop asking
# once it has. Stepping aside is a one-shot courtesy, not a policy: after
# the first minimise, a console holding the foreground again means the
# USER put it there (the menu key, the taskbar), and re-minimising it made
# the menu look impossible to bring back for as long as the game dawdled
# over claiming a window - restore, half a second, gone again. The latch
# in Wait-ForGameExit can't cover this on its own: after we minimise, the
# foreground is allowed to sit on nothing at all (a game still loading has
# no window to give it to), and a null foreground sets no latch.
function Hide-MenuForGame {
    if ($script:conHwnd -eq [IntPtr]::Zero) { return $false }
    try {
        if ([CLIntFocus.Win]::GetForegroundWindow() -eq $script:conHwnd) {
            [CLIntFocus.Win]::ShowWindow($script:conHwnd, 6) | Out-Null   # SW_MINIMIZE
            return $true
        }
    } catch {}
    return $false
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
    # AppActivate by OWN PID, never by title - other consoles can share it.
    try { (New-Object -ComObject WScript.Shell).AppActivate($PID) | Out-Null } catch {}
    # A restore can land the window at the minimize PARKING coordinates
    # (-21333,-21333 on this box), "restored" yet off every monitor - see
    # Repair-MenuWindow for how conhost gets there. Re-entering fullscreen
    # mode both repositions the window and repairs the placement it saved.
    try {
        if (-not [CLIntFocus.Win]::IsIconic($script:conHwnd) -and
            [CLIntFocus.Win]::MonitorFromWindow($script:conHwnd, 0) -eq [IntPtr]::Zero) {   # MONITOR_DEFAULTTONULL
            Set-ConsoleFullscreen
        }
    } catch {}
    # Coming back from a game or video is a display transition too - a
    # resolution change while the console was covered can strand a ghost
    # scrollbar strip. Come back to a freshly painted surface.
    Hide-Scrollbars -Repaint
}

# Minimizing the console while conhost's fullscreen display mode is on
# poisons its restore state (measured live, v1.2.11): the first taskbar
# click is EATEN - conhost drops out of fullscreen mode but stays
# minimized (the icon just flickers) - and the next restore, from any
# path, parks the window at the minimize coordinates and then saves
# those as its normal placement, so it is alive, "restored", and
# invisible forever. The hotkey never hit this because SW_RESTORE while
# the mode is still fullscreen makes conhost reassert the fullscreen
# rect; only the taskbar's SC_RESTORE corrupts. Called from the idle
# tick in Read-InputKey, so both poison stages self-heal within ~300ms:
# a minimized-in-fullscreen menu whose mode flips off while still
# minimized can only mean a taskbar click was eaten - finish the
# restore it asked for. A minimized window reports the monitor of its
# restore position, so the off-screen check can't misfire on a normal
# minimize.
$script:fsWhileIconic = $false
function Repair-MenuWindow {
    if ($script:conHwnd -eq [IntPtr]::Zero) { return }
    try {
        if ([CLIntFocus.Win]::IsIconic($script:conHwnd)) {
            $mode = [uint32]0
            [CLI.Native]::GetConsoleDisplayMode([ref]$mode) | Out-Null
            if ($mode -band 1) { $script:fsWhileIconic = $true }
            elseif ($script:fsWhileIconic) {
                $script:fsWhileIconic = $false
                Show-MenuWindow        # restore + focus; its off-screen check
                Set-ConsoleFullscreen  # may have run, but this pins the mode
            }
        } else {
            $script:fsWhileIconic = $false
            if ([CLIntFocus.Win]::MonitorFromWindow($script:conHwnd, 0) -eq [IntPtr]::Zero) {
                Set-ConsoleFullscreen
                Show-MenuWindow
            }
        }
    } catch {}
}

# The scrollbar defences live in Read-InputKey's 300ms idle tick, which never
# runs while the script is blocked waiting on another window or process - and
# that is exactly when the user is LOOKING at the other window, with the menu
# exposed behind or beside it. A bar born there (a fullscreen transition that
# settled late, a game changing the display mode) used to sit on screen for
# the whole wait, because nothing was left running to remove it (seen live
# 2026-08-03: menu launched a shortcut seconds after startup and the startup
# bar stayed up for the entire Wait-ForOpenedWindow). One cheap guard for the
# wait loops: pin buffer == window, then Hide-Scrollbars - which repaints
# only when it really removed a bar, so a quiet tick costs two API reads.
function Protect-CoveredMenu {
    try {
        $cw = [Console]::WindowWidth
        $ch = [Console]::WindowHeight
        if ([Console]::BufferWidth -ne $cw -or [Console]::BufferHeight -ne $ch) {
            $Host.UI.RawUI.BufferSize = New-Object System.Management.Automation.Host.Size($cw, $ch)
        }
    } catch {}
    Hide-Scrollbars
}

# Pin the menu above everything else, or let it back down again.
#
# Handing the Steam client a command means running steam.exe, and that
# raises its window - the URL protocol is the only way to talk to a running
# Steam without doing so, and it has nothing for uninstalling. Steam still
# comes up, but behind a topmost menu, so the user never sees it: no flash
# of the store, no wondering what just happened. NOACTIVATE, so this alone
# never moves the focus around.
function Set-MenuTopmost([bool]$on) {
    if ($script:conHwnd -eq [IntPtr]::Zero) { return }
    try {
        $after = if ($on) { [IntPtr](-1) } else { [IntPtr](-2) }   # HWND_TOPMOST / HWND_NOTOPMOST
        # SWP_NOSIZE | SWP_NOMOVE | SWP_NOACTIVATE
        [CLIntFocus.Win]::SetWindowPos($script:conHwnd, $after, 0, 0, 0, 0, 0x0013) | Out-Null
    } catch {}
}

# Steam's on-screen window belongs to steamwebhelper, not steam.exe, and
# only one of the several helper processes owns it - which is why looking
# for it on the 'steam' process finds nothing. Recorded before we hand the
# client a command so that a Steam the user already had open is left alone;
# only a window that appears because of us gets put away again.
function Get-SteamWindows {
    $set = @{}
    try {
        foreach ($p in (Get-Process -Name 'steamwebhelper', 'steam' -ErrorAction SilentlyContinue)) {
            try {
                $p.Refresh()
                $w = $p.MainWindowHandle
                if ($w -ne [IntPtr]::Zero -and [CLIntFocus.Win]::IsWindowVisible($w)) { $set[[int64]$w] = $true }
            } catch {}
        }
    } catch {}
    return $set
}
# Put back exactly what was not there before. Hiding is what Steam itself
# does when closed to the tray, so a client that was in the tray goes back
# to the tray rather than being left minimised on the taskbar. Every window
# put away is remembered, because one of them may turn out to be a question
# for the user rather than a window Steam merely felt like showing.
$script:steamHidden = @{}
function Hide-NewSteamWindows($before) {
    try {
        foreach ($w in (Get-SteamWindows).Keys) {
            if (-not $before[$w]) {
                try {
                    [CLIntFocus.Win]::ShowWindow([IntPtr]$w, 0) | Out-Null   # SW_HIDE
                    $script:steamHidden[$w] = $true
                } catch {}
            }
        }
    } catch {}
}
# Hand back everything we hid. Used the moment it turns out this client
# wants an answer after all: its dialog must not be sitting hidden because
# we tidied it away a second earlier.
function Restore-HiddenSteamWindows {
    foreach ($w in @($script:steamHidden.Keys)) {
        try { [CLIntFocus.Win]::ShowWindow([IntPtr]$w, 5) | Out-Null } catch {}   # SW_SHOW
    }
    $script:steamHidden = @{}
}

# Get out of the way of a window that is about to open behind us. Steam's
# uninstall prompt is the case that needs it: a maximised menu would hide
# the very dialog the user has to answer.
function Hide-MenuWindow {
    if ($script:conHwnd -ne [IntPtr]::Zero) {
        try { [CLIntFocus.Win]::ShowWindow($script:conHwnd, 6) | Out-Null } catch {}   # SW_MINIMIZE
    }
}

# The WELCOME BACK landing screen. Painted by Wait-ForGameExit WHILE the
# game still runs (the console sits hidden behind it showing the stale
# LAUNCHING screen, and the instant the game window closes Windows exposes
# whatever is painted): pre-painting means no exit-detection latency can
# flash the launch screen at the user. Also called after the wait returns
# for the rare run where the game never took the screen at all.
function Draw-LandingScreen($g, [DateTime]$t0) {
    $mins = [int][Math]::Floor(([DateTime]::Now - $t0).TotalMinutes)
    $dur  = if (-not $script:sessionTimeOn) { '' }
            elseif ($mins -ge 60) { "played for $([Math]::Floor($mins / 60))h $($mins % 60)m" }
            elseif ($mins -ge 1)  { "played for $mins min" }
            else                  { '' }
    Clear-Host
    Write-Host ""
    Write-Host "      _" -ForegroundColor $theme.Accent
    Write-Host "     /^\      WELCOME BACK" -ForegroundColor $theme.Accent
    Write-Host "    |___|" -ForegroundColor $theme.Accent
    Write-Host "    |   |     $($g.Name)" -ForegroundColor $theme.Logo
    Write-Host "    |___|     $dur" -ForegroundColor $theme.Accent
    Write-Host "   /|   |\    GG o7" -ForegroundColor $theme.Info
    Write-Host "__/_|___|_\__" -ForegroundColor $theme.Info
    Write-Host ""
}

# VLC's flavour of the same idea, for the same reason. A video the user
# bailed out of never got a wrap, so say so - the caller decides which,
# and the pre-paint can only assume the whole thing was watched.
function Draw-WrapScreen([string]$name, [bool]$done = $true) {
    $head = if ($done) { "THAT'S A WRAP" } else { 'TO BE CONTINUED...' }
    Clear-Host
    Write-Host ""
    Write-Host "     _____" -ForegroundColor $theme.Accent
    Write-Host "    | |[] |    $head" -ForegroundColor $theme.Accent
    Write-Host "    |_|___|    $name" -ForegroundColor $theme.Logo
    Write-Host ""
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
$script:mouseRightWas = $false  # same for the right button, which opens the item menu
$script:wheelY = -1             # pointer row at the last wheel notch
$script:wheelSteps = 1          # notches collapsed into that one event
# Pointer cell last seen, and whether hover is currently muted. conhost
# reports a MOUSE_MOVED record for pointer movement far finer than one
# cell, so a pointer merely resting on the list keeps re-announcing the
# row it is already on - which yanked the cursor back every time the pad
# or the arrow keys moved it. Any non-mouse input mutes hover; it comes
# back the moment the pointer genuinely changes cell.
$script:mouseCellX = -1; $script:mouseCellY = -1
$script:hoverMuted = $false
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
# Selected in SETTINGS, stored as "Theme" in settings.json. Bg is the
# console's own background - nothing else in the app passes one, so it is
# what Clear-Host fills with and what every unpainted cell shows.
#
# A theme may also carry a Palette: <console colour name> -> 0xRRGGBB, which
# repaints those entries of THIS console's 16-colour table while the theme is
# active (see Set-ConsolePalette). The 16 names are all the console can draw,
# and the two that these themes want as a full-screen background are wrong at
# that size whatever scheme the window came with: DarkBlue is #000080 on the
# legacy palette and #0037DA on Campbell (today's conhost default) - navy or
# electric, both too much across a whole screen - and White is #F2F2F2/#FFFFFF,
# a torch in a dark room. Softening happens in the palette rather than by
# picking another name, because there IS no softer name. Bonus: pinning the
# RGB means these two themes look the same on every machine instead of
# inheriting whatever scheme that console was configured with.
$themes = [ordered]@{
    classic    = @{ Bg = 'Black';    Accent = 'Cyan';     Logo = 'Magenta';     Info = 'DarkCyan';    Hint = 'DarkGray'; Text = 'Gray';  Bright = 'White';    Notice = 'Yellow';  Scroll = 'DarkMagenta'; SelFg = 'Black' }
    vapor      = @{ Bg = 'Black';    Accent = 'Magenta';  Logo = 'Cyan';        Info = 'DarkMagenta'; Hint = 'DarkGray'; Text = 'Gray';  Bright = 'White';    Notice = 'Yellow';  Scroll = 'DarkCyan';    SelFg = 'Black' }
    matrix     = @{ Bg = 'Black';    Accent = 'Green';    Logo = 'DarkGreen';   Info = 'DarkGreen';   Hint = 'DarkGray'; Text = 'Gray';  Bright = 'Green';    Notice = 'Yellow';  Scroll = 'DarkGreen';   SelFg = 'Black' }
    amber      = @{ Bg = 'Black';    Accent = 'Yellow';   Logo = 'DarkYellow';  Info = 'DarkYellow';  Hint = 'DarkGray'; Text = 'Gray';  Bright = 'Yellow';   Notice = 'Red';     Scroll = 'DarkYellow';  SelFg = 'Black' }
    arctic     = @{ Bg = 'Black';    Accent = 'White';    Logo = 'Cyan';        Info = 'DarkCyan';    Hint = 'DarkGray'; Text = 'Gray';  Bright = 'White';    Notice = 'Yellow';  Scroll = 'DarkCyan';    SelFg = 'Black' }
    powershell = @{ Bg = 'DarkBlue'; Accent = 'Yellow';   Logo = 'White';       Info = 'Cyan';        Hint = 'DarkGray'; Text = 'Gray';  Bright = 'White';    Notice = 'Yellow';  Scroll = 'DarkCyan';    SelFg = 'DarkBlue'
                    # A muted slate navy in place of the electric stock blue -
                    # still unmistakably the PowerShell blue, minus the glare.
                    # DarkBlue is also this theme's SelFg, so the text on the
                    # yellow selection bar softens with it. Cyan/DarkCyan come
                    # down to match (stock cyan on navy vibrates), the yellow
                    # goes to a warm gold, and DarkGray lifts to a cool grey -
                    # stock #767676 on navy is too dim to read the hint row.
                    Palette = @{ DarkBlue = 0x1E3350; Cyan = 0x7FC8D8; DarkCyan = 0x4E8C99; Yellow = 0xF2C55C; DarkGray = 0x8C97A8 } }
    paper      = @{ Bg = 'White';    Accent = 'DarkBlue'; Logo = 'DarkMagenta'; Info = 'DarkCyan';    Hint = 'DarkGray'; Text = 'Black'; Bright = 'DarkBlue'; Notice = 'DarkRed'; Scroll = 'DarkMagenta'; SelFg = 'White'
                    # Warm off-white instead of stock white, and ink rather
                    # than pure black on top of it - paper, not a lightbulb.
                    # White is also SelFg here, so the text on the blue
                    # selection bar picks up the same off-white. The rest are
                    # pulled down to printed-ink weight: stock DarkCyan and
                    # DarkMagenta are bright screen colours that wash out on a
                    # light page, and stock DarkRed is a fire alarm.
                    Palette = @{ White = 0xF2EDE3; Black = 0x1F1D1A; DarkBlue = 0x2B4C7E; DarkGray = 0x6B6660
                                 DarkCyan = 0x2F7C8C; DarkMagenta = 0x7A3E86; DarkRed = 0xA83A32 } }
}
$themeName = if ($settings['Theme'] -and $themes.Contains([string]$settings['Theme'])) { [string]$settings['Theme'] } else { 'classic' }
$theme = $themes[$themeName]
# The console's colours as we found them, so quitting hands the window
# back unchanged - a theme with a background repaints the whole buffer.
# Black is enum 0, so these are compared against $null, never truthiness.
$origFg = $null; $origBg = $null
try { $origFg = $Host.UI.RawUI.ForegroundColor; $origBg = $Host.UI.RawUI.BackgroundColor } catch {}

# --- Console palette (v1.1.5) -------------------------------------------
# The RGB behind each of the 16 colour names, for THIS console window only,
# via CONSOLE_SCREEN_BUFFER_INFO_EX. A ConsoleColor's enum value IS its index
# in that table (both are the attribute bits: DarkBlue = FOREGROUND_BLUE = 1,
# DarkRed = FOREGROUND_RED = 4, ...), so no mapping table is needed.
#
# Two traps in this API, both handled below: COLORREF is 0x00BBGGRR, so the
# bytes are the reverse of the 0xRRGGBB literals the themes are written in;
# and SetConsoleScreenBufferInfoEx reads srWindow as an INCLUSIVE rect while
# Get hands one back EXCLUSIVE - passing it straight through shrinks the
# window by a row and a column every single call.
try {
    Add-Type -Namespace CLIntPal -Name Win -MemberDefinition @'
[StructLayout(LayoutKind.Sequential)] public struct COORD { public short X; public short Y; }
[StructLayout(LayoutKind.Sequential)] public struct SMALL_RECT { public short Left; public short Top; public short Right; public short Bottom; }
[StructLayout(LayoutKind.Sequential)] public struct BUFINFOEX {
    public uint cbSize; public COORD dwSize; public COORD dwCursorPosition; public ushort wAttributes;
    public SMALL_RECT srWindow; public COORD dwMaximumWindowSize; public ushort wPopupAttributes;
    public bool bFullscreenSupported;
    [MarshalAs(UnmanagedType.ByValArray, SizeConst = 16)] public uint[] ColorTable; }
[DllImport("kernel32.dll")] public static extern IntPtr GetStdHandle(int n);
[DllImport("kernel32.dll", SetLastError = true)] public static extern bool GetConsoleScreenBufferInfoEx(IntPtr h, ref BUFINFOEX i);
[DllImport("kernel32.dll", SetLastError = true)] public static extern bool SetConsoleScreenBufferInfoEx(IntPtr h, ref BUFINFOEX i);
'@
} catch {}

function Get-ConsolePalette {
    try {
        $info = New-Object CLIntPal.Win+BUFINFOEX
        $info.cbSize = [System.Runtime.InteropServices.Marshal]::SizeOf($info)
        $h = [CLIntPal.Win]::GetStdHandle(-11)
        if (-not [CLIntPal.Win]::GetConsoleScreenBufferInfoEx($h, [ref]$info)) { return $null }
        return $info.ColorTable.Clone()
    } catch { return $null }
}

# $table = the full 16-entry COLORREF array to install (as handed out by
# Get-ConsolePalette), or $null to do nothing.
function Set-ConsolePaletteTable($table) {
    if (-not $table) { return }
    try {
        $info = New-Object CLIntPal.Win+BUFINFOEX
        $info.cbSize = [System.Runtime.InteropServices.Marshal]::SizeOf($info)
        $h = [CLIntPal.Win]::GetStdHandle(-11)
        if (-not [CLIntPal.Win]::GetConsoleScreenBufferInfoEx($h, [ref]$info)) { return }
        $info.ColorTable = $table
        $r = $info.srWindow
        # NB [int16], NOT [short] - PowerShell has no [short] accelerator, and
        # the resulting "Unable to find type" lands in the catch below, so the
        # whole palette silently does nothing (cost an hour once).
        $r.Right = [int16]($r.Right + 1); $r.Bottom = [int16]($r.Bottom + 1)   # see the note above
        $info.srWindow = $r
        [CLIntPal.Win]::SetConsoleScreenBufferInfoEx($h, [ref]$info) | Out-Null
    } catch {}
}

# The palette as the window was handed to us, so quitting puts it back (a dev
# shell keeps its own look, same reasoning as $origFg/$origBg above).
$origPalette = Get-ConsolePalette

# Install the stock palette plus this theme's overrides. Always starts from
# $origPalette, so switching from paper to classic drops paper's off-white
# rather than leaving it behind for the next theme to inherit.
function Set-ConsolePalette($overrides) {
    if (-not $script:origPalette) { return }
    $table = $script:origPalette.Clone()
    if ($overrides) {
        foreach ($name in $overrides.Keys) {
            try {
                $i = [int][System.ConsoleColor]$name
                $rgb = [int]$overrides[$name]
                # 0xRRGGBB -> COLORREF 0x00BBGGRR
                $table[$i] = [uint32]((($rgb -band 0xFF) -shl 16) -bor ($rgb -band 0xFF00) -bor (($rgb -shr 16) -band 0xFF))
            } catch {}
        }
    }
    Set-ConsolePaletteTable $table
}

# Apply the current theme's console colours. Only takes effect on cells
# painted after it, so every caller follows it with a full redraw.
function Set-ThemeColors {
    # Palette first: it repaints cells already on screen with the new RGBs,
    # so doing it after the fg/bg set would flash the stock colour.
    Set-ConsolePalette $script:theme.Palette
    try {
        $Host.UI.RawUI.BackgroundColor = $script:theme.Bg
        $Host.UI.RawUI.ForegroundColor = $script:theme.Text
    } catch {}
}

# --- Handing the theme to the built-in player ---------------------------
# The player draws CLInt's look on a WinForms window, so it needs RGB where
# everything here uses colour NAMES. Resolve each one exactly the way the
# screen resolves it - this theme's palette override if it has one, else
# whatever this console's table actually holds - and the overlay comes out
# the colour the menu was a second earlier, on this machine, including the
# two themes that repaint their own background.
#
# Only reached if the console API is unavailable and the theme has no
# opinion: Campbell, conhost's default scheme since 2017.
$stockRgb = @{
    Black = 0x0C0C0C; DarkBlue = 0x0037DA; DarkGreen = 0x13A10E; DarkCyan = 0x3A96DD
    DarkRed = 0xC50F1F; DarkMagenta = 0x881798; DarkYellow = 0xC19C00; Gray = 0xCCCCCC
    DarkGray = 0x767676; Blue = 0x3B78FF; Green = 0x16C60C; Cyan = 0x61D6D6
    Red = 0xE74856; Magenta = 0xB4009E; Yellow = 0xF9F1A5; White = 0xF2F2F2
}
function Get-ColorRgb([string]$name) {
    if ($script:theme.Palette -and $script:theme.Palette.ContainsKey($name)) {
        return [int]$script:theme.Palette[$name]
    }
    if ($script:origPalette) {
        try {
            # COLORREF 0x00BBGGRR -> 0xRRGGBB, the reverse of Set-ConsolePalette
            $c = [int]$script:origPalette[[int][System.ConsoleColor]$name]
            return [int]((($c -band 0xFF) -shl 16) -bor ($c -band 0xFF00) -bor (($c -shr 16) -band 0xFF))
        } catch {}
    }
    if ($script:stockRgb.ContainsKey($name)) { return [int]$script:stockRgb[$name] }
    return 0xCCCCCC
}

# Role=RRGGBB pairs for Player.ps1's -Theme. No spaces, so it travels as a
# single argument without quoting.
function Get-ThemeRgbArg {
    $roles = @('Bg', 'Accent', 'Logo', 'Info', 'Hint', 'Text', 'Bright', 'Notice')
    return (($roles | ForEach-Object { '{0}={1:X6}' -f $_, (Get-ColorRgb $script:theme[$_]) }) -join ',')
}

# Text size (SETTINGS): font heights in scaled pixels, so the visual size
# follows the user's display scale like every other app. Medium is the
# 28px the app has always used.
$textSizes = [ordered]@{ small = 20; medium = 28; large = 34 }
$textSizeName = if ($settings['TextSize'] -and $textSizes.Contains([string]$settings['TextSize'])) { [string]$settings['TextSize'] } else { 'medium' }

# --- Button hints (SETTINGS) --------------------------------------------
# Which buttons the on-screen hint rows name. CLInt is built to be driven
# from the couch, so the gamepad set is the default - but every one of these
# rows is also the only place the keyboard equivalents are written down, and
# at a desk the controller names are noise. One setting covers every hint in
# the app, the built-in player's row included, which is why the choice
# travels to Player.ps1 on its command line.
#
# Only the button NAMES move between the two sets; the verb after them
# ("launch", "cancel") is the same either way. That keeps each hint one
# string with tokens in it rather than two strings that drift apart the
# first time someone edits one and forgets the other.
#
# The names are the real bindings, checked against the input handlers:
# Enter launches, Esc goes back, the arrows move AND switch tabs, and F5 is
# what the gamepad's RB arrives as.
$hintWords = @{
    gamepad  = @{ Move = 'D-pad: move';  Tab = '</>: switch tab'; A = 'A';     B = 'B'
                  RB   = 'RB';           EnterA = 'Enter/A';      EscB = 'Esc/B'; Y = 'Y' }
    keyboard = @{ Move = 'Arrows: move'; Tab = 'Left/Right: tab'; A = 'Enter'; B = 'Esc'
                  RB   = 'F5';           EnterA = 'Enter';        EscB = 'Esc';   Y = 'M' }
}
$controlHints = if ([string]$settings['ButtonHints'] -eq 'keyboard') { 'keyboard' } else { 'gamepad' }

function Hint([string]$s) {
    $w = $script:hintWords[$script:controlHints]
    foreach ($k in $w.Keys) { $s = $s.Replace('{' + $k + '}', $w[$k]) }
    return $s
}

# Behaviour toggles (all in SETTINGS). Clock/battery/recently-played
# default on; the launch-time update check is opt-in.
$showClock       = $settings['ShowClock']       -ne $false
$showBattery     = $settings['ShowBattery']     -ne $false
$recentEnabled   = $settings['Recent']          -ne $false
$playtimeEnabled = $settings['Playtime']        -ne $false
$sessionTimeOn   = $settings['SessionTime']     -ne $false
$autoCheck       = $settings['AutoUpdateCheck'] -eq $true
$mouseEnabled    = $settings['Mouse']           -ne $false
$hoverTabs       = $settings['HoverTabs']       -eq $true

# --- Launch at startup (SETTINGS toggle, off unless turned on) ----------
# An HKCU Run entry, not a Startup-folder shortcut, for the same reason
# the hotkey's logon entry is one (see Install.ps1): GetFolderPath can
# hand back '' for the Startup folder. The entry itself is the setting -
# nothing in settings.json - so the row always shows what Windows will
# actually do at sign-in, and a settings reset leaves it alone just like
# the hotkey's entry.
$autoStartRunKey  = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
$autoStartRunName = 'CLInt'
function Register-AutoStart {
    # Same invocation as the desktop shortcut: Launch.ps1 under a hidden
    # powershell, which starts conhost fullscreen and foregrounds it.
    $cmd = "`"$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe`" -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$(Join-Path $script:rootDir 'Launch.ps1')`""
    if (-not (Test-Path $script:autoStartRunKey)) { New-Item $script:autoStartRunKey -Force | Out-Null }
    Set-ItemProperty $script:autoStartRunKey -Name $script:autoStartRunName -Value $cmd
}
function Unregister-AutoStart {
    Remove-ItemProperty $script:autoStartRunKey -Name $script:autoStartRunName -Force -ErrorAction SilentlyContinue
}
$autoStart = $null -ne (Get-ItemProperty $autoStartRunKey -Name $autoStartRunName -ErrorAction SilentlyContinue)
# A moved CLInt folder would leave the entry aimed at the old path, so
# re-assert the current one while the toggle is on. Gated on Launch.ps1
# actually being there: the flat test-harness copy has none, and must
# never rewrite the real machine's entry to point at itself.
if ($autoStart -and (Test-Path (Join-Path $script:rootDir 'Launch.ps1'))) {
    try { Register-AutoStart } catch {}
}
$inModal = $false        # modals suppress the idle clock/battery repaint
$batteryPct = -1
$batteryNext = 0
$tdpNowW = -1            # live TDP watts (Motion Assistant machines only)
$statusLast = ''
$statusDrawnLen = 0      # width of the last corner draw, for clean blanking
$statusReserved = 0      # corner columns the tab bar left free at last full draw
$updateNoticeShown = $false

# Recently played: recent.json maps a game key (AppId / local:<name>) to
# the time it was last played, which is all the ordering needs. Playtime
# is Steam's to report - see Get-SteamPlaytime. Only touched while the
# feature is enabled.
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
function Record-Play($game) {
    $script:recentMap[[string]$game.AppId] = [pscustomobject]@{
        Last = [DateTime]::Now.ToString('s')
    }
    Save-RecentMap
}
# Video history (Files tabs): play counts tracked here per machine, and
# partially-watched positions read straight from VLC's own resume state,
# so the [>>] tag shows the real continue-from timestamp. CurrentlyWatching
# lifts those part-watched videos into a section of their own; it reads the
# same VLC state, so it stands on its own with video history switched off.
$videoHistEnabled = $settings['VideoHistory']     -ne $false
$watchingEnabled  = $settings['CurrentlyWatching'] -ne $false
# UP NEXT: the episode after the one a folder last saw finished. It is
# built from the play counts, so it follows VideoHistory's toggle as
# well as its own - no history, no way to know what was finished.
$upNextEnabled    = $settings['UpNext']            -ne $false
# The built-in player's bottom row of button hints. On by default - the
# player takes a controller and nothing else says what the buttons do -
# but once they are known they are just a row of text over the film, so
# turning them off shortens the overlay by exactly that row.
$playerHints      = $settings['PlayerHints']       -ne $false
# Whether the built-in player starts a file with subtitles showing. Off
# unless asked for - a file carrying a subtitle track is not a reason to
# put it on screen - and note the default is the opposite way round to the
# toggles above, so this one tests for $true rather than -ne $false.
$subtitlesOn      = $settings['Subtitles']         -eq $true
# Where a watch starts counting as complete, as a percentage of the file.
# Nobody sits through the credits: TV credits start around 96-98% of an
# episode, films and anime EDs nearer 92-95%, so 95 catches "stopped when
# the credits rolled" without swallowing a real early bail. 100 keeps the
# strict only-the-very-end rule. Honoured by the built-in player, which
# knows the file's length; the other paths have no duration to compare.
$watchedPctOpts = @(90, 95, 98, 100)
$watchedPct = 95
try {
    if ($watchedPctOpts -contains [int]$settings['WatchedPercent']) {
        $watchedPct = [int]$settings['WatchedPercent']
    }
} catch {}
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
# Set a count outright, for the item menu. Zero drops the entry rather than
# storing a 0: an absent key and "watched no times" are the same thing, and
# keeping the row would leave the file growing with nothing in it. The
# original Last is preserved - correcting a count is not watching it again.
function Set-VideoPlays([string]$path, [int]$n) {
    $k = $path.ToLower()
    if ($n -le 0) {
        $script:watchMap.Remove($k)
    } else {
        $last = ''
        if ($script:watchMap[$k]) { try { $last = [string]$script:watchMap[$k].Last } catch {} }
        if (-not $last) { $last = [DateTime]::Now.ToString('s') }
        $script:watchMap[$k] = [pscustomobject]@{ Plays = $n; Last = $last }
    }
    Save-WatchMap
}
# VLC stores resume positions in [RecentsMRL] of vlc-qt-interface.ini:
# parallel 'list=' (file:/// URIs) and 'times=' (milliseconds; 0 = none).
# Returned in VLC's own order, which is most-recently-opened first, with
# the paths exactly as VLC wrote them - CURRENTLY WATCHING needs both.
function Get-VlcResumeEntries {
    $out = @()
    try {
        $ini = Join-Path $env:APPDATA 'vlc\vlc-qt-interface.ini'
        if (-not (Test-Path $ini)) { return $out }
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
                    $out += [pscustomobject]@{ Path = $p; Seconds = [int]($ms / 1000) }
                }
            }
        }
    } catch {}
    return @($out)
}
# Lookup flavour of the same data, keyed by lower-cased path.
function Get-VlcResumeSeconds {
    $map = @{}
    foreach ($e in (Get-VlcResumeEntries)) { $map[$e.Path.ToLower()] = $e.Seconds }
    return $map
}

# The built-in player has no vlc-qt-interface.ini to write into, so it
# reports where it stopped and CLInt keeps that here - the same shape of
# data VLC keeps, under our own roof. A Seconds of 0 is not an absence: it
# is a tombstone saying "watched to the end", and it exists to shadow the
# stale row VLC may still be holding for a file the built-in player has
# since finished. Without it, a video would climb back into CURRENTLY
# WATCHING on the strength of a position nothing has used for weeks.
$resumeFile = Join-Path $script:dataDir 'resume.json'
$resumeMap = @{}
if (Test-Path $resumeFile) {
    try {
        (Get-Content $resumeFile -Raw | ConvertFrom-Json).PSObject.Properties |
            ForEach-Object { $resumeMap[$_.Name] = $_.Value }
    } catch {}
}
function Save-ResumeMap {
    try { [pscustomobject]$script:resumeMap | ConvertTo-Json | Set-Content $script:resumeFile -Encoding utf8 } catch {}
}
function Set-Resume([string]$path, [int]$seconds, [string]$last) {
    if (-not $last) { $last = [DateTime]::Now.ToString('s') }
    $script:resumeMap[$path.ToLower()] = [pscustomobject]@{
        Path = $path; Seconds = [Math]::Max(0, $seconds); Last = $last
    }
    Save-ResumeMap
}

# Both stores, as one list, most-recently-touched first. Ours goes first and
# wins outright on any path it mentions: it is the only one of the two that
# is written the moment playback stops.
function Get-ResumeEntries {
    $out = @(); $seen = @{}
    $ours = @($script:resumeMap.Keys | Sort-Object {
        try { [DateTime]$script:resumeMap[$_].Last } catch { [DateTime]::MinValue }
    } -Descending)
    foreach ($k in $ours) {
        $seen[$k] = $true
        $sec = 0
        try { $sec = [int]$script:resumeMap[$k].Seconds } catch {}
        if ($sec -le 0) { continue }   # tombstone: claimed, but nothing to resume
        $p = [string]$script:resumeMap[$k].Path
        if ($p) { $out += [pscustomobject]@{ Path = $p; Seconds = $sec } }
    }
    foreach ($e in (Get-VlcResumeEntries)) {
        if ($seen[$e.Path.ToLower()]) { continue }
        $out += $e
    }
    return @($out)
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
$vlcDir     = if ($vlcExe) { Split-Path $vlcExe -Parent } else { $null }
$videoExtRe = '^\.(mp4|mkv|avi|webm|mov|m4v|wmv|mpg|mpeg|ts|flv)$'

# The built-in player (SETTINGS) plays through the libvlc inside that same
# VLC install, in a process of its own. Which PowerShell launches it is not
# a preference: a 32-bit libvlc cannot be loaded into 64-bit PowerShell, or
# the other way round, and VLC ships in both flavours. So read the machine
# type out of the DLL's PE header and hand the job to the host that matches.
# No VLC, or a header we can't read, means no built-in player - the setting
# says so rather than offering a mode that would fail at the first press.
function Get-PlayerHost([string]$dir) {
    if (-not $dir) { return $null }
    $dll = Join-Path $dir 'libvlc.dll'
    if (-not (Test-Path $dll)) { return $null }
    $machine = 0
    try {
        $fs = [IO.File]::OpenRead($dll)
        try {
            $br = New-Object IO.BinaryReader($fs)
            $fs.Position = 0x3C
            $fs.Position = $br.ReadInt32() + 4   # e_lfanew -> PE signature, then COFF header
            $machine = $br.ReadUInt16()
        } finally { $fs.Close() }
    } catch { return $null }
    # System32 is whatever bitness the CALLING process is, so a 32-bit CLInt
    # asking for the 64-bit host has to go via Sysnative to dodge the
    # file-system redirector.
    $native = if ([Environment]::Is64BitProcess -or -not [Environment]::Is64BitOperatingSystem) { 'System32' } else { 'Sysnative' }
    $path = switch ($machine) {
        0x8664  { Join-Path $env:SystemRoot "$native\WindowsPowerShell\v1.0\powershell.exe" }   # x64
        0x014C  { Join-Path $env:SystemRoot 'SysWOW64\WindowsPowerShell\v1.0\powershell.exe' }  # x86
        default { $null }                                                                       # arm64 etc: not ours to guess
    }
    if ($path -and (Test-Path $path)) { return $path }
    return $null
}
$playerHost = Get-PlayerHost $vlcDir
# Default on: CLInt's own player is the intended experience wherever the
# engine exists. Only an explicit "default app" choice in SETTINGS - saved
# as 'default' - opts out; no engine means no built-in player regardless.
$builtinPlayer = $playerHost -and ($settings['VideoPlayer'] -ne 'default')

# Videos VLC still holds a resume position for get a CURRENTLY WATCHING
# section at the top of the tab's ROOT listing - the games tabs' RECENTLY
# PLAYED idea, applied to what is half-watched rather than what was opened
# last. Subfolders are included: a part-watched episode buried three levels
# down is the one thing you want one keypress away, and it is listed by file
# name alone. The folders above it are how it was FOUND, not what it is -
# an episode already carries its show and number in its own name, and the
# row then reads exactly as it does in the browser below. Only at the root,
# though - inside a subfolder the listing is the plain browser again, or the
# same video would follow you around. VLC drops a file from this list the
# moment it plays to the end, so the section empties itself with no
# bookkeeping of ours.
#
# UP NEXT is the companion section for what was watched to the END: a
# folder stands in for a show, and the video after the folder's most
# recently finished one (same A-Z order as the browser) is the episode
# you'd reach for next. Play counts only record on completion, so the
# watch history IS the list of finished episodes. A folder holding a
# part-watched video contributes nothing - the thing to offer there is
# the CURRENTLY WATCHING row, not the episode after it - which is also
# why one show can sit in CURRENTLY WATCHING while another's next
# episode waits in UP NEXT. Finishing the last file of a folder simply
# retires the folder from the section.
# Do two file names read as episodes of the same show? Two shapes count.
# Names that differ only by number ("Alien 1"/"Alien 2", "Show 01"/"Show
# 02"): strip the digit runs and they collapse to one stem, while a folder
# of movies yields a different stem per file. And names that carry their
# episode titles ("... - S07E09 - Moving Day"/"... - S07E10 - Party Line"):
# the stems differ, but the names read identically up to the episode number
# and only part ways there - so a pair whose first difference is
# digit-against-digit also counts. That shared prefix must still hold a
# letter once a straddled digit run is trimmed off its end, or "2001 A
# Space Odyssey" and "2012" would pass on the strength of their dates
# alone. Movies keep failing both tests ("Alien 3" parts from "Aliens" at
# ' ' vs 's', not at a number), which is what keeps a movies folder out
# of UP NEXT. (An UNnumbered first film never queues its sequel anyway:
# culture sort puts "Die Hard 2.mkv" before "Die Hard.mkv", so the sequel
# is not "after" the finished film - pre-existing A-Z rule, not this.)
# Whitespace is collapsed and trimmed so the leftover separator around a
# stripped number ("Die Hard" vs "Die Hard 2 ") can't split a stem.
function Test-EpisodeSibling([string]$finished, [string]$candidate) {
    $a = ([System.IO.Path]::GetFileNameWithoutExtension($finished)  -replace '\s+', ' ').Trim().ToLower()
    $b = ([System.IO.Path]::GetFileNameWithoutExtension($candidate) -replace '\s+', ' ').Trim().ToLower()
    if ((($a -replace '\d+', '') -replace '\s+', ' ').Trim() -eq (($b -replace '\d+', '') -replace '\s+', ' ').Trim()) { return $true }
    $n = [Math]::Min($a.Length, $b.Length)
    $i = 0
    while ($i -lt $n -and $a[$i] -eq $b[$i]) { $i++ }
    if ($i -ge $n) { return $false }   # one name is a prefix of the other: nowhere left to part at a number
    if (-not ([char]::IsDigit($a[$i]) -and [char]::IsDigit($b[$i]))) { return $false }
    return (($a.Substring(0, $i) -replace '\d+$', '') -match '\p{L}')
}

function Add-VideoSections($t, $list, $entries) {
    if (-not $t.Root -or $t.Dir -ne $t.Root) { return @($list) }
    $prefix = $t.Root.TrimEnd('\') + '\'
    $watching = @(); $taken = @{}
    if ($script:watchingEnabled) {
        foreach ($e in $entries) {
            if (-not $e.Path.StartsWith($prefix, 'OrdinalIgnoreCase')) { continue }   # another tab's folder
            if ([System.IO.Path]::GetExtension($e.Path) -notmatch $script:videoExtRe) { continue }
            # VLC remembers a path long after the file moved, was deleted, or
            # went away with the drive it lived on - never list a dead row.
            if (-not (Test-Path -LiteralPath $e.Path -PathType Leaf)) { continue }
            $k = $e.Path.ToLower()
            $plays = 0
            if ($script:videoHistEnabled -and $script:watchMap[$k]) {
                try { $plays = [int]$script:watchMap[$k].Plays } catch {}
            }
            $watching += [pscustomobject]@{
                Name = [System.IO.Path]::GetFileName($e.Path); Path = $e.Path; Type = 'File'
                Plays = $plays; Resume = $e.Seconds; Watching = $true
            }
            $taken[$k] = $true
        }
    }
    $upNext = @()
    if ($script:upNextEnabled -and $script:videoHistEnabled -and $script:watchMap.Count -gt 0) {
        # Folders with a live half-watched video are continue-watching
        # territory, whatever the CurrentlyWatching toggle says - collect
        # them first so their next episode is never suggested over the
        # resume. A resume entry whose file is gone doesn't count: there
        # is nothing left to continue.
        $partial = @{}
        foreach ($e in $entries) {
            if (-not $e.Path.StartsWith($prefix, 'OrdinalIgnoreCase')) { continue }
            if ([System.IO.Path]::GetExtension($e.Path) -notmatch $script:videoExtRe) { continue }
            if (-not (Test-Path -LiteralPath $e.Path -PathType Leaf)) { continue }
            $partial[([System.IO.Path]::GetDirectoryName($e.Path)).ToLower()] = $true
        }
        # Each folder's most recently finished video, by the watch map's
        # Last stamp. Keys are already lower-cased full paths.
        $latest = @{}
        foreach ($k in @($script:watchMap.Keys)) {
            if (-not $k.StartsWith($prefix, 'OrdinalIgnoreCase')) { continue }
            if ([System.IO.Path]::GetExtension($k) -notmatch $script:videoExtRe) { continue }
            $d = [System.IO.Path]::GetDirectoryName($k)
            if ($partial[$d]) { continue }
            $when = [DateTime]::MinValue
            try { $when = [DateTime]$script:watchMap[$k].Last } catch {}
            if (-not $latest[$d] -or $when -gt $latest[$d].When) {
                $latest[$d] = [pscustomobject]@{ Name = [System.IO.Path]::GetFileName($k); When = $when }
            }
        }
        # Newest shows first, capped so a long backlog of finished shows
        # can't push the browser off the screen. The finished file itself
        # only needs to have EXISTED - deleting watched episodes is normal
        # housekeeping, and its name still orders the folder's survivors.
        foreach ($d in @($latest.Keys | Sort-Object { $latest[$_].When } -Descending)) {
            if ($upNext.Count -ge 5) { break }
            $next = $null
            foreach ($f in @(Get-ChildItem -LiteralPath $d -File -ErrorAction SilentlyContinue | Sort-Object Name)) {
                if ($f.Name.StartsWith('.')) { continue }
                if ($f.Extension -notmatch $script:videoExtRe) { continue }
                if ($f.Name -le $latest[$d].Name) { continue }
                # Only another episode of the same show qualifies - in a
                # movies folder no candidate reads as one, so the folder
                # never queues. A miss is invisible; a wrong suggestion
                # is noticed.
                if (-not (Test-EpisodeSibling $latest[$d].Name $f.Name)) { continue }
                $next = $f; break
            }
            if (-not $next -or $taken[$next.FullName.ToLower()]) { continue }
            # $d came out of a lower-cased watch key, and Get-ChildItem hands
            # that casing straight back in FullName. Only the parent folder's
            # name is ever shown (the collision rows below), so put its real
            # casing back and let the deeper segments stay as they are.
            try {
                $gp = $next.Directory.Parent
                if ($gp) {
                    $hit = @($gp.GetDirectories($next.Directory.Name))
                    if ($hit.Count -eq 1) {
                        $next = [System.IO.FileInfo](Join-Path $hit[0].FullName $next.Name)
                    }
                }
            } catch {}
            $k = $next.FullName.ToLower()
            $plays = 0
            if ($script:watchMap[$k]) { try { $plays = [int]$script:watchMap[$k].Plays } catch {} }
            $upNext += [pscustomobject]@{
                Name = $next.Name; Path = $next.FullName; Type = 'File'
                Plays = $plays; Resume = $null
            }
            $taken[$k] = $true
        }
    }
    if ($watching.Count -eq 0 -and $upNext.Count -eq 0) { return @($list) }
    # Names alone can collide - "Show\Season 1\01.mkv" and "Season 2\01.mkv"
    # both come through as "01.mkv", and two identical rows are worse than
    # one long one. Only the colliding rows get their folder back, so the
    # ordinary case stays a bare file name. Checked across both sections:
    # The Wire's resume row and its up-next row collide just as readily.
    $lifted = @($watching) + @($upNext)
    $seen = @{}
    foreach ($w in $lifted) {
        $n = $w.Name.ToLower()
        $seen[$n] = 1 + [int]$seen[$n]
    }
    foreach ($w in $lifted) {
        if ($seen[$w.Name.ToLower()] -gt 1) {
            # NOT Split-Path: -LiteralPath and -Parent are different parameter
            # sets in PS 5.1 and throw together, and plain -Path would read a
            # folder named "Season [1]" as a wildcard.
            $parent = [System.IO.Path]::GetFileName([System.IO.Path]::GetDirectoryName($w.Path))
            if ($parent) { $w.Name = $parent + '\' + $w.Name }
        }
    }
    # Lifted, not copied: a root-level video listed above must not show up
    # again in the A-Z rows below it.
    $rest = @($list | Where-Object { $_.Type -ne 'File' -or -not $taken[$_.Path.ToLower()] })
    $out = @()
    if ($watching.Count -gt 0) {
        $out += [pscustomobject]@{ Name = 'CURRENTLY WATCHING'; Unselectable = $true }
        $out += $watching
    }
    if ($upNext.Count -gt 0) {
        if ($out.Count -gt 0) { $out += [pscustomobject]@{ Name = ''; Unselectable = $true } }   # blank spacer row
        $out += [pscustomobject]@{ Name = 'UP NEXT'; Unselectable = $true }
        $out += $upNext
    }
    if ($rest.Count -gt 0) {
        $out += [pscustomobject]@{ Name = '';       Unselectable = $true }   # blank spacer row
        $out += [pscustomobject]@{ Name = 'BROWSE'; Unselectable = $true }
        $out += $rest
    }
    return @($out)
}

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
    $resumeEntries = if ($script:videoHistEnabled -or $script:watchingEnabled) { @(Get-ResumeEntries) } else { @() }
    $vlcResume = @{}
    foreach ($e in $resumeEntries) { $vlcResume[$e.Path.ToLower()] = $e.Seconds }
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
    return @(Add-VideoSections $t $list $resumeEntries)
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

# Game and video options each live on their own sub-page, reached from
# SETTINGS. They are built here rather than inline so the sub-page can
# rebuild its rows after every change and show the new value in place.
function Get-GameSettingsItems {
    $list = @()
    $list += [pscustomobject]@{ Key = 'NonSteam'
                                Name = ('Non-Steam apps in Steam tabs'.PadRight(30) + $(if ($script:nonSteamEnabled) { 'on' } else { 'off' })) }
    $list += [pscustomobject]@{ Key = 'Recent'
                                Name = ('Recently played first'.PadRight(30) + $(if ($script:recentEnabled) { 'on' } else { 'off' })) }
    $list += [pscustomobject]@{ Key = 'Playtime'
                                Name = ('Steam playtime tag'.PadRight(30) + $(if ($script:playtimeEnabled) { 'on' } else { 'off' })) }
    $list += [pscustomobject]@{ Key = 'SessionTime'
                                Name = ('Time played on return'.PadRight(30) + $(if ($script:sessionTimeOn) { 'on' } else { 'off' })) }
    return $list
}

function Get-VideoSettingsItems {
    $list = @()
    $list += [pscustomobject]@{ Key = 'VideoPlayer'
                                Name = ('Video player'.PadRight(30) +
                                        $(if ($script:builtinPlayer)  { "CLInt's own player" }
                                          elseif ($script:playerHost) { 'default app' }
                                          else                        { 'default app  (needs VLC for the built-in one)' })) }
    # Only meaningful while the built-in player is the one being used, so
    # it appears under that row rather than sitting there doing nothing.
    if ($script:builtinPlayer) {
        $list += [pscustomobject]@{ Key = 'PlayerHints'
                                    Name = ('Player button hints'.PadRight(30) +
                                            $(if ($script:playerHints) { 'on' } else { 'off' })) }
        $list += [pscustomobject]@{ Key = 'Subtitles'
                                    Name = ('Subtitles on by default'.PadRight(30) +
                                            $(if ($script:subtitlesOn) { 'on' } else { 'off' })) }
        # Only the built-in player knows a file's length, so only it can
        # honour this - shown under its row for the same reason as above.
        $list += [pscustomobject]@{ Key = 'WatchedAt'
                                    Name = ('Counts as watched at'.PadRight(30) + "$($script:watchedPct)%") }
    }
    $list += [pscustomobject]@{ Key = 'VideoHist'
                                Name = ('Video history'.PadRight(30) + $(if ($script:videoHistEnabled) { 'on' } else { 'off' })) }
    $list += [pscustomobject]@{ Key = 'Watching'
                                Name = ('Currently watching first'.PadRight(30) + $(if ($script:watchingEnabled) { 'on' } else { 'off' })) }
    # UP NEXT is built from the play counts, so while video history is
    # off it would be a toggle that does nothing - hidden rather than dead.
    if ($script:videoHistEnabled) {
        $list += [pscustomobject]@{ Key = 'UpNext'
                                    Name = ('Up next'.PadRight(30) + $(if ($script:upNextEnabled) { 'on' } else { 'off' })) }
    }
    if (-not $script:vlcExe) {
        $list += [pscustomobject]@{ Key = 'VlcInfo'
                                    Name = 'VLC not detected - videos will open in the default player' }
    }
    return $list
}

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
    # What the tabs hold gets a page each, so the list below stays about
    # CLInt itself rather than mixing games and videos into one column.
    $list += [pscustomobject]@{ Key = 'GameSettings'
                                Name = ('Game settings'.PadRight(30) + 'Steam library, recently played') }
    $list += [pscustomobject]@{ Key = 'VideoSettings'
                                Name = ('Video settings'.PadRight(30) + 'player, history, currently watching, up next') }
    $list += [pscustomobject]@{ Key = 'Fullscreen'; Name = 'Toggle fullscreen' }
    $list += [pscustomobject]@{ Key = 'ShowClock'
                                Name = ('Show clock'.PadRight(30) + $(if ($script:showClock) { 'on' } else { 'off' })) }
    $list += [pscustomobject]@{ Key = 'ShowBattery'
                                Name = ('Show battery'.PadRight(30) + $(if ($script:showBattery) { 'on' } else { 'off' })) }
    $list += [pscustomobject]@{ Key = 'AutoCheck'
                                Name = ('Check updates at launch'.PadRight(30) + $(if ($script:autoCheck) { 'on' } else { 'off' })) }
    $list += [pscustomobject]@{ Key = 'AutoStart'
                                Name = ('Launch at startup'.PadRight(30) + $(if ($script:autoStart) { 'on' } else { 'off' })) }
    $list += [pscustomobject]@{ Key = 'Mouse'
                                Name = ('Mouse support'.PadRight(30) + $(if ($script:mouseEnabled) { 'on' } else { 'off' })) }
    # Only worth showing while the mouse is on - otherwise it is a toggle
    # that does nothing.
    if ($script:mouseEnabled) {
        $list += [pscustomobject]@{ Key = 'HoverTabs'
                                    Name = ('Change tabs on hover'.PadRight(30) + $(if ($script:hoverTabs) { 'on' } else { 'off' })) }
    }
    $list += [pscustomobject]@{ Key = 'MenuKey'
                                Name = ('Menu key'.PadRight(30) +
                                        $(if ($script:hotkeyReady) { Get-MenuKeySummary $script:rootDir }
                                          else { 'unavailable - re-run Install.bat' })) }
    $list += [pscustomobject]@{ Key = 'ButtonHints'
                                Name = ('Button hints'.PadRight(30) + $script:controlHints) }
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
    Snap-Selection   # the root's CURRENTLY WATCHING section may have grown or shrunk while we were away
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

# Pull the viewport back around the selection. Every other caller adjusts
# $offset itself as it moves the cursor; this is for the case where the
# viewport changed size instead - a resize leaves $offset pointing where a
# taller window used to reach, and the cursor off the bottom of the screen.
function Snap-Viewport {
    if ($script:items.Count -eq 0) { $script:offset = 0; return }
    $maxOff = [Math]::Max(0, $script:items.Count - $script:visible)
    if ($script:offset -gt $maxOff) { $script:offset = $maxOff }
    if ($script:selected -lt $script:offset) { $script:offset = $script:selected }
    if ($script:selected -ge $script:offset + $script:visible) {
        $script:offset = $script:selected - $script:visible + 1
    }
    if ($script:offset -lt 0) { $script:offset = 0 }
}

$items = @(Get-TabItems 0)
Snap-Selection

function Write-At([int]$x, [int]$y, [string]$text, $fg, $bg) {
    # SetCursorPosition is bounded by the BUFFER, and the buffer can change
    # under us between the layout that produced these coordinates and this
    # write - a game switching resolution, the fullscreen transition
    # settling, a window drag. A stale coordinate then throws, which killed
    # the whole frame; on the mouse path (hover -> Draw-ScrollHints, at
    # W - 2) it threw on every mouse movement and filled error.log. Skipping
    # the write costs one smeared cell until the next redraw, which the
    # resize check in Read-InputKey now schedules anyway.
    try {
        [Console]::SetCursorPosition($x, $y)
        if ($bg) { Write-Host $text -ForegroundColor $fg -BackgroundColor $bg -NoNewline }
        else     { Write-Host $text -ForegroundColor $fg -NoNewline }
    } catch {}
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
    # That pin is allowed to fail (a resize still in flight, a buffer conhost
    # won't shrink right now), and it silently used to leave W/H describing a
    # window LARGER than the buffer every draw is clipped to. Take whichever
    # is smaller: an under-drawn row is a cosmetic miss until the next
    # redraw; a coordinate past the buffer is an exception mid-frame.
    try {
        $script:W = [Math]::Min($script:W, [Console]::BufferWidth)
        $script:H = [Math]::Min($script:H, [Console]::BufferHeight)
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
        # Steam's own lifetime playtime, and only for real Steam games -
        # a non-Steam shortcut has none on record, so it gets no tag rather
        # than a number that would mean something different on every row.
        if ($script:playtimeEnabled -and $items[$i].Steam) {
            $mins = [int](Get-SteamPlaytime)[[string]$items[$i].AppId]
            if ($mins -ge 60) { $label += "  [$([Math]::Floor($mins / 60))h]" }
        }
    } elseif ($type -eq 'Files' -and $items[$i].Type -eq 'File') {
        # A CURRENTLY WATCHING row is the resume position, so it carries the
        # timestamp whether or not the video-history tags are switched on.
        if ($items[$i].Resume -and ($script:videoHistEnabled -or $items[$i].Watching)) {
            $ts = [TimeSpan]::FromSeconds([double]$items[$i].Resume)
            $pos = if ($ts.Hours -gt 0) { $ts.ToString('h\:mm\:ss') } else { $ts.ToString('m\:ss') }
            $label += "  [>> $pos]"
        }
        if ($script:videoHistEnabled -and $items[$i].Plays -ge 1) { $label += "  [x$($items[$i].Plays)]" }
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
# Set by modals; shown after the next full redraw. Seeded with whatever
# the startup hotkey cycle had to report - that ran long before this
# variable existed, and its one failure mode is precisely the kind that
# shows nothing anywhere else.
$pendingNotice = $script:hotkeyUpdateNotice
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
        'Files'     { Pad "$($cur.Dir)  ($nReal items)" ($W - 16) }
        'Settings'  { 'settings are saved automatically' }
    }
    Write-At 15 1 $count $theme.Info
    $help = if ($cur.Type -eq 'Settings') { Hint '[ {Move}    {Tab}    {A}: change    {B}: quit ]' }
            elseif ($tdpEnabled -and $cur.Type -in 'Steam', 'Shortcuts') { Hint '[ {Move}    {A}: launch    {RB}: TDP    {Y}: options    {B}: quit ]' }
            else { Hint '[ {Move}    {Tab}    {A}: launch    {Y}: options    {B}: quit ]' }
    # Clipped to the line: unpadded it WRAPS on a narrow window, and the
    # wrapped tail lands on the first list row.
    Write-At 15 3 (Pad $help ($W - 16)) $theme.Hint
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
// The left stick folds into the d-pad bits so menus react to either.
// Dominant axis only - a tilted up/down scroll must not drift into a
// tab switch - and engage/release hysteresis so a wobble right at the
// threshold cannot machine-gun fresh presses.
private const int ENGAGE = 16384, RELEASE = 10000;
private static int stickDir = 0;
public static int StickDpad(int lx, int ly) {
    int dir = 0;
    if (Math.Abs(ly) >= Math.Abs(lx)) {
        if (ly >= ENGAGE) dir = 0x0001; else if (ly <= -ENGAGE) dir = 0x0002;
    } else {
        if (lx <= -ENGAGE) dir = 0x0004; else if (lx >= ENGAGE) dir = 0x0008;
    }
    if (dir == 0) {
        int d = stickDir;
        if ((d == 0x0001 && ly >= RELEASE) || (d == 0x0002 && ly <= -RELEASE) ||
            (d == 0x0004 && lx <= -RELEASE) || (d == 0x0008 && lx >= RELEASE)) dir = d;
    }
    stickDir = dir;
    return dir;
}
public static int GetButtons() {
    int b = 0, lx = 0, ly = 0;
    var s = new XINPUT_STATE();
    for (uint i = 0; i < 4; i++) {
        try {
            if (XInputGetState(i, ref s) == 0) {
                b |= s.Gamepad.wButtons;
                if (Math.Abs((int)s.Gamepad.sThumbLX) > Math.Abs(lx)) lx = s.Gamepad.sThumbLX;
                if (Math.Abs((int)s.Gamepad.sThumbLY) > Math.Abs(ly)) ly = s.Gamepad.sThumbLY;
            }
        }
        catch (DllNotFoundException) { return -1; }
    }
    return b | StickDpad(lx, ly);
}
'@
} catch { $script:padOk = $false }

# Button masks -> menu keys; d-pad directions auto-repeat while held.
# GetButtons already folds the left stick into the d-pad bits, so the
# stick inherits these mappings (and the repeat rules) for free.
$PAD_BUTTONS = @(
    @{ Mask = 0x0001; Key = [ConsoleKey]::UpArrow;    Repeat = $true  }   # d-pad/stick up
    @{ Mask = 0x0002; Key = [ConsoleKey]::DownArrow;  Repeat = $true  }   # d-pad/stick down
    # Left/right only switch tabs, so they must NOT auto-repeat: an empty
    # tab redraws instantly, and a brief hold would repeat and skip past it.
    @{ Mask = 0x0004; Key = [ConsoleKey]::LeftArrow;  Repeat = $false }   # d-pad/stick left
    @{ Mask = 0x0008; Key = [ConsoleKey]::RightArrow; Repeat = $false }   # d-pad/stick right
    @{ Mask = 0x1000; Key = [ConsoleKey]::Enter;      Repeat = $false }   # A = launch/open
    @{ Mask = 0x2000; Key = [ConsoleKey]::Escape;     Repeat = $false }   # B = back/quit
    # Y used to be a second "next tab", which the d-pad and stick already
    # do either way - it is the item menu now, matching the M key.
    @{ Mask = 0x8000; Key = [ConsoleKey]::M;          Repeat = $false }   # Y = item menu
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

# The tab bar is row 0; $tabHit holds each tab's cell extent as recorded
# by the last Draw-All. Shared by the click path and the optional hover
# path so both land on exactly the same tab for a given column.
function Switch-TabAt([int]$x) {
    foreach ($hit in $script:tabHit) {
        if ($x -ge $hit[0] -and $x -le $hit[1]) {
            if ($hit[2] -ne $script:tab) { Switch-Tab ($hit[2] - $script:tab) }
            return
        }
    }
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
            if ($r.Flags -band 4) {   # wheel (delta sign lives in the high word)
                $down = [bool]($r.Btn -band 0x80000000)
                # collapse a queued burst of same-direction notches - a fast
                # flick queues faster than a big-library redraw drains - but
                # COUNT them, so a flick still travels as far as it was spun
                $notches = 1
                while ($true) {
                    $n2 = [uint32]0
                    if (-not [CLIntMouse.Win]::GetNumberOfConsoleInputEvents($hin, [ref]$n2) -or $n2 -eq 0) { break }
                    $p = New-Object CLIntMouse.Rec
                    $g2 = [uint32]0
                    if (-not [CLIntMouse.Win]::PeekConsoleInput($hin, [ref]$p, 1, [ref]$g2) -or $g2 -eq 0) { break }
                    if ($p.EventType -ne 2 -or -not ($p.Flags -band 4) -or
                        ([bool]($p.Btn -band 0x80000000)) -ne $down) { break }
                    [CLIntMouse.Win]::ReadConsoleInput($hin, [ref]$p, 1, [ref]$g2) | Out-Null
                    $notches++
                }
                $script:wheelSteps = $notches
                # Modals move their own cursor and have no viewport to scroll
                # independently of it, so there the wheel stays a plain arrow.
                if ($script:inModal) {
                    if ($down) { return 'DownArrow' } else { return 'UpArrow' }
                }
                # On the main list it scrolls the VIEW instead. Moving the
                # selection was self-defeating: the pointer hasn't moved, so
                # the next mouse-move event hover-selected the row under it
                # again and put the cursor straight back - the wheel looked
                # dead. The row the pointer ends up over is recorded here
                # because a wheel record carries the pointer position too.
                $script:wheelY = $r.Y
                $script:hoverMuted = $false   # the mouse is being used again
                if ($down) { return 'ScrollDown' } else { return 'ScrollUp' }
            }
            $leftNow = [bool]($r.Btn -band 1)
            $isMove  = [bool]($r.Flags -band 1)
            # a press is a fresh left-down on a plain button event (flags 0,
            # or 2 for the double-click repeat - already down, so no edge)
            $press   = -not $isMove -and $leftNow -and -not $script:mouseLeftWas
            $script:mouseLeftWas = $leftNow
            # Right button, same press-edge rule: it opens the item menu.
            $rightNow   = [bool]($r.Btn -band 2)
            $rightPress = -not $isMove -and $rightNow -and -not $script:mouseRightWas
            $script:mouseRightWas = $rightNow
            if ($press -or $rightPress) { $script:hoverMuted = $false }   # a click is the mouse taking over
            if ($isMove) {
                # Same cell as last time = the pointer hasn't really gone
                # anywhere: sub-cell wobble, or conhost re-reporting a
                # stationary pointer. Nothing to hover.
                if ($r.X -eq $script:mouseCellX -and $r.Y -eq $script:mouseCellY) { continue }
                $script:mouseCellX = $r.X; $script:mouseCellY = $r.Y
                # First real cell change after pad/keyboard navigation only
                # un-mutes: it takes a deliberate move (any second cell) to
                # hand the selection back, so one stray cell of drift can't
                # steal the cursor from under the controller.
                if ($script:hoverMuted) {
                    $script:hoverMuted = $false
                    # A modal's cursor has moved by pad since the last hover,
                    # so the remembered hover index is stale: clear it, or a
                    # move back onto that same row would look like no change
                    # and fire nothing.
                    $script:modalHover = -1
                    continue
                }
            }
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
                if ($r.Y -eq 0) {
                    # Tab bar. Switching on hover is opt-in (HoverTabs, off by
                    # default): the pointer crosses the bar on its way to the
                    # window edge, and with it on that flips through every tab
                    # it passes over - which is the point when you asked for
                    # it and an accident when you did not.
                    if ($script:hoverTabs) { Switch-TabAt $r.X }
                    continue
                }
                Select-RowAt $r.Y | Out-Null
                continue
            }
            # Right-click acts on the row it lands on, so it selects that row
            # first - the menu that opens is always about the row you pointed
            # at, not wherever the cursor happened to be.
            if ($rightPress) {
                if ($r.Y -ne 0 -and (Select-RowAt $r.Y) -ge 0) { return 'MenuKey' }
                continue
            }
            if (-not $press) { continue }
            if ($r.Y -eq 0) {   # tab bar
                Switch-TabAt $r.X
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
        # Keyboard and pad both mute hover: while the user is driving the
        # selection themselves, a pointer parked over the list must not keep
        # pulling the cursor back to whatever row it happens to sit on.
        if ([Console]::KeyAvailable) {
            $ki = [Console]::ReadKey($true)
            $k = $ki.Key
            # Remote-keyboard apps (Remote Helper's Keyboard mode among them)
            # inject characters as KEYEVENTF_UNICODE, which arrives as
            # VK_PACKET (231) with the real character riding alongside.
            # Translate it back so the switches downstream, which only ever
            # see the ConsoleKey, keep working.
            if ([int]$k -eq 231) {
                $c = $ki.KeyChar
                $k = switch ($c) {
                    ' '        { [ConsoleKey]::Spacebar }
                    "`r"       { [ConsoleKey]::Enter }
                    "`n"       { [ConsoleKey]::Enter }
                    ([char]27) { [ConsoleKey]::Escape }
                    "`t"       { [ConsoleKey]::Tab }
                    ([char]8)  { [ConsoleKey]::Backspace }
                    default    {
                        if     ($c -ge 'a' -and $c -le 'z') { [ConsoleKey]([int][ConsoleKey]::A + ([int]$c - [int][char]'a')) }
                        elseif ($c -ge 'A' -and $c -le 'Z') { [ConsoleKey]([int][ConsoleKey]::A + ([int]$c - [int][char]'A')) }
                        elseif ($c -ge '0' -and $c -le '9') { [ConsoleKey]([int][ConsoleKey]::D0 + ([int]$c - [int][char]'0')) }
                        else { $ki.Key }
                    }
                }
            }
            if ("$k" -in 'UpArrow', 'DownArrow') { Drain-RepeatArrows "$k" }
            $script:hoverMuted = $true
            return $k
        }
        $k = Get-PadKey
        if ($null -ne $k) { $script:hoverMuted = $true; return $k }
        # The window can resize while we sit here waiting (the fullscreen
        # transition settles a beat after launch, a game changes resolution
        # and hands the desktop back smaller, frames get dragged), and a
        # buffer wider than the window means a scrollbar until the next
        # keypress triggered a redraw. Re-pin the buffer promptly instead.
        if ([Environment]::TickCount -ge $script:bufferCheckNext) {
            $script:bufferCheckNext = [Environment]::TickCount + 300
            # First, undo any minimize/restore damage (an eaten taskbar
            # click, a window restored off-screen): a heal changes the
            # console size, and the resize check just below then redraws
            # in this same tick.
            Repair-MenuWindow
            $resized = $false
            try {
                $cw = [Console]::WindowWidth
                $ch = [Console]::WindowHeight
                # Re-pinning the buffer to a window that SHRANK used to leave
                # $W/$H describing the old, bigger one - and every draw between
                # here and the next full redraw then wrote past the buffer's
                # last column. Hover was the one that noticed, several times a
                # second, because it repaints the scroll hints at W - 2.
                $resized = ($cw -ne $script:W -or $ch -ne $script:H)
                if ([Console]::BufferWidth -ne $cw -or [Console]::BufferHeight -ne $ch) {
                    $Host.UI.RawUI.BufferSize = New-Object System.Management.Automation.Host.Size($cw, $ch)
                }
            } catch {}
            Hide-Scrollbars   # conhost leaves stale bars behind after transient mismatches
            if ($resized) {
                Get-Layout        # geometry first: a modal repaints itself from it next frame
                if (-not $script:inModal) {
                    Snap-Viewport # a shorter viewport can leave the cursor off-screen
                    Draw-All
                }
            }
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
    # Set whenever this listing was reached by going UP a level: the cursor
    # lands back on '..' instead of on '[ use this folder ]', so holding A
    # (or Enter) climbs out of a deep tree one level per press. Landing on
    # the pick row meant the second press chose the folder you had just
    # left, which is never what a double-tap out of nested folders means.
    $landOnUp = $false
    Clear-Host
    Get-Layout
    while ($true) {
        if ($needList) {
            $entries = @(Get-PickerEntries $dir)
            if ($landOnUp) {
                $i = 0
                while ($i -lt $entries.Count -and $entries[$i].Type -ne 'Up') { $i++ }
                # The drive list has no '..' row - fall back to the top there.
                $sel = $(if ($i -lt $entries.Count) { $i } else { 0 })
                $landOnUp = $false
            }
            if ($sel -ge $entries.Count) { $sel = [Math]::Max(0, $entries.Count - 1) }
            $needList = $false
        }
        Write-At 2 0 (Pad "CHOOSE FOLDER  --  $label" ($W - 4)) $theme.Accent
        Write-At 2 1 (Pad ("Now: " + $(if ($dir) { $dir } else { 'select a drive' })) ($W - 4)) $theme.Info
        Write-At 2 3 (Hint '[ {Move}    {A}: open / choose    {B}: up / cancel ]') $theme.Hint
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
                        $sel = 0; $off = 0; $needList = $true; $landOnUp = $true
                    }
                }
            }
            'Escape'    {
                if ($null -eq $dir) { return $null }   # B in the drive list cancels
                $parent = Split-Path $dir -Parent
                $dir = if ([string]::IsNullOrEmpty($parent)) { $null } else { $parent }
                $sel = 0; $off = 0; $needList = $true; $landOnUp = $true
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
        Write-At 2 2 (Hint '[ {Move}    {A}: choose    {B}: cancel ]') $theme.Hint
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

# B / Escape / Q used to close CLInt on the spot, which is easy to do by
# accident on a pad - B is also the back button everywhere else. Ask first.
# Yes sits on top and the cursor starts there, so quitting stays a two-press
# muscle-memory move: B, A. An accidental B is still caught, because it takes
# the second press to go through - and B again cancels the prompt outright.
# SETTINGS -> [ quit CLInt ] stays a direct exit: getting there is already
# deliberate.
function Confirm-Quit {
    return ((Pick-Option 'QUIT CLInt?' @('Yes - quit CLInt', 'No - keep CLInt open')) -eq 0)
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
        Write-At 2 2 (Hint '[ {Move}    {A}: choose    {B}: cancel ]') $theme.Hint
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
    Write-At 2 2 (Hint '[ type on the keyboard    {EnterA}: save    {EscB}: cancel    empty: automatic name ]') $theme.Hint
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

# Scrolling variant of Pick-Option, for lists longer than the screen
# (Pick-Option draws every row it is handed, so the key list would run off
# the bottom). Returns the chosen index, or -1 on cancel.
function Pick-ScrollList([string]$title, [string]$hint, [string[]]$rows, [int]$start = 0) {
    $script:inModal = $true
    if ($rows.Count -eq 0) { return -1 }
    $sel = [Math]::Max(0, [Math]::Min($start, $rows.Count - 1))
    $off = 0
    Clear-Host
    Get-Layout
    while ($true) {
        Write-At 2 0 (Pad $title ($W - 4)) $theme.Accent
        Write-At 2 2 (Pad $hint ($W - 4)) $theme.Hint
        $top = 4
        $vis = [Math]::Max(1, $H - $top - 1)
        if ($sel -lt $off) { $off = $sel }
        if ($sel -ge $off + $vis) { $off = $sel - $vis + 1 }
        $rowW = $W - 3   # NOT $w - see the note in the folder picker
        for ($r = 0; $r -lt $vis; $r++) {
            $i = $off + $r
            if ($i -lt $rows.Count) {
                if ($i -eq $sel) { Write-At 1 ($top + $r) (Pad ('  >> ' + $rows[$i] + '  ') $rowW) $theme.SelFg $theme.Accent }
                else             { Write-At 1 ($top + $r) (Pad ('     ' + $rows[$i] + '  ') $rowW) $theme.Text }
            } else {
                Write-At 1 ($top + $r) (' ' * $rowW) $theme.Text
            }
        }
        $script:modalTop = $top; $script:modalOff = $off
        $script:modalRows = $vis; $script:modalCount = $rows.Count
        switch (Read-InputKey) {
            'UpArrow'    { $sel = ($sel - 1 + $rows.Count) % $rows.Count }
            'DownArrow'  { $sel = ($sel + 1) % $rows.Count }
            'MouseHover' { $sel = $script:modalHover }
            { "$_" -in 'Enter', 'MouseClick' } {
                if ("$_" -eq 'MouseClick') { $sel = $script:modalHover }
                return $sel
            }
            'Escape' { return -1 }
            'Q'      { return -1 }
        }
    }
}

# Full-screen "hold on" line. Setting the key waits on the hotkey script's
# reply (a second or two at worst), and a frozen menu with no explanation
# reads as a crash.
function Show-Working([string]$title, [string]$line) {
    $script:inModal = $true
    $script:modalTop = -1   # no rows: nothing for the mouse to hit-test
    Clear-Host
    Get-Layout
    Write-At 2 0 (Pad $title ($W - 4)) $theme.Accent
    Write-At 2 3 (Pad $line ($W - 4)) $theme.Text
}

# Capture one keypress, raw. Modifier keys don't arrive on their own, so
# Ctrl+Alt+M comes through as a single event with its modifiers attached.
function Read-MenuKeyPress {
    $script:inModal = $true
    $script:modalTop = -1
    Clear-Host
    Get-Layout
    Write-At 2 0 (Pad 'MENU KEY  --  PRESS THE KEY YOU WANT' ($W - 4)) $theme.Accent
    Write-At 2 2 (Pad 'The current menu key is switched off, so it cannot open CLInt over this screen.' ($W - 4)) $theme.Info
    Write-At 2 4 (Pad 'Hold Fn if the key needs it, and press it exactly as you normally would.' ($W - 4)) $theme.Text
    Write-At 2 5 (Pad "If nothing registers, or the wrong key is detected, go back and choose from" ($W - 4)) $theme.Text
    Write-At 2 6 (Pad "the list instead - that binds by name and ignores how your keyboard sends it." ($W - 4)) $theme.Text
    Write-At 2 8 (Pad (Hint '[ {EscB}: cancel ]') ($W - 4)) $theme.Hint
    while ($true) {
        if ([Console]::KeyAvailable) {
            $k = [Console]::ReadKey($true)
            if ($k.Key -eq [ConsoleKey]::Escape -and $k.Modifiers -eq 0) { return $null }
            $name = Convert-KeyPressToAhk $k
            if ($name) { return $name }
        }
        if ((Get-PadKey) -eq [ConsoleKey]::Escape) { return $null }
        Start-Sleep -Milliseconds 16
    }
}

# SETTINGS -> Menu key. Everything about the global hotkey lives here now:
# re-running the installer to change it meant typing at a console that the
# old key could (and did) bury under a fresh copy of CLInt.
function Configure-MenuKey {
    if (-not $script:hotkeyReady) {
        $script:pendingNotice = 'Menu key setup needs app\Hotkey.ps1 - re-run Install.bat.'
        return
    }
    if (-not (Find-AhkExe)) {
        # A global hotkey has to live in something that is always running;
        # AutoHotkey v2 is that something.
        $c = Pick-Option 'MENU KEY  --  this needs AutoHotkey v2 (free, and CLInt is its only user here)' @(
            'Install AutoHotkey v2 now (winget)', 'Not now')
        if ($c -ne 0) { return }
        Clear-Host
        Write-Host ""
        Write-Host "   INSTALLING AUTOHOTKEY V2..." -ForegroundColor $theme.Accent
        Write-Host ""
        try { winget install --id AutoHotkey.AutoHotkey --accept-source-agreements --accept-package-agreements } catch {}
        if (-not (Find-AhkExe)) {
            Write-Host ""
            Write-Host "   Still not found - install it from autohotkey.com, then come back here." -ForegroundColor Yellow
            Write-Host ""
            Write-Host "   press any button to go back" -ForegroundColor $theme.Hint
            $script:inModal = $true   # the menu geometry is gone from this screen
            Read-InputKey | Out-Null
            return
        }
    }
    while ($true) {
        $curKey = Get-MenuKeyName $script:rootDir
        $st     = Get-MenuKeyStatus $script:rootDir
        if (-not $curKey -and $st) { $curKey = $st.Key }
        $title = "MENU KEY  --  currently: $(Get-MenuKeyLabel $curKey)"
        if ($st -and $st.State -in 'fail', 'unknown') { $title += '   (not working - pick another)' }
        $opts = @('Choose from a list',
                  'Press the key I want to use',
                  'Turn the menu key off',
                  'Done')
        $c = Pick-Option $title $opts
        if ($c -lt 0 -or $c -eq 3) { return }

        if ($c -eq 2) {
            Show-Working 'MENU KEY' 'Turning the menu key off...'
            $script:pendingNotice = (Set-MenuKey $script:rootDir 'off').Message
            return
        }

        # Kill the current binding BEFORE asking for a new one. Re-binding
        # the key you already use means pressing it while it still works,
        # which used to launch CLInt on top of the thing doing the rebind.
        Show-Working 'MENU KEY' 'Releasing the current key...'
        $sus = Suspend-MenuKey $script:rootDir
        if (-not $sus.Ok) {
            # The old key might still be live, so nobody gets asked to PRESS
            # one - that press would open CLInt over the screen asking for
            # it, which is the whole bug. Choosing by name is unaffected, so
            # offer that rather than dead-ending here.
            if ((Pick-Option "MENU KEY  --  $($sus.Message)" @('Choose from a list anyway', 'Cancel')) -ne 0) {
                Set-MenuKey $script:rootDir $curKey | Out-Null   # leave the old binding as we found it
                return
            }
            $c = 0
        }

        $chosen = $null
        if ($c -eq 0) {
            $choices = @(Get-MenuKeyChoices)
            $rows    = @($choices | ForEach-Object { $_.Label.PadRight(20) + $_.Hint })
            $start   = [Math]::Max(0, [array]::IndexOf(@($choices | ForEach-Object { $_.Key }), $curKey))
            $pick = Pick-ScrollList 'MENU KEY  --  CHOOSE A KEY' `
                        (Hint '[ {Move}    {A}: choose    {B}: cancel ]') $rows $start
            if ($pick -ge 0) { $chosen = $choices[$pick].Key }
        } else {
            while (-not $chosen) {
                $name = Read-MenuKeyPress
                if (-not $name) { break }
                $lbl = Get-MenuKeyLabel $name
                $warn = if (Test-MenuKeyIsTypingKey $name) {
                    '   WARNING: a typing key opens the menu every time you press it, everywhere'
                } else { '' }
                $c2 = Pick-Option "DETECTED: $lbl$warn" @("Use $lbl", 'That is the wrong key - press again', 'Cancel')
                if ($c2 -eq 0) { $chosen = $name } elseif ($c2 -ne 1) { break }
            }
        }

        # Cancelled anywhere above: put back exactly what was there before,
        # because the release step already switched it off.
        if (-not $chosen) {
            Show-Working 'MENU KEY' 'Restoring the previous key...'
            Set-MenuKey $script:rootDir $curKey | Out-Null
            return
        }

        Show-Working 'MENU KEY' "Setting $(Get-MenuKeyLabel $chosen)..."
        $res = Set-MenuKey $script:rootDir $chosen
        $script:pendingNotice = $res.Message
        if ($res.Ok) { return }
        if ((Pick-Option "MENU KEY  --  $($res.Message)" @('Try another key', 'Leave it')) -ne 0) { return }
    }
}

# The options that live on a sub-page. Kept apart from the SETTINGS switch
# because the sub-page, not the main list, is what dispatches them now.
function Invoke-SettingsAction([string]$key) {
    switch ($key) {
        'NonSteam' {
            $script:nonSteamEnabled = -not $script:nonSteamEnabled
            $settings['NonSteam'] = $script:nonSteamEnabled
            Save-Settings
            try { $script:games = @(Get-SteamLibrary) } catch { $script:games = @() }
            Add-MaProfileTags $games
            Build-Tabs   # rebuild Steam tabs with/without non-Steam apps
        }
        'Recent' {
            $script:recentEnabled = -not $script:recentEnabled
            $settings['Recent'] = $script:recentEnabled
            Save-Settings
            Build-Tabs   # apply or undo the recent-first sorting
        }
        'Playtime' {
            $script:playtimeEnabled = -not $script:playtimeEnabled
            $settings['Playtime'] = $script:playtimeEnabled
            Save-Settings
            # The tag is stamped by Draw-GameLine every frame, so there is
            # no tab to rebuild - the next paint already has it right.
        }
        'SessionTime' {
            $script:sessionTimeOn = -not $script:sessionTimeOn
            $settings['SessionTime'] = $script:sessionTimeOn
            Save-Settings
            # Read by Draw-LandingScreen at the next WELCOME BACK.
        }
        'VideoPlayer' {
            if (-not $script:playerHost) {
                # Nothing to switch to: say what's missing rather than
                # toggle a setting that couldn't be honoured.
                $script:pendingNotice = 'The built-in player uses VLC as its engine. Install VLC (videolan.org) and it appears here.'
            } else {
                $script:builtinPlayer = -not $script:builtinPlayer
                $settings['VideoPlayer'] = if ($script:builtinPlayer) { 'builtin' } else { 'default' }
                Save-Settings
            }
        }
        'PlayerHints' {
            $script:playerHints = -not $script:playerHints
            $settings['PlayerHints'] = $script:playerHints
            Save-Settings
            # Nothing on screen here changes - the next player launch reads it.
        }
        'Subtitles' {
            $script:subtitlesOn = -not $script:subtitlesOn
            $settings['Subtitles'] = $script:subtitlesOn
            Save-Settings
        }
        'WatchedAt' {
            # A steps through the few values that make sense, the way a
            # toggle steps through two - no picker for four numbers.
            $i = [array]::IndexOf($script:watchedPctOpts, $script:watchedPct)
            $script:watchedPct = $script:watchedPctOpts[($i + 1) % $script:watchedPctOpts.Count]
            $settings['WatchedPercent'] = $script:watchedPct
            Save-Settings
            $script:pendingNotice = if ($script:watchedPct -eq 100) {
                'Only a video played right to the end counts as watched.'
            } else {
                "Stopping after $($script:watchedPct)% of a video now counts as a full watch."
            }
        }
        'VideoHist' {
            $script:videoHistEnabled = -not $script:videoHistEnabled
            $settings['VideoHistory'] = $script:videoHistEnabled
            Save-Settings
            Build-Tabs   # rebuild file tabs with/without tags
        }
        'Watching' {
            $script:watchingEnabled = -not $script:watchingEnabled
            $settings['CurrentlyWatching'] = $script:watchingEnabled
            Save-Settings
            Build-Tabs   # apply or undo the CURRENTLY WATCHING section
        }
        'UpNext' {
            $script:upNextEnabled = -not $script:upNextEnabled
            $settings['UpNext'] = $script:upNextEnabled
            Save-Settings
            Build-Tabs   # apply or undo the UP NEXT section
        }
        'VlcInfo' {
            $script:pendingNotice = 'With VLC (videolan.org): fullscreen playback, the menu returns when a video ends, and resume markers work.'
        }
    }
}

# A settings sub-page: looks like Pick-Option, but it stays open after a
# choice and rebuilds its rows each pass, so a toggle shows its new value
# where you are rather than sending you back to SETTINGS to check.
function Show-SettingsGroup([string]$title, [scriptblock]$build) {
    $script:inModal = $true
    $sel = 0
    $script:modalTop = 4; $script:modalOff = 0
    $script:modalHover = 0
    $notice = ''
    Clear-Host
    Get-Layout
    while ($true) {
        $rows = @(& $build)
        if ($rows.Count -eq 0) { return }
        $script:modalRows = $rows.Count; $script:modalCount = $rows.Count
        if ($sel -ge $rows.Count) { $sel = $rows.Count - 1 }
        Write-At 2 0 (Pad $title ($W - 4)) $theme.Accent
        Write-At 2 2 (Hint '[ {Move}    {A}: change    {B}: back ]') $theme.Hint
        for ($i = 0; $i -lt $rows.Count; $i++) {
            if ($i -eq $sel) { Write-At 1 (4 + $i) (Pad ('  >> ' + $rows[$i].Name + '  ') ($W - 3)) $theme.SelFg $theme.Accent }
            else             { Write-At 1 (4 + $i) (Pad ('     ' + $rows[$i].Name + '  ') ($W - 3)) $theme.Text }
        }
        # Padded every pass, so the line blanks itself once the notice has
        # been answered by the next keypress.
        Write-At 2 (5 + $rows.Count) (Pad $notice ($W - 4)) $theme.Notice
        $notice = ''
        switch (Read-InputKey) {
            'UpArrow'    { $sel = ($sel - 1 + $rows.Count) % $rows.Count }
            'DownArrow'  { $sel = ($sel + 1) % $rows.Count }
            'MouseHover' { $sel = $script:modalHover }
            { "$_" -in 'Enter', 'MouseClick' } {
                if ("$_" -eq 'MouseClick') { $sel = $script:modalHover }
                Invoke-SettingsAction $rows[$sel].Key
                # Shown here rather than left for the SETTINGS redraw: the
                # answer belongs with the row that raised it.
                if ($script:pendingNotice) { $notice = $script:pendingNotice; $script:pendingNotice = $null }
            }
            'Escape'    { return }
            'Q'         { return }
        }
    }
}

# ------------------------------------------------------- Item menu ---
# Y on the pad, M (or the keyboard's own Menu key) and right-click all open
# this: what can be done to the row under the cursor. The options are built
# from the row itself, so nothing dead is ever offered - a video with no
# resume position has no "reset position" line at all.
function Show-ItemMenu {
    if ($script:items.Count -eq 0) { return }
    $it = $script:items[$script:selected]
    if (-not $it -or $it.Unselectable) { return }
    # Rows with nothing to offer - a folder, a settings row - do nothing at
    # all. A menu that exists only to say "no options here" is worse than
    # the button appearing to be idle on that row.
    $type = $tabs[$script:tab].Type
    if ($type -in 'Steam', 'Shortcuts')                 { Show-GameMenu $it }
    elseif ($type -eq 'Files' -and $it.Type -eq 'File') { Show-VideoMenu $it }
}

# Watch an install record disappear, which is how an uninstall is known to
# have gone through. $StopOnFocus is for the hidden wait: the menu coming
# back to the front means the user has finished with Steam one way or the
# other, and usually means they cancelled.
function Wait-ForUninstall($manifest, [int]$ms, [bool]$stopOnFocus = $false, [bool]$keepFront = $false,
                          $hideSteamAfter = $null) {
    if (-not $manifest) { return $false }   # never found it: nothing to watch
    $until = [Environment]::TickCount + $ms
    $grabs = 0
    while ([Environment]::TickCount -lt $until) {
        Start-Sleep -Milliseconds 200
        # Whatever Steam has just put on screen goes away again the moment
        # it appears, so it is never left sitting in front of the menu.
        if ($null -ne $hideSteamAfter) { Hide-NewSteamWindows $hideSteamAfter }
        if (-not (Test-Path $manifest)) { return $true }
        # No console handle means we can neither tell where the focus is nor
        # ask for it back - not the same thing as being in the background.
        $haveHwnd = ($script:conHwnd -ne [IntPtr]::Zero)
        $isFront  = ($haveHwnd -and [CLIntFocus.Win]::GetForegroundWindow() -eq $script:conHwnd)
        if ($stopOnFocus -and $isFront) { return $false }
        # Handing Steam a command brings its window up whether or not it has
        # anything to show. Take the front back - the user asked CLInt to do
        # this and should still be looking at CLInt when it finishes. Capped,
        # so a deliberate alt-tab away isn't fought over for the whole wait.
        if ($keepFront -and $haveHwnd -and -not $isFront -and $grabs -lt 5) {
            Show-MenuWindow
            $grabs++
        }
    }
    return $false
}

function Show-GameMenu($g) {
    # Uninstalling is Steam's business: a non-Steam shortcut is just a path
    # Steam was told about, so there is nothing to remove and nothing to
    # say about it - Y is simply inert on those rows.
    if (-not $g.Steam) { return }
    $name = "$([string]$g.Name)".ToUpper()
    $c = Pick-Option $name @('Uninstall this game', 'Return')
    if ($c -ne 0) { Draw-All; return }
    # Our own confirmation, driven by the d-pad like everything else here.
    # It is not a formality: app_uninstall below removes the game outright
    # without asking, so this prompt is the only thing in front of it.
    $sure = Pick-Option "UNINSTALL $name  --  ARE YOU SURE?" @('Yes - uninstall it', 'Cancel')
    if ($sure -ne 0) { Draw-All; return }
    Draw-All
    Show-Notice "Uninstalling $($g.Name)..."
    $manifest = Get-AppManifestPath ([string]$g.AppId)

    # steam://uninstall always raises Steam's own confirmation, which wants a
    # mouse. The client's console command does the same job with no dialog at
    # all, and the client takes console commands as +arguments - so that is
    # the one we ask for, having just done the asking ourselves.
    # -silent asks the client not to put its window up; the topmost pin is
    # what actually guarantees it, since a forwarded command raises Steam
    # regardless. Both, so the common case never even flickers.
    $gone = $false
    $steamBefore = Get-SteamWindows   # anything already open is not ours to touch
    $script:steamHidden = @{}
    Set-MenuTopmost $true
    try {
        $fired = $false
        try {
            $exe = Join-Path (Get-SteamPath) 'steam.exe'
            if (Test-Path $exe) {
                Start-Process $exe -ArgumentList '-silent', '+app_uninstall', ([string]$g.AppId)
                $fired = $true
            }
        } catch {}
        if (-not $fired) { Start-Process "steam://uninstall/$($g.AppId)" }
        # A silent removal lands in a moment, so wait a little with the menu
        # still up and in front. Focus is taken back as well as the z-order:
        # Steam can hold the keyboard from behind, which would leave the menu
        # looking right but ignoring the pad.
        $gone = Wait-ForUninstall $manifest 12000 -keepFront $true -hideSteamAfter $steamBefore
    } finally {
        Set-MenuTopmost $false        # never leave the console pinned over the desktop
        Hide-NewSteamWindows $steamBefore   # and never leave Steam's window behind either
    }
    # Still here: this client wouldn't take the command and has put its own
    # dialog up instead. That one needs answering, so stop covering it and
    # get out of the way. The URL is NOT fired as well - that would be a
    # second prompt stacked on the first.
    if (-not $gone -and $manifest) {
        Restore-HiddenSteamWindows   # whatever it wants answering, put it back on screen
        Hide-MenuWindow
        $gone = Wait-ForUninstall $manifest 180000 -stopOnFocus $true
    }
    Show-MenuWindow   # however it went, the user ends up back here
    try { $script:games = @(Get-SteamLibrary) } catch { $script:games = @() }
    Add-MaProfileTags $games
    $script:steamPlaytime = $null   # an uninstall leaves the playtime behind; re-read anyway
    Build-Tabs
    $script:items = @(Get-TabItems $script:tab)
    $script:selected = [Math]::Min($script:selected, [Math]::Max(0, $script:items.Count - 1))
    Snap-Selection
    Snap-Viewport
    Draw-All
    if ($gone) { Show-Notice "$($g.Name) uninstalled." }
    else       { Show-Notice "$($g.Name) is still installed - the uninstall wasn't finished." }
}

# Stays open after each change so a count can be nudged more than once, and
# rebuilds its own rows every pass to show the new figure in place.
function Show-VideoMenu($v) {
    $path = [string]$v.Path
    $k = $path.ToLower()
    $changed = $false
    while ($true) {
        $plays = 0
        if ($script:watchMap[$k]) { try { $plays = [int]$script:watchMap[$k].Plays } catch {} }
        $resume = 0
        foreach ($e in (Get-ResumeEntries)) {
            if ($e.Path.ToLower() -eq $k) { $resume = [int]$e.Seconds; break }
        }
        $opts = @(); $acts = @()
        # The one-press answer for a half-watched video: "I did watch this."
        # A play recorded as of now plus the partial position cleared - the
        # same pair of writes a watch that ends in the player makes, so the
        # sections react identically: out of CURRENTLY WATCHING, the next
        # episode into UP NEXT. First in the list because on a row wearing
        # a [>>] tag it is the reason the menu was opened.
        if ($resume -gt 0) {
            $opts += 'Mark as completed'; $acts += 'complete'
        }
        $opts += 'Play count + 1'; $acts += 'inc'
        if ($plays -gt 0) {
            $opts += 'Play count - 1';        $acts += 'dec'
            $opts += 'Reset play count to 0'; $acts += 'zero'
        }
        if ($resume -gt 0) {
            $ts = [TimeSpan]::FromSeconds($resume)
            $pos = if ($ts.Hours -gt 0) { $ts.ToString('h\:mm\:ss') } else { $ts.ToString('m\:ss') }
            $opts += "Reset play position  (stopped at $pos)"; $acts += 'pos'
        }
        $opts += 'Return'; $acts += 'done'
        $c = Pick-Option "$([string]$v.Name)  --  played $plays" $opts
        if ($c -lt 0 -or $acts[$c] -eq 'done') { break }
        switch ($acts[$c]) {
            # Record-VideoPlay, not Set-VideoPlays: Last must say NOW, so
            # UP NEXT orders this folder as freshly watched.
            'complete' { Record-VideoPlay $path; Set-Resume $path 0 }
            'inc'  { Set-VideoPlays $path ($plays + 1) }
            'dec'  { Set-VideoPlays $path ($plays - 1) }
            'zero' { Set-VideoPlays $path 0 }
            # 0 seconds is the "watched to the end" tombstone, which is
            # exactly what clearing a position means: it also shadows the
            # stale row VLC may still be holding for this file.
            'pos'  { Set-Resume $path 0 }
        }
        $changed = $true
    }
    if ($changed) {
        # Tags and the CURRENTLY WATCHING section both move: a cleared
        # position drops the video out of that section, shifting every row.
        $t = $tabs[$script:tab]
        $t.Items = @(Get-FileItems $t)
        $script:items = $t.Items
        $script:selected = [Math]::Min($script:selected, [Math]::Max(0, $script:items.Count - 1))
        Snap-Selection
        Snap-Viewport
    }
    Draw-All
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

# The wait for a shortcut that opened something rather than launching a game
# (Track = 'Window'): there is no process to poll, so follow the WINDOW it put
# on screen. Whatever takes the foreground off us within a few seconds is it -
# an Explorer window for a folder, the reader for a document.
#
# CLInt is left where it is rather than minimised: it is fullscreen, so closing
# that window exposes the menu again directly, with no flash of desktop in
# between. Two things end the wait - the window closing, or CLInt being the
# foreground again (the menu hotkey, alt-tab). That second one matters: the
# folder may well stay open, and the user still has to be able to get back into
# the menu. Nothing appearing at all just returns, so a shortcut that opens
# silently doesn't strand the menu either.
function Wait-ForOpenedWindow([int]$appearTimeoutS = 10) {
    $hwnd = [IntPtr]::Zero
    $deadline = [DateTime]::Now.AddSeconds($appearTimeoutS)
    while ([DateTime]::Now -lt $deadline) {
        try {
            $fg = [CLIntFocus.Win]::GetForegroundWindow()
            if ($fg -ne $script:conHwnd -and $fg -ne [IntPtr]::Zero) { $hwnd = $fg; break }
        } catch { break }
        Protect-CoveredMenu   # the idle tick isn't running while we sit here
        Start-Sleep -Milliseconds 250
    }
    if ($hwnd -eq [IntPtr]::Zero) { return }
    while ($true) {
        try {
            if (-not [CLIntFocus.Win]::IsWindow($hwnd)) { break }
            if ([CLIntFocus.Win]::GetForegroundWindow() -eq $script:conHwnd) { break }
        } catch { break }
        # This wait can hold for as long as the opened window stays up - the
        # menu sits exposed behind it the whole time, so keep the scrollbar
        # and minimize-poison defences alive here too.
        Protect-CoveredMenu
        Repair-MenuWindow
        Start-Sleep -Milliseconds 300
    }
}

# The start-detection waits in Wait-ForGameExit used to be deaf: a Steam-side
# failure (logged in on another PC, a declined update prompt, anti-cheat
# trouble) never flips the Running flag, so the user sat trapped on a dead
# LAUNCHING screen for the whole start timeout, then got a WELCOME BACK for a
# game that never ran. Steam offers no launch-failed signal to watch for, so
# the wait is cancellable instead: B / Escape / Q (pad B arrives as Escape via
# Get-PadKey, which keeps its foreground gate - a press aimed at Steam's own
# error dialog is not stolen). Other keys are consumed and dropped; they were
# headed for the post-launch drain anyway.
function Test-LaunchCancelled {
    $cancel = $false
    while ([Console]::KeyAvailable) {
        $k = [Console]::ReadKey($true)
        if ($k.Key -in 'Escape', 'B', 'Q') { $cancel = $true }
    }
    if ((Get-PadKey) -eq [ConsoleKey]::Escape) { $cancel = $true }
    return $cancel
}

# How the launch attempt resolved, for the caller: 'Started' (the game ran -
# land normally), 'Cancelled' (the user backed out) or 'TimedOut' (nothing
# ever started). Script-scoped rather than returned - Wait-ForGameExit's
# callers ignore its pipeline, and keeping it that way means no stray output
# from the loop bodies can ever masquerade as a result.
$script:launchResult = 'Started'

function Wait-ForGameExit($game, [int]$holdTdpW = 0, [int]$startTimeoutS = 90, [scriptblock]$landing = $null) {
    $script:launchResult = 'Started'
    if ($game.Exe) {
        # Non-Steam shortcut: Steam doesn't track these in the registry,
        # so watch the exe's process instead.
        $proc = [System.IO.Path]::GetFileNameWithoutExtension($game.Exe)
        $deadline = [DateTime]::Now.AddSeconds($startTimeoutS)
        $hintAt   = [DateTime]::Now.AddSeconds(10)
        $started  = $false
        while ([DateTime]::Now -lt $deadline) {
            if (Get-Process -Name $proc -ErrorAction SilentlyContinue) { $started = $true; break }
            if (Test-LaunchCancelled) { $script:launchResult = 'Cancelled'; return }
            if ($hintAt -and [DateTime]::Now -ge $hintAt) {
                # a healthy launch never lingers this long, so only now is
                # the escape hatch worth mentioning
                Write-Host ""
                Write-Host "   Taking a while? B goes back to the menu." -ForegroundColor $theme.Hint
                $hintAt = $null
            }
            Protect-CoveredMenu   # the idle tick isn't running while we sit here
            Start-Sleep -Milliseconds 500
        }
        if (-not $started) { $script:launchResult = 'TimedOut'; return }
        $holdUntil = [DateTime]::Now.AddSeconds(45)
        $graceEnd  = [DateTime]::Now.AddSeconds(8)   # let the game claim focus itself first
        $nextTdp   = [DateTime]::Now                 # drift-check cadence stays 2s
        $waitT0    = [DateTime]::Now
        $lastLandMin  = -1
        $gameHadFocus = $false
        $steppedAside = $false
        while (Get-Process -Name $proc -ErrorAction SilentlyContinue) {
            $now = [DateTime]::Now
            if ($now -lt $holdUntil) {
                if ($holdTdpW -and $now -ge $nextTdp) { Assert-Tdp $holdTdpW; $nextTdp = $now.AddSeconds(2) }
                if ($now -ge $graceEnd) {
                    # Once the game has verifiably held the foreground, never
                    # step aside again: on a quick quit the foreground lands
                    # back on CLInt while this loop still thinks the game is
                    # running, and minimising then flashes the desktop.
                    if (-not $gameHadFocus) {
                        try { $gameHadFocus = [CLIntFocus.Win]::GetForegroundWindow() -notin @($script:conHwnd, [IntPtr]::Zero) } catch {}
                    }
                    # Once per launch (see Hide-MenuForGame): a console back
                    # in front after that is the user's doing, not ours to
                    # undo.
                    if (-not $gameHadFocus -and -not $steppedAside) { $steppedAside = Hide-MenuForGame }
                }
            }
            # While the game covers the screen the console is invisible: paint
            # the landing screen onto it NOW (re-painting as the minutes tick
            # so the duration stays current), so the moment the game window
            # closes what Windows exposes is already the landing screen, not
            # the stale launch screen - exit-detection latency stops mattering.
            # Test-MenuCovered, not just foreground-lost: mid-launch a small
            # dialog can hold the foreground with the console still showing.
            if ($landing -and (Test-MenuCovered)) {
                $lm = [int]($now - $waitT0).TotalMinutes
                if ($lm -ne $lastLandMin) {
                    try {
                        & $landing
                        $lastLandMin = $lm
                        $script:landingPainted = $true
                    } catch {}
                }
            }
            Protect-CoveredMenu   # a game changing the display can spawn a bar mid-wait
            Start-Sleep -Milliseconds 500   # short: this poll is also the return-to-menu latency
        }
        return
    }
    # Steam flips this registry value to 1 while the game is running.
    $key = "HKCU:\Software\Valve\Steam\Apps\$($game.AppId)"
    $deadline = [DateTime]::Now.AddSeconds($startTimeoutS)
    $hintAt   = [DateTime]::Now.AddSeconds(10)
    $started  = $false
    while ([DateTime]::Now -lt $deadline) {
        if ((Get-ItemProperty $key -ErrorAction SilentlyContinue).Running -eq 1) { $started = $true; break }
        if (Test-LaunchCancelled) { $script:launchResult = 'Cancelled'; return }
        if ($hintAt -and [DateTime]::Now -ge $hintAt) {
            # a healthy launch never lingers this long, so only now is
            # the escape hatch worth mentioning
            Write-Host ""
            Write-Host "   Taking a while? B goes back to the menu." -ForegroundColor $theme.Hint
            $hintAt = $null
        }
        Protect-CoveredMenu   # the idle tick isn't running while we sit here
        Start-Sleep -Milliseconds 500
    }
    if (-not $started) { $script:launchResult = 'TimedOut'; return }
    $holdUntil = [DateTime]::Now.AddSeconds(45)
    $graceEnd  = [DateTime]::Now.AddSeconds(8)   # let the game claim focus itself first
    $nextTdp   = [DateTime]::Now                 # drift-check cadence stays 2s
    $waitT0    = [DateTime]::Now
    $lastLandMin  = -1
    $gameHadFocus = $false
    $steppedAside = $false
    $gameHwnd  = [IntPtr]::Zero
    while ((Get-ItemProperty $key -ErrorAction SilentlyContinue).Running -eq 1) {
        $now = [DateTime]::Now
        if ($now -lt $holdUntil) {
            if ($holdTdpW -and $now -ge $nextTdp) { Assert-Tdp $holdTdpW; $nextTdp = $now.AddSeconds(2) }
            if ($now -ge $graceEnd) {
                # same quick-quit guard as the exe path above (Steam's Running
                # flag can lag the window closing by several seconds); keep
                # re-sampling the handle inside the hold window so a splash
                # screen handing off to the real game window is tracked
                try {
                    $fg = [CLIntFocus.Win]::GetForegroundWindow()
                    if ($fg -notin @($script:conHwnd, [IntPtr]::Zero)) {
                        $gameHadFocus = $true
                        $gameHwnd     = $fg
                    }
                } catch {}
                # Once per launch (see Hide-MenuForGame): a console back in
                # front after that is the user's doing, not ours to undo.
                if (-not $gameHadFocus -and -not $steppedAside) { $steppedAside = Hide-MenuForGame }
            }
        }
        # Pre-paint the landing screen onto the covered console while the game
        # holds the screen (same reasoning as the exe path above): whatever is
        # painted here is what the closing game window exposes.
        if ($landing -and (Test-MenuCovered)) {
            $lm = [int]($now - $waitT0).TotalMinutes
            if ($lm -ne $lastLandMin) {
                try {
                    & $landing
                    $lastLandMin = $lm
                    $script:landingPainted = $true
                } catch {}
            }
        }
        # Steam's Running flag lags the window closing, which parked the
        # user on the stale launch screen for seconds. The window we saw
        # holding the foreground IS the game: once it's been destroyed and
        # the foreground is back on CLInt, the game is over - don't wait
        # for the flag. (Summoning CLInt over a live game via the hotkey
        # can't trip this: the game's window still exists then.)
        if ($gameHwnd -ne [IntPtr]::Zero) {
            try {
                if (-not [CLIntFocus.Win]::IsWindow($gameHwnd) -and
                    [CLIntFocus.Win]::GetForegroundWindow() -eq $script:conHwnd) { break }
            } catch {}
        }
        Protect-CoveredMenu   # a game changing the display can spawn a bar mid-wait
        Start-Sleep -Milliseconds 500   # short: this poll is also the return-to-menu latency
    }
}

# Wheel scrolling: move the VIEWPORT, the way dragging a scrollbar does,
# leaving the cursor to follow the pointer. Every other navigation moves the
# cursor and lets the viewport chase it; this is the one that works the
# other way round, because a wheel scrolls a page - it doesn't pick things.
function Scroll-List([int]$rows) {
    if ($script:items.Count -eq 0) { return }
    $maxOff = [Math]::Max(0, $script:items.Count - $script:visible)
    $new = [Math]::Min([Math]::Max(0, $script:offset + $rows), $maxOff)
    if ($new -eq $script:offset) { return }   # already at the end: nothing to repaint
    Clear-Notice
    $script:offset = $new
    # The pointer sat still while the list moved underneath it, so the
    # highlight goes to whatever is under it now - the same rule hover
    # already follows, which is what stops the two fighting.
    $i = $script:wheelY - $script:listTop + $script:offset
    if ($script:wheelY -ge $script:listTop -and $script:wheelY -lt $script:listTop + $script:visible -and
        $i -lt $script:items.Count -and -not $script:items[$i].Unselectable) {
        $script:selected = $i
    } else {
        # Pointer off the list, or on a section title: keep the cursor where
        # it was, but never let it scroll off the screen - A has to launch
        # something the user can still see.
        if ($script:selected -lt $script:offset) { $script:selected = $script:offset }
        elseif ($script:selected -ge $script:offset + $script:visible) {
            $script:selected = $script:offset + $script:visible - 1
        }
        Snap-Selection
    }
    Draw-List
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
    try { (New-Object -ComObject WScript.Shell).AppActivate($PID) | Out-Null } catch {}
    Set-ConsoleFullscreen   # always: launching CLInt means fullscreen
    Set-ThemeColors         # before the first Draw-All: its Clear-Host lays down the background
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
            # Three rows a notch, Windows' own wheel default, and never more
            # than a screenful however hard it was flicked.
            'ScrollUp'   { Scroll-List (-[Math]::Min($visible, 3 * $script:wheelSteps)) }
            'ScrollDown' { Scroll-List ([Math]::Min($visible, 3 * $script:wheelSteps)) }
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
                        'GameSettings'  { Show-SettingsGroup 'GAME SETTINGS'  { Get-GameSettingsItems } }
                        'VideoSettings' { Show-SettingsGroup 'VIDEO SETTINGS' { Get-VideoSettingsItems } }
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
                                        # Resume positions are video history too:
                                        # leaving them behind would empty the play
                                        # counts and keep CURRENTLY WATCHING full.
                                        $script:resumeMap = @{}
                                        Remove-Item $script:resumeFile -Force -ErrorAction SilentlyContinue
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
                        'AutoCheck' {
                            $script:autoCheck = -not $script:autoCheck
                            $settings['AutoUpdateCheck'] = $script:autoCheck
                            Save-Settings
                        }
                        'AutoStart' {
                            # The registry entry is the state: flip it there
                            # first, and only show the row changed if Windows
                            # took the write.
                            try {
                                if ($script:autoStart) { Unregister-AutoStart } else { Register-AutoStart }
                                $script:autoStart = -not $script:autoStart
                            } catch {
                                $script:pendingNotice = 'Windows would not save the startup entry'
                            }
                        }
                        'Mouse' {
                            $script:mouseEnabled = -not $script:mouseEnabled
                            $settings['Mouse'] = $script:mouseEnabled
                            Save-Settings
                            Set-MouseMode $script:mouseEnabled
                        }
                        'HoverTabs' {
                            $script:hoverTabs = -not $script:hoverTabs
                            $settings['HoverTabs'] = $script:hoverTabs
                            Save-Settings
                        }
                        'ButtonHints' {
                            # Two values, so A flips it - no picker needed. The
                            # Draw-All this branch ends with repaints the hint
                            # row in the new words.
                            $script:controlHints = if ($script:controlHints -eq 'gamepad') { 'keyboard' } else { 'gamepad' }
                            $settings['ButtonHints'] = $script:controlHints
                            Save-Settings
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
                        'MenuKey' { Configure-MenuKey }
                        'Theme'  {
                            $names = @($themes.Keys)
                            $c = Pick-Option 'COLOR THEME' ($names + @('Cancel'))
                            if ($c -ge 0 -and $c -lt $names.Count) {
                                $script:themeName = $names[$c]
                                $script:theme     = $themes[$script:themeName]
                                $settings['Theme'] = $script:themeName
                                Save-Settings
                                # the Draw-All this branch ends with clears the
                                # screen, which is what lays the new background
                                Set-ThemeColors
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
                    if ($v.Unselectable) { break }   # section row: nothing to open
                    if ($v.Type -eq 'Dir') { Enter-FileDir $cur $v.Path; break }
                    if ($v.Type -eq 'Up')  { Exit-FileDir $cur | Out-Null; break }
                    $isVideo = [System.IO.Path]::GetExtension($v.Path) -match $videoExtRe
                    Clear-Host
                    Write-Host ""
                    Write-Host "     _____" -ForegroundColor $theme.Accent
                    Write-Host "    | |>  |    NOW PLAYING" -ForegroundColor $theme.Accent
                    Write-Host "    |_|___|    $($v.Name)" -ForegroundColor $theme.Logo
                    Write-Host ""
                    $landedAt = $null
                    if ($isVideo -and $script:builtinPlayer -and $script:playerHost) {
                        # Our own player, in its own process (see Player.ps1 for
                        # why it cannot be this one). We hold a real handle to
                        # it, so unlike the VLC path there is no process-name
                        # guessing and no start-up timeout to get wrong.
                        $stateFile = Join-Path $script:dataDir 'player-state.json'
                        Remove-Item $stateFile -Force -ErrorAction SilentlyContinue
                        # The player announces its window in player.hwnd for
                        # the menu key (see CLIntKey.ahk) and removes it on
                        # exit - but a hard crash removes nothing, so it is
                        # swept on both sides of every run.
                        $playerHwnd = Join-Path $script:dataDir 'player.hwnd'
                        Remove-Item $playerHwnd -Force -ErrorAction SilentlyContinue
                        $pargs = @(
                            '-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden'
                            '-File',      "`"$(Join-Path $PSScriptRoot 'Player.ps1')`""
                            '-Video',     "`"$($v.Path)`""
                            '-VlcDir',    "`"$script:vlcDir`""
                            '-StateFile', "`"$stateFile`""
                            # The look travels with the file: the same
                            # colours this console is showing, at the same
                            # text size, so the overlay is not visibly a
                            # different program from the menu behind it.
                            '-Theme',     (Get-ThemeRgbArg)
                            '-TextPx',    [string]$textSizes[$script:textSizeName]
                            '-Controls',  $script:controlHints
                            '-WatchedPct', [string]$script:watchedPct
                        )
                        if (-not $script:playerHints) { $pargs += '-NoHints' }
                        if ($script:subtitlesOn)      { $pargs += '-Subtitles' }
                        # Start-Process does not quote list items for you, so
                        # every path above carries its own quotes - without them
                        # "Program Files (x86)" arrives as three arguments.
                        if ($v.Resume -and ($script:videoHistEnabled -or $v.Watching)) {
                            $pargs += @('-Start', [string][int]$v.Resume)
                        }
                        $proc = $null
                        try {
                            $proc = Start-Process $script:playerHost -ArgumentList $pargs -PassThru -WindowStyle Hidden
                        } catch {}
                        if (-not $proc) {
                            Show-MenuWindow
                            $script:pendingNotice = 'The built-in player would not start. SETTINGS -> Video settings can switch back to the default app.'
                        } else {
                            $script:landingPainted = $false
                            $wrapSb = { Draw-WrapScreen $v.Name }.GetNewClosure()
                            $wt0 = [DateTime]::Now
                            $lastLand = -1
                            $pwnd     = [IntPtr]::Zero   # the player's window, once announced
                            $conWasIc = $false           # console iconic on the previous tick
                            while (-not $proc.HasExited) {
                                # Same pre-paint trick the game path uses: while
                                # the player covers the console, paint the wrap
                                # screen onto it NOW, so the instant the player
                                # window goes the screen behind it is already
                                # right instead of showing a stale NOW PLAYING.
                                if (Test-MenuCovered) {
                                    $lm = [int]([DateTime]::Now - $wt0).TotalMinutes
                                    if ($lm -ne $lastLand) {
                                        try { & $wrapSb; $lastLand = $lm; $script:landingPainted = $true } catch {}
                                    }
                                }
                                # The menu key puts the player and this console
                                # away together, and the player keeps itself out
                                # of the taskbar - so the one button left down
                                # there is the console's, and clicking it must
                                # bring the FILM back. Two problems stand in the
                                # way: conhost eats a taskbar restore taken while
                                # its fullscreen mode is on (see Repair-MenuWindow,
                                # whose idle-tick self-heal is not running - this
                                # loop is where the script is), and restoring the
                                # console alone would only expose a deaf wrap
                                # screen. So run the repair here too, and treat
                                # the console coming back from minimized - which
                                # mid-film can only be the user at the taskbar -
                                # as the ask to hand the screen to the player.
                                try {
                                    Protect-CoveredMenu   # scrollbar defences, idle tick not running
                                    Repair-MenuWindow
                                    $conIc = [CLIntFocus.Win]::IsIconic($script:conHwnd)
                                    if ($conWasIc -and -not $conIc) {
                                        if ($pwnd -eq [IntPtr]::Zero -and (Test-Path $playerHwnd)) {
                                            $pwnd = [IntPtr][int64]((Get-Content $playerHwnd -Raw).Trim())
                                        }
                                        if ($pwnd -ne [IntPtr]::Zero -and [CLIntFocus.Win]::IsWindow($pwnd)) {
                                            if ([CLIntFocus.Win]::IsIconic($pwnd)) {
                                                [CLIntFocus.Win]::ShowWindow($pwnd, 9) | Out-Null   # SW_RESTORE
                                            }
                                            [CLIntFocus.Win]::SetForegroundWindow($pwnd) | Out-Null
                                        }
                                    }
                                    $conWasIc = $conIc
                                } catch {}
                                Start-Sleep -Milliseconds 300
                            }
                            Remove-Item $playerHwnd -Force -ErrorAction SilentlyContinue
                            Show-MenuWindow
                            # One run can cover several files (LB/RB walks the
                            # folder), so every row it reports is folded back in,
                            # not just the one that was launched.
                            $rows = @()
                            try {
                                if (Test-Path $stateFile) {
                                    $rows = @((Get-Content $stateFile -Raw | ConvertFrom-Json).Results)
                                }
                            } catch {}
                            $finished = $true
                            $lastRow  = $null
                            foreach ($r in $rows) {
                                if (-not $r -or -not $r.Path) { continue }
                                Set-Resume $r.Path ([int]$r.Seconds) ([string]$r.Last)
                                if ($r.Finished -and $script:videoHistEnabled) { Record-VideoPlay $r.Path }
                                if (-not $lastRow) { $lastRow = $r }
                                else {
                                    try { if ([DateTime]$r.Last -gt [DateTime]$lastRow.Last) { $lastRow = $r } } catch {}
                                }
                            }
                            # The wrap screen names whatever they stopped on,
                            # which after an LB/RB walk is not what they picked.
                            $wrapName = $v.Name
                            if ($lastRow) {
                                $finished = [bool]$lastRow.Finished
                                if ($lastRow.Path -ne $v.Path) {
                                    $wrapName = [System.IO.Path]::GetFileName([string]$lastRow.Path)
                                }
                            } elseif ($proc.ExitCode -ne 0) {
                                # Died before it recorded anything: don't claim a
                                # watch, and don't leave the user wondering.
                                $finished = $false
                                $script:pendingNotice = 'The built-in player stopped unexpectedly. SETTINGS -> Video settings can switch back to the default app.'
                            }
                            if (-not $finished -or -not $script:landingPainted -or $wrapName -ne $v.Name) {
                                Draw-WrapScreen $wrapName $finished
                            }
                            $landedAt = [DateTime]::Now
                        }
                    } elseif ($isVideo -and $vlcExe) {
                        # Resume explicitly: VLC's own continue-playback prompt
                        # is a mouse-only toast that vanishes after ~10s, so a
                        # gamepad user misses it and starts over. The [>>] tag
                        # already knows the position - hand it to VLC directly.
                        $vlcArgs = @('--fullscreen', '--play-and-exit')
                        if ($v.Resume -and ($script:videoHistEnabled -or $v.Watching)) { $vlcArgs += "--start-time=$([int]$v.Resume)" }
                        $vlcArgs += "`"$($v.Path)`""
                        Start-Process $vlcExe -ArgumentList $vlcArgs
                        $script:landingPainted = $false
                        $wrapSb = { Draw-WrapScreen $v.Name }.GetNewClosure()
                        Wait-ForGameExit ([pscustomobject]@{ Exe = 'vlc.exe' }) 0 90 $wrapSb
                        # VLC is gone: get back on screen before the resume-tag
                        # refresh below so the desktop never shows through
                        Show-MenuWindow
                        # VLC clears its saved position on completion, so a
                        # leftover position means the user bailed partway.
                        $vlcSecs  = (Get-VlcResumeSeconds)[$v.Path.ToLower()]
                        $finished = -not $vlcSecs
                        # Keep our own store level with VLC's. Skipping this
                        # would let a position written by the built-in player
                        # outlive the watch that VLC has just completed, and
                        # the video would sit in CURRENTLY WATCHING for good.
                        Set-Resume $v.Path $(if ($finished) { 0 } else { [int]$vlcSecs })
                        # Repaint unless the pre-paint behind VLC already said
                        # the right thing: while the video played there was no
                        # saved position to read, so that one always assumed a
                        # full watch. Also covers the rare run where VLC never
                        # took the screen and nothing was pre-painted at all.
                        if (-not $finished -or -not $script:landingPainted) {
                            Draw-WrapScreen $v.Name $finished
                        }
                        $landedAt = [DateTime]::Now
                        # A launch is not a watch: only count a play once the
                        # video reaches the end - resuming later isn't another play.
                        if ($script:videoHistEnabled -and $finished) { Record-VideoPlay $v.Path }
                    } else {
                        # No VLC = no exit signal and no resume state: the old
                        # count-on-launch is the best available.
                        if ($script:videoHistEnabled -and $isVideo) { Record-VideoPlay $v.Path }
                        Start-Process $v.Path   # default app for this file type
                        Start-Sleep -Seconds 5
                        Show-MenuWindow
                    }
                    if ($script:videoHistEnabled -or $script:watchingEnabled) {
                        # refresh tags and the CURRENTLY WATCHING section: VLC
                        # has just written (or cleared) its resume state
                        $keep = $selected
                        $cur.Items = @(Get-FileItems $cur)
                        $script:items = $cur.Items
                        $script:selected = [Math]::Min($keep, [Math]::Max(0, $items.Count - 1))
                        Snap-Selection   # a finished video leaves the section, shifting every row under it
                    }
                    if ($landedAt) {
                        $left = 1500 - ([DateTime]::Now - $landedAt).TotalMilliseconds
                        if ($left -gt 0) { Start-Sleep -Milliseconds $left }
                    }
                    while ([Console]::KeyAvailable) { [Console]::ReadKey($true) | Out-Null }
                    Draw-All
                    break
                }
                $g = $items[$selected]
                if ($g.Unselectable) { break }   # section row: nothing to launch
                # A shortcut to a folder or a document is opened, not played:
                # it says so, and it comes back to the menu rather than to a
                # WELCOME BACK screen with a time played on it.
                $opening = ($g.Track -eq 'Window')
                Clear-Host
                Write-Host ""
                Write-Host "      _" -ForegroundColor $theme.Accent
                Write-Host "     /^\      $(if ($opening) { 'OPENING' } else { 'LAUNCHING' })" -ForegroundColor $theme.Accent
                Write-Host "    |___|" -ForegroundColor $theme.Accent
                Write-Host "    |   |     $($g.Name)" -ForegroundColor $theme.Logo
                Write-Host "    |___|" -ForegroundColor $theme.Accent
                Write-Host "   /|   |\    $(if ($opening) { 'close it to come back' } else { 'GLHF o7' })" -ForegroundColor $theme.Info
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
                $script:landingPainted = $false
                $script:launchResult   = 'Started'   # opened windows have no start to fail
                if ($opening) {
                    # No process to watch: follow the window it opened, and
                    # return the moment it closes or the user comes back to us.
                    Wait-ForOpenedWindow
                } else {
                    # GetNewClosure pins $g/$t0 to their values here - the block
                    # runs inside Wait-ForGameExit, and dynamic scoping must not
                    # pick up any same-named local there.
                    $landSb = { Draw-LandingScreen $g $t0 }.GetNewClosure()
                    Wait-ForGameExit $g $(if ($prevTdp) { $tdpWatts } else { 0 }) $(if ($steamCold) { 240 } else { 90 }) $landSb
                }
                # The game is gone: get back on screen BEFORE the TDP revert
                # and re-sorting below so the desktop never shows through.
                Show-MenuWindow
                # Normally the landing screen was pre-painted while we sat
                # hidden behind the game, so closing it exposed the screen
                # directly - repainting now would only flicker. Paint here
                # only if the game never took the screen (e.g. died at launch).
                # An opened folder gets no landing screen at all - straight
                # back to the live menu, which is what the user wants there.
                # Neither does a launch that never became a game: WELCOME
                # BACK with "played for 0m" would just rub it in.
                $landedAt = $null
                if (-not $opening -and $script:launchResult -eq 'Started') {
                    if (-not $script:landingPainted) { Draw-LandingScreen $g $t0 }
                    $landedAt = [DateTime]::Now
                }
                if ($prevTdp) { Set-Tdp $prevTdp.Stapm $prevTdp.Fast $prevTdp.Slow }
                # Steam has just written a fresh playtime for this game (or
                # is about to), so the cached figures are stale.
                $script:steamPlaytime = $null
                if ($script:recentEnabled -and $script:launchResult -eq 'Started') {
                    Record-Play $g
                    # bubble the just-played game to the top of every game tab
                    foreach ($gt in $tabs) {
                        if ($gt.Type -in 'Steam', 'Shortcuts') { $gt.Items = @(Sort-Games $gt.Items) }
                    }
                    $script:items    = $cur.Items
                    $script:selected = [Math]::Max(0, [array]::IndexOf($cur.Items, $g))
                    Snap-Selection
                    $script:offset   = 0
                }
                $script:batteryNext = 0   # TDP was restored: refresh the corner readout promptly
                # let the landing screen land - flashing past it reads as a
                # glitch - then drop keys pressed meanwhile and redraw
                if ($landedAt) {
                    $left = 1500 - ([DateTime]::Now - $landedAt).TotalMilliseconds
                    if ($left -gt 0) { Start-Sleep -Milliseconds $left }
                }
                while ([Console]::KeyAvailable) { [Console]::ReadKey($true) | Out-Null }
                Draw-All
                # A cancelled launch needs no announcement - the user did it.
                # A silent timeout would look like CLInt shrugged for no reason.
                if ($script:launchResult -eq 'TimedOut') {
                    Show-Notice 'The game never started - Steam or its launcher may be showing an error.'
                }
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
            # Y on the pad arrives as M; 'MenuKey' is a right-click, and
            # Applications is the keyboard's own context-menu key.
            { "$_" -in 'M', 'Applications', 'MenuKey' } { Show-ItemMenu }
            'Escape'    {   # in a file-tab subfolder: go up a level; otherwise quit
                if ($cur.Type -eq 'Files' -and (Exit-FileDir $cur)) { break }
                if (Confirm-Quit) { Clear-Host; exit 0 }
                Draw-All   # the prompt cleared the screen; put the menu back
            }
            'Q'         {
                if (Confirm-Quit) { Clear-Host; exit 0 }
                Draw-All
            }
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
    # hand the console back the colours it had (a dev shell keeps its own
    # look; the app's own window is closing anyway)
    try {
        Set-ConsolePaletteTable $script:origPalette   # undo any theme palette
        if ($null -ne $script:origBg) { $Host.UI.RawUI.BackgroundColor = $script:origBg }
        if ($null -ne $script:origFg) { $Host.UI.RawUI.ForegroundColor = $script:origFg }
    } catch {}
}
