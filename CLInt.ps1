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
            if ([Win32.Native]::GetForegroundWindow() -eq $hwnd) {
                [Win32.Native]::ShowWindow($hwnd, 6) | Out-Null                  # SW_MINIMIZE
            } elseif ([Win32.Native]::IsIconic($hwnd)) {
                [Win32.Native]::ShowWindow($hwnd, 9) | Out-Null                  # SW_RESTORE
                [Win32.Native]::SetForegroundWindow($hwnd) | Out-Null
            } else {
                [Win32.Native]::SetForegroundWindow($hwnd) | Out-Null
            }
        }
        exit 0
    }
}

$Host.UI.RawUI.WindowTitle = 'CLInt'   # matched by Launch.ps1, CLIntKey.ahk and claude-gamepad.ahk

# App version: version.txt ships with the code and is bumped on every
# update, so the in-app corner display and the updater can compare.
$appVersion = try { (Get-Content (Join-Path $PSScriptRoot 'version.txt') -TotalCount 1).Trim() } catch { '?' }

# ------------------------------------------------------------- Steam ---
function Get-SteamPath {
    $p = (Get-ItemProperty "HKCU:\Software\Valve\Steam" -ErrorAction SilentlyContinue).SteamPath
    if (-not $p) { $p = (Get-ItemProperty "HKLM:\SOFTWARE\WOW6432Node\Valve\Steam" -ErrorAction SilentlyContinue).InstallPath }
    if (-not $p) { throw "Steam installation not found in the registry." }
    return $p -replace '/', '\'
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

function Get-NonSteamGames {
    # Non-Steam shortcuts live in a binary VDF: userdata\<account>\config\shortcuts.vdf.
    # steam://rungameid/ needs the 64-bit shortcut id: (appid << 32) | 0x02000000.
    $steam = Get-SteamPath
    $found = foreach ($vdf in (Get-ChildItem (Join-Path $steam 'userdata\*\config\shortcuts.vdf') -ErrorAction SilentlyContinue)) {
        $raw = [System.Text.Encoding]::GetEncoding(28591).GetString([System.IO.File]::ReadAllBytes($vdf.FullName))
        foreach ($entry in ($raw -split "\x08\x08")) {
            $name = [regex]::Match($entry, "(?i)\x01appname\x00([^\x00]*)\x00").Groups[1].Value
            $idm  = [regex]::Match($entry, "(?is)\x02appid\x00(.{4})")
            if (-not $name -or -not $idm.Success) { continue }   # pre-2019 entries have no appid field
            $idBytes = [byte[]]($idm.Groups[1].Value.ToCharArray() | ForEach-Object { [byte]$_ })
            $appid = [BitConverter]::ToUInt32($idBytes, 0)
            $exe = [regex]::Match($entry, "(?i)\x01exe\x00([^\x00]*)\x00").Groups[1].Value -replace '"', ''
            [pscustomobject]@{
                Name     = $name
                AppId    = $appid
                LaunchId = ([uint64]$appid -shl 32) -bor 0x02000000
                Exe      = $exe
                Dir      = $null
            }
        }
    }
    return @($found | Sort-Object Name)
}

# ----------------------------------------------------------- Settings ---
# settings.json holds the tab configuration: an array of
#   { "Type": "Steam" }                          - the Steam library
#   { "Type": "Shortcuts", "Path": "..." }       - .lnk shortcuts in a folder
#   { "Type": "Files",     "Path": "..." }       - file browser (videos via VLC)
# in display order; a SETTINGS tab is always appended. Optional per-tab
# fields (both settable in-app): "Name" overrides the auto-derived title,
# "Icon" picks a mascot from the catalog. A top-level "Theme" selects the
# color theme.
$settingsFile = Join-Path $PSScriptRoot 'settings.json'
$settings = @{}
if (Test-Path $settingsFile) {
    (Get-Content $settingsFile -Raw | ConvertFrom-Json).PSObject.Properties |
        ForEach-Object { $settings[$_.Name] = $_.Value }
}
if (-not $settings.ContainsKey('Tabs')) {
    # First run - or migration from the fixed-tab era's two folder keys.
    # (Key-existence check, not truthiness: an empty Tabs array is a valid
    # deliberate config - all tabs removed - and must not resurrect defaults.)
    $shortcutDir = if ($settings['LocalShortcutDir']) { $settings['LocalShortcutDir'] }
                   else { Join-Path ([Environment]::GetFolderPath('Desktop')) 'Game Shortcuts' }
    $filesDir    = if ($settings['VideoRoot']) { $settings['VideoRoot'] }
                   else { [Environment]::GetFolderPath('MyVideos') }
    $settings['Tabs'] = @(
        @{ Type = 'Steam' }
        @{ Type = 'Shortcuts'; Path = $shortcutDir }
        @{ Type = 'Files';     Path = $filesDir }
    )
}
$settings.Remove('LocalShortcutDir'); $settings.Remove('VideoRoot')
# JSON round-trips tab entries as PSCustomObjects; normalize to hashtables.
$settings['Tabs'] = @($settings['Tabs'] | ForEach-Object {
    if ($_ -is [hashtable]) { $_ }
    else { $t = @{}; $_.PSObject.Properties | ForEach-Object { $t[$_.Name] = $_.Value }; $t }
})

function Save-Settings {
    $settings | ConvertTo-Json -Depth 5 | Set-Content $settingsFile -Encoding utf8
}

# The Steam library is only scanned when a Steam tab is configured (or for
# -List); machines without Steam just don't get Steam tabs.
$games = @()
$needSteam = $List -or @($settings['Tabs'] | Where-Object { $_.Type -eq 'Steam' }).Count -gt 0
if ($needSteam) {
    try { $games = @(@(Get-InstalledGames) + @(Get-NonSteamGames) | Sort-Object Name) } catch {}
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
$tdpFile    = Join-Path $PSScriptRoot 'tdp-settings.json'
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
[DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
public static extern bool GetCurrentConsoleFontEx(IntPtr hOut, bool max, ref CONSOLE_FONT_INFOEX info);
[DllImport("kernel32.dll", SetLastError = true)]
public static extern bool SetConsoleDisplayMode(IntPtr hOut, uint flags, out int coords);
[DllImport("kernel32.dll")] public static extern bool GetConsoleDisplayMode(out uint mode);
[DllImport("kernel32.dll")] public static extern IntPtr GetConsoleWindow();
[DllImport("user32.dll")] public static extern int GetWindowLong(IntPtr h, int idx);
[DllImport("user32.dll")] public static extern int SetWindowLong(IntPtr h, int idx, int val);
[DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr h, IntPtr after, int x, int y, int cx, int cy, uint flags);
[DllImport("user32.dll")] public static extern int GetSystemMetrics(int i);
[StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left; public int Top; public int Right; public int Bottom; }
[DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
[DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
[DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
[DllImport("user32.dll")] public static extern void keybd_event(byte vk, byte scan, uint flags, UIntPtr extra);
[DllImport("user32.dll")] public static extern bool PostMessage(IntPtr h, uint msg, IntPtr wp, IntPtr lp);
'@
} catch {}

# Poll for conhost's fullscreen mode to engage - the toggle is not
# instantaneous, especially via the message path.
function Wait-FullscreenMode([int]$timeoutMs) {
    $deadline = [Environment]::TickCount + $timeoutMs
    do {
        $m = 0
        if ([CLI.Native]::GetConsoleDisplayMode([ref]$m) -and $m -ne 0) { return $true }
        Start-Sleep -Milliseconds 100
    } while ([Environment]::TickCount -lt $deadline)
    return $false
}

# One font size per device, decided once and used in BOTH windowed and
# fullscreen so the text never changes size between modes. Chosen as the
# largest Consolas whose measured cells divide the panel closest to
# exactly (1920x1080 fits 24px cells at 160x45; 1280x720 fits 20px at
# 128x36) - a perfectly-divided grid also leaves no uncovered strips for
# the manual fullscreen fallback.
$script:conFontSize = 0
function Set-ConsoleFont {
    try {
        $out = [CLI.Native]::GetStdHandle(-11)
        $font = New-Object CLI.Native+CONSOLE_FONT_INFOEX
        $font.cbSize = [System.Runtime.InteropServices.Marshal]::SizeOf($font)
        $font.FontFamily = 54; $font.FontWeight = 400
        $font.FaceName = 'Consolas'
        if (-not $script:conFontSize) {
            $sw = [CLI.Native]::GetSystemMetrics(0)
            $sh = [CLI.Native]::GetSystemMetrics(1)
            $best = 28
            $bestScore = [int]::MaxValue
            foreach ($fs in 28, 26, 24, 22, 20, 18, 16) {
                $font.SizeX = 0; $font.SizeY = $fs
                [CLI.Native]::SetCurrentConsoleFontEx($out, $false, [ref]$font) | Out-Null
                $cur = New-Object CLI.Native+CONSOLE_FONT_INFOEX
                $cur.cbSize = [System.Runtime.InteropServices.Marshal]::SizeOf($cur)
                if (-not [CLI.Native]::GetCurrentConsoleFontEx($out, $false, [ref]$cur) -or $cur.SizeX -le 0) { continue }
                $score = [Math]::Max($sw % $cur.SizeX, $sh % $cur.SizeY)
                if ($score -lt $bestScore) { $bestScore = $score; $best = $fs }
                if ($score -le 2) { break }   # candidates run largest-first: first great fit wins
            }
            $script:conFontSize = $best
        }
        $font.SizeX = 0; $font.SizeY = $script:conFontSize
        [CLI.Native]::SetCurrentConsoleFontEx($out, $false, [ref]$font) | Out-Null
    } catch {}
}

function Set-ConsoleFullscreen {
    try {
        $out = [CLI.Native]::GetStdHandle(-11)
        Set-ConsoleFont

        # Rung 1: the direct API behind Alt+Enter. Works on some devices
        # (the 1080p GPD), refused on others (a 720p machine) even though
        # conhost's own Alt+Enter works fine there.
        $coords = 0
        [CLI.Native]::SetConsoleDisplayMode($out, 1, [ref]$coords) | Out-Null
        $native = Wait-FullscreenMode 600
        $hwnd = [CLI.Native]::GetConsoleWindow()

        # Rung 2: Alt+Enter as a window message, posted straight to the
        # console window - the same toggle the physical keys trigger, no
        # focus required and nothing to leak into other apps.
        if (-not $native) {
            [CLI.Native]::PostMessage($hwnd, 0x0104, [IntPtr]0x0D, [IntPtr][int64]0x20000001) | Out-Null   # WM_SYSKEYDOWN Enter, Alt held
            [CLI.Native]::PostMessage($hwnd, 0x0105, [IntPtr]0x0D, [IntPtr][int64]0xE0000001) | Out-Null   # WM_SYSKEYUP
            $native = Wait-FullscreenMode 1200
        }

        # Rung 3: synthesized keystrokes, only into our own focused window.
        if (-not $native) {
            [CLI.Native]::SetForegroundWindow($hwnd) | Out-Null
            Start-Sleep -Milliseconds 150
            if ([CLI.Native]::GetForegroundWindow() -eq $hwnd) {
                [CLI.Native]::keybd_event(0x12, 0, 0, [UIntPtr]::Zero)   # Alt down
                [CLI.Native]::keybd_event(0x0D, 0, 0, [UIntPtr]::Zero)   # Enter down
                [CLI.Native]::keybd_event(0x0D, 0, 2, [UIntPtr]::Zero)   # Enter up
                [CLI.Native]::keybd_event(0x12, 0, 2, [UIntPtr]::Zero)   # Alt up
                $native = Wait-FullscreenMode 1200
            }
        }

        # Rung 4: force it by hand - strip the frame, grow the grid to what
        # fits (the panel-fit font means it divides the screen exactly or
        # nearly so), stretch the window, and pin it back to the origin
        # after conhost's cell-snap has settled.
        if (-not $native) {
            $style = [CLI.Native]::GetWindowLong($hwnd, -16)
            $style = $style -band (-bnot 0x00CF0000)   # caption, frame, sysmenu, min/max
            [CLI.Native]::SetWindowLong($hwnd, -16, $style) | Out-Null
            try {
                $maxW = [Console]::LargestWindowWidth
                $maxH = [Console]::LargestWindowHeight
                $Host.UI.RawUI.BufferSize = New-Object System.Management.Automation.Host.Size($maxW, $maxH)
                $Host.UI.RawUI.WindowSize = New-Object System.Management.Automation.Host.Size($maxW, $maxH)
            } catch {}
            $sw = [CLI.Native]::GetSystemMetrics(0)
            $sh = [CLI.Native]::GetSystemMetrics(1)
            # 0x0020 FRAMECHANGED | 0x0040 SHOWWINDOW
            [CLI.Native]::SetWindowPos($hwnd, [IntPtr]::Zero, 0, 0, $sw, $sh, 0x0060) | Out-Null
            Start-Sleep -Milliseconds 150
            # conhost may have re-snapped the size; force the position again
            # (0x0001 SWP_NOSIZE | 0x0010 SWP_NOACTIVATE)
            [CLI.Native]::SetWindowPos($hwnd, [IntPtr]::Zero, 0, 0, 0, 0, 0x0071) | Out-Null
        }

        # buffer == window so there are no scrollbars
        $ws = $Host.UI.RawUI.WindowSize
        $Host.UI.RawUI.BufferSize = New-Object System.Management.Automation.Host.Size($ws.Width, $ws.Height)

        # Still not covering the screen? Leave a breadcrumb for debugging.
        if (-not (Test-ConsoleFullscreen)) {
            try {
                $r = New-Object CLI.Native+RECT
                [CLI.Native]::GetWindowRect($hwnd, [ref]$r) | Out-Null
                $m2 = 0; [CLI.Native]::GetConsoleDisplayMode([ref]$m2) | Out-Null
                "$(Get-Date -Format s)  fullscreen incomplete: mode=$m2 native=$native font=$($script:conFontSize) rect=$($r.Left),$($r.Top),$($r.Right),$($r.Bottom) screen=$([CLI.Native]::GetSystemMetrics(0))x$([CLI.Native]::GetSystemMetrics(1)) cols=$([Console]::WindowWidth) rows=$([Console]::WindowHeight)" |
                    Add-Content (Join-Path $PSScriptRoot 'error.log')
            } catch {}
        }
    } catch {}
}

# Does the console window actually cover the screen? Used to re-assert
# fullscreen when the menu is brought back via hotkey/shortcut after
# something knocked it out of fullscreen. Errs on "yes" so an unreadable
# rect can never cause a reapply loop.
function Test-ConsoleFullscreen {
    try {
        $r = New-Object CLI.Native+RECT
        if (-not [CLI.Native]::GetWindowRect([CLI.Native]::GetConsoleWindow(), [ref]$r)) { return $true }
        $sw = [CLI.Native]::GetSystemMetrics(0)
        $sh = [CLI.Native]::GetSystemMetrics(1)
        return ($r.Left -le 0 -and $r.Top -le 0 -and $r.Right -ge $sw -and $r.Bottom -ge $sh)
    } catch { return $true }
}

# Undo both fullscreen paths: back to a normal framed window, centered
# at roughly 80% of the screen.
function Set-ConsoleWindowed {
    try {
        $out = [CLI.Native]::GetStdHandle(-11)
        $coords = 0
        [CLI.Native]::SetConsoleDisplayMode($out, 2, [ref]$coords) | Out-Null   # leave native fullscreen
        Set-ConsoleFont   # same size as fullscreen - the text never changes size
        $hwnd = [CLI.Native]::GetConsoleWindow()
        $style = [CLI.Native]::GetWindowLong($hwnd, -16)
        [CLI.Native]::SetWindowLong($hwnd, -16, ($style -bor 0x00CF0000)) | Out-Null
        $sw = [CLI.Native]::GetSystemMetrics(0)
        $sh = [CLI.Native]::GetSystemMetrics(1)
        [CLI.Native]::SetWindowPos($hwnd, [IntPtr]::Zero,
            [int]($sw * 0.1), [int]($sh * 0.1), [int]($sw * 0.8), [int]($sh * 0.8), 0x0060) | Out-Null
        Start-Sleep -Milliseconds 100
        $ws = $Host.UI.RawUI.WindowSize
        $Host.UI.RawUI.BufferSize = New-Object System.Management.Automation.Host.Size($ws.Width, $ws.Height)
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
'@
    $script:conHwnd = [CLIntFocus.Win]::GetConsoleWindow()
} catch {}

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

# Fullscreen on launch: on by default, toggleable in SETTINGS ("Fullscreen"
# in settings.json). Turning it off gives a normal centered window.
$fsEnabled = $settings['Fullscreen'] -ne $false

# Cap on configurable tabs (SETTINGS not counted): the tab bar starts at
# column 15 and each named tab takes roughly 15-16 columns, so ~8 content
# tabs plus SETTINGS is what a fullscreen console row actually fits.
$MAX_TABS = 8

$vlcExe     = 'C:\Program Files\VideoLAN\VLC\vlc.exe'
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
    $list += @(Get-ChildItem $dir -Directory -ErrorAction SilentlyContinue | Sort-Object Name |
        Where-Object { @(Get-ChildItem $_.FullName -File -Recurse -ErrorAction SilentlyContinue |
            Select-Object -First 1).Count -gt 0 } |
        ForEach-Object { [pscustomobject]@{ Name = $_.Name + '\'; Path = $_.FullName; Type = 'Dir' } })
    $list += @(Get-ChildItem $dir -File -ErrorAction SilentlyContinue | Sort-Object Name |
        ForEach-Object { [pscustomobject]@{ Name = $_.Name; Path = $_.FullName; Type = 'File' } })
    return $list
}

# ---------------------------------------------------------------- Tabs ---
# Runtime tab objects built from $settings.Tabs (+ SETTINGS appended).
# Each carries its own items, cursor, and - for Files tabs - browse state.
function New-TabState($cfg) {
    $t = @{ Type = $cfg.Type; Path = $cfg.Path; Sel = 0; Off = 0 }
    $t.Name = if ($cfg.Name) { $cfg.Name } else {
        switch ($cfg.Type) {
            'Steam'     { 'STEAM GAMES' }
            'Shortcuts' { if ($cfg.Path) { (Split-Path $cfg.Path -Leaf).ToUpper() } else { 'SHORTCUTS' } }
            'Files'     { if ($cfg.Path) { (Split-Path $cfg.Path -Leaf).ToUpper() } else { 'FILES' } }
            'Settings'  { 'SETTINGS' }
        }
    }
    switch ($cfg.Type) {
        'Steam'     { $t.Items = $games }
        'Shortcuts' {
            $t.Items = @(Get-ShortcutGames $cfg.Path)
            Add-MaProfileTags $t.Items
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
            'Steam'     { 'Steam library' }
            'Shortcuts' { "shortcuts in $($cfg.Path)" }
            'Files'     { "files in $($cfg.Path)" }
        }
        $list += [pscustomobject]@{ Key = 'Tab'; Index = $i
                                    Name = ("Tab $($i + 1): $($tabs[$i].Name)".PadRight(30) + $desc) }
    }
    $list += [pscustomobject]@{ Key = 'AddTab'; Name = '[ + add a tab ]' }
    $list += [pscustomobject]@{ Key = 'Fullscreen'; Name = 'Toggle fullscreen' }
    $list += [pscustomobject]@{ Key = 'Theme'
                                Name = ('Color theme'.PadRight(30) + $script:themeName) }
    $list += [pscustomobject]@{ Key = 'Update'
                                Name = ('Check for updates'.PadRight(30) + "current: v$appVersion") }
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

$items = @(Get-TabItems 0)

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
    $script:listTop  = 7                       # header block height (6-row logos + gap)
    $script:visible  = [Math]::Max(1, $H - $listTop - 1)
}

function Draw-GameLine([int]$i) {
    $y = $listTop + ($i - $offset)
    if ($i -lt $offset -or $i -ge $offset + $visible) { return }
    $lineW = $W - 3   # not $w: case-insensitively shadows $W (see Pick-Folder)
    $label = $items[$i].Name
    $type = $tabs[$tab].Type
    if ($type -in 'Steam', 'Shortcuts') {
        $tdp = Get-GameTdp $items[$i]
        if ($items[$i].MaProfile) { $label += "  [MA profile]" }
        elseif ($tdp)             { $label += "  [$($tdp)W]" }
    }
    if ($i -eq $selected) {
        Write-At 1 $y (Pad ("  >> " + $label + "  ") $lineW) $theme.SelFg $theme.Accent
    } else {
        $fg = if ($type -eq 'Files' -and $items[$i].Type -ne 'File') { $theme.Bright } else { $theme.Text }
        Write-At 1 $y (Pad ("     " + $label + "  ") $lineW) $fg
    }
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
    $script:noticeShown = $false
    $cur = $tabs[$tab]
    $logo = if ($cur.Logo) { $cur.Logo } else { $mascots[$typeMascot[$cur.Type]] }
    for ($i = 0; $i -lt $logo.Count; $i++) {
        Write-At 2 $i $logo[$i] $theme.Logo
    }
    $x = 15
    for ($t = 0; $t -lt $tabs.Count; $t++) {
        $txt = "  $($tabs[$t].Name)  "
        if ($x + $txt.Length -ge $W) { break }   # more tabs than fit: clip the bar
        if ($t -eq $tab) { Write-At $x 0 $txt $theme.SelFg $theme.Accent }
        else             { Write-At $x 0 $txt $theme.Hint }
        $x += $txt.Length + 2
    }
    $count = switch ($cur.Type) {
        'Steam'     { "$($items.Count) Steam games installed" }
        'Shortcuts' { "$($items.Count) shortcuts" }
        'Files'     { Pad "$($cur.Dir)  ($($items.Count) items)" ($W - 16) }
        'Settings'  { 'settings are saved automatically' }
    }
    Write-At 15 1 $count $theme.Info
    $help = if ($cur.Type -eq 'Settings') { "[ D-pad: move    </>: switch tab    A: change    B: quit ]" }
            elseif ($tdpEnabled -and $cur.Type -in 'Steam', 'Shortcuts') { "[ D-pad: move    </>: switch tab    A: launch    RB: TDP    B: quit ]" }
            else { "[ D-pad: move    </>: switch tab    A: launch    B: quit ]" }
    Write-At 15 3 $help $theme.Hint
    if ($items.Count -eq 0) {
        $msg = if ($cur.Type -eq 'Shortcuts') { 'No .lnk shortcuts in this folder - press A to choose another folder or remove this tab.' }
               else { 'Nothing found here.' }
        Write-At 6 $listTop (Pad $msg ($W - 8)) $theme.Hint
    }
    Draw-List
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
    Write-At ($W - 2) $listTop ' ' $theme.Text
    Write-At ($W - 2) ($listTop + $visible - 1) ' ' $theme.Text
    # scroll indicators
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
$script:wasFg = $true       # we start focused and (if enabled) fullscreen
$script:fsCheckNext = 0
function Read-InputKey {
    while ($true) {
        if ([Console]::KeyAvailable) { return ([Console]::ReadKey($true)).Key }
        $k = Get-PadKey
        if ($null -ne $k) { return $k }
        # On regaining focus (hotkey/shortcut re-open), make sure we're
        # still actually fullscreen; if something knocked the window out
        # of it, force it back. Only on the transition, never repeatedly.
        if ([Environment]::TickCount -ge $script:fsCheckNext) {
            $script:fsCheckNext = [Environment]::TickCount + 500
            $fgNow = ($script:conHwnd -ne [IntPtr]::Zero -and
                      [CLIntFocus.Win]::GetForegroundWindow() -eq $script:conHwnd)
            if ($fgNow -and -not $script:wasFg -and $script:fsEnabled -and -not (Test-ConsoleFullscreen)) {
                Set-ConsoleFullscreen
                Draw-All
            }
            $script:wasFg = $fgNow
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
        $list += @(Get-ChildItem $dir -Directory -ErrorAction SilentlyContinue | Sort-Object Name |
            ForEach-Object { [pscustomobject]@{ Name = $_.Name + '\'; Path = $_.FullName; Type = 'Dir' } })
    }
    return $list
}

# Modal folder browser: A opens a folder or picks the current one via the
# top entry, B goes up a level (above a drive root: the drive list, then
# cancel). Returns the chosen path, or $null if cancelled.
function Pick-Folder([string]$label, [string]$start) {
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
        $key = Read-InputKey
        switch ($key) {
            'UpArrow'   { if ($entries.Count) { $sel = ($sel - 1 + $entries.Count) % $entries.Count } }
            'DownArrow' { if ($entries.Count) { $sel = ($sel + 1) % $entries.Count } }
            'Enter'     {
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
    $sel = 0
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
            'UpArrow'   { $sel = ($sel - 1 + $options.Count) % $options.Count }
            'DownArrow' { $sel = ($sel + 1) % $options.Count }
            'Enter'     { return $sel }
            'Escape'    { return -1 }
            'Q'         { return -1 }
        }
    }
}

# Icon picker: mascot list on the left, live art preview on the right.
# Returns a mascot name, '::auto' for automatic assignment, $null on cancel.
function Pick-Mascot([string]$title, [string]$current) {
    $names = @($mascots.Keys | Where-Object { $_ -ne 'robot' })   # robot belongs to SETTINGS
    $entries = @('(automatic)') + $names
    $sel = [Math]::Max(0, [array]::IndexOf($entries, $current))
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
            'UpArrow'   { $sel = ($sel - 1 + $entries.Count) % $entries.Count }
            'DownArrow' { $sel = ($sel + 1) % $entries.Count }
            'Enter'     { if ($sel -eq 0) { return '::auto' } else { return $entries[$sel] } }
            'Escape'    { return $null }
            'Q'         { return $null }
        }
    }
}

# Modal text prompt: type on the keyboard, Enter/A saves, Esc/B cancels.
# Returns the text, or $null if cancelled. An empty result means "no
# override" - callers treat it as "back to the automatic value".
function Read-TextInput([string]$title, [string]$current) {
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
    if ($cfg.Type -ne 'Steam') { $opts += 'Change folder' }
    $opts += @('Rename tab', 'Change icon', 'Move left', 'Move right', 'Remove tab', 'Cancel')
    $choice = Pick-Option "TAB $($i + 1): $($tabs[$i].Name)" $opts
    if ($choice -lt 0) { return }
    switch ($opts[$choice]) {
        'Change folder' {
            $p = Pick-Folder "new folder for this tab" $cfg.Path
            if ($p) { $cfg.Path = $p; $cfg.Remove('Name') }   # re-derive the title
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
            $settings['Tabs'] += @{ Type = 'Steam' }
            if ($games.Count -eq 0) {
                try { $script:games = @(@(Get-InstalledGames) + @(Get-NonSteamGames) | Sort-Object Name) } catch {}
                Add-MaProfileTags $games
            }
            Apply-TabConfig
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

function Wait-ForGameExit($game) {
    if ($game.Exe) {
        # Non-Steam shortcut: Steam doesn't track these in the registry,
        # so watch the exe's process instead.
        $proc = [System.IO.Path]::GetFileNameWithoutExtension($game.Exe)
        $deadline = [DateTime]::Now.AddSeconds(90)
        while ([DateTime]::Now -lt $deadline) {
            if (Get-Process -Name $proc -ErrorAction SilentlyContinue) { break }
            Start-Sleep -Milliseconds 500
        }
        while (Get-Process -Name $proc -ErrorAction SilentlyContinue) {
            Start-Sleep -Seconds 2
        }
        return
    }
    # Steam flips this registry value to 1 while the game is running.
    $key = "HKCU:\Software\Valve\Steam\Apps\$($game.AppId)"
    $deadline = [DateTime]::Now.AddSeconds(90)
    while ([DateTime]::Now -lt $deadline) {
        if ((Get-ItemProperty $key -ErrorAction SilentlyContinue).Running -eq 1) { break }
        Start-Sleep -Milliseconds 500
    }
    while ((Get-ItemProperty $key -ErrorAction SilentlyContinue).Running -eq 1) {
        Start-Sleep -Seconds 2
    }
}

function Move-Selection([int]$delta) {
    if ($items.Count -eq 0) { return }
    Clear-Notice
    $old = $script:selected
    $script:selected = ($script:selected + $delta + $items.Count) % $items.Count
    if ($script:selected -lt $script:offset) {
        $script:offset = $script:selected
        Draw-List
    } elseif ($script:selected -ge $script:offset + $script:visible) {
        $script:offset = $script:selected - $script:visible + 1
        Draw-List
    } else {
        Draw-GameLine $old        # repaint only the two lines that changed
        Draw-GameLine $script:selected
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
    if ($script:fsEnabled) { Set-ConsoleFullscreen }
    Draw-All
    # Drop any keypress still buffered from launching the shortcut (e.g. the
    # Enter that opened it), otherwise it instantly launches the first game.
    Start-Sleep -Milliseconds 400
    while ([Console]::KeyAvailable) { [Console]::ReadKey($true) | Out-Null }
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
            'Home'      { Move-Selection (-$selected) }
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
                                }
                            }
                            1 {
                                $settings['Tabs'] = @($settings['Tabs'] | Where-Object { $_ -ne $cfg })
                                Save-Settings; Build-Tabs
                                $script:tab = [Math]::Min($tab, $tabs.Count - 1)
                                $script:items = @(Get-TabItems $tab)
                                $script:selected = 0; $script:offset = 0
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
                        'Fullscreen' {
                            # Stateless button: act on what the window IS,
                            # not a remembered on/off. The result is still
                            # persisted so the next launch matches.
                            if (Test-ConsoleFullscreen) { $script:fsEnabled = $false; Set-ConsoleWindowed }
                            else                        { $script:fsEnabled = $true;  Set-ConsoleFullscreen }
                            $settings['Fullscreen'] = $script:fsEnabled
                            Save-Settings
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
                    if ($isVideo -and (Test-Path $vlcExe)) {
                        Start-Process $vlcExe -ArgumentList '--fullscreen', '--play-and-exit', "`"$($v.Path)`""
                        Wait-ForGameExit ([pscustomobject]@{ Exe = 'vlc.exe' })
                    } else {
                        Start-Process $v.Path   # default app for this file type
                        Start-Sleep -Seconds 5
                    }
                    try { (New-Object -ComObject WScript.Shell).AppActivate('CLInt') | Out-Null } catch {}
                    while ([Console]::KeyAvailable) { [Console]::ReadKey($true) | Out-Null }
                    Draw-All
                    break
                }
                $g = $items[$selected]
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
                if ($cur.Type -eq 'Shortcuts') { Start-Process $g.Path }   # run the .lnk itself
                else                           { Start-Process "steam://rungameid/$($g.LaunchId)" }
                Wait-ForGameExit $g
                if ($prevTdp) { Set-Tdp $prevTdp.Stapm $prevTdp.Fast $prevTdp.Slow }
                # bring the menu window back to the front, drop any keys
                # pressed while the game was running, and redraw
                try { (New-Object -ComObject WScript.Shell).AppActivate('CLInt') | Out-Null } catch {}
                while ([Console]::KeyAvailable) { [Console]::ReadKey($true) | Out-Null }
                Draw-All
            }
            'F5'        {   # RB on the gamepad (read natively via XInput)
                if ($tdpEnabled -and $cur.Type -in 'Steam', 'Shortcuts' -and $items.Count -gt 0) {
                    $g = $items[$selected]
                    if ($g.MaProfile) {
                        Show-Notice "TDP locked: Motion Assistant has its own profile for this game ($($g.MaProfile).ini)"
                    } else {
                        Clear-Notice
                        $next = $tdpModes[($tdpModes.IndexOf((Get-GameTdp $g)) + 1) % $tdpModes.Count]
                        if ($next -eq 0) { $tdpMap.Remove([string]$g.AppId) }
                        else             { $tdpMap[[string]$g.AppId] = $next }
                        Save-TdpMap
                        Draw-GameLine $selected
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
                    Add-Content (Join-Path $PSScriptRoot 'error.log')
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
