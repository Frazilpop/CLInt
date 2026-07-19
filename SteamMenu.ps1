# SteamMenu.ps1 - CLInt: interactive terminal launcher for installed Steam games.
# Scans Steam's appmanifest files (no AI, no network) and launches the
# selected game via the steam:// protocol.
#
# Usage:  games          (interactive menu: arrows/D-pad to move, Enter/A to launch)
#         games -List    (just print the games, no menu)

param([switch]$List)

$ErrorActionPreference = 'Stop'

# Single instance: whichever way a second copy gets started (desktop
# shortcut, AppsKey via SteamMenuKey.ahk, direct run), it defers to the
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

$Host.UI.RawUI.WindowTitle = 'CLInt'   # matched by Launch.ps1, SteamMenuKey.ahk and claude-gamepad.ahk

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

$games = @(@(Get-InstalledGames) + @(Get-NonSteamGames) | Sort-Object Name)
if ($games.Count -eq 0) { Write-Host "No installed Steam games found."; exit 1 }

# ----------------------------------------------------------- Settings ---
# User-configurable folders, editable from the SETTINGS tab in the app.
$settingsFile = Join-Path $PSScriptRoot 'settings.json'
$settings = @{
    VideoRoot        = 'D:\Videos'
    LocalShortcutDir = 'C:\Users\frazi\Desktop\Game Shortcuts'
}
if (Test-Path $settingsFile) {
    (Get-Content $settingsFile -Raw | ConvertFrom-Json).PSObject.Properties |
        ForEach-Object { $settings[$_.Name] = $_.Value }
}
function Save-Settings {
    $settings | ConvertTo-Json | Set-Content $settingsFile -Encoding utf8
}

# Local (non-Steam-managed) games: .lnk shortcuts collected in one folder.
# Launched via the shortcut itself; game exit is tracked by the target exe.
function Get-LocalGames {
    $wsh = New-Object -ComObject WScript.Shell
    @(Get-ChildItem (Join-Path $settings.LocalShortcutDir '*.lnk') -ErrorAction SilentlyContinue |
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
$localGames = @()   # filled by Update-LocalGames once MA profiles are known

# ---------------------------------------------------------------- TDP ---
# Per-game TDP override, applied through the same ryzenadj.exe that GPD's
# Motion Assistant uses (its WinRing0 driver is already loaded, so no
# elevation is needed). RB / F5 cycles: default -> 12W -> 15W -> 18W -> 5W.
# The pre-launch limits are captured and restored when the game closes.

$ryzenAdj   = 'C:\Users\frazi\Documents\MotionAssistant\amd\ryzenadj.exe'
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
$maProfileNames = @(Get-ChildItem 'C:\Users\frazi\Documents\MotionAssistant\Profiles\Process\*.ini' `
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

function Update-LocalGames {
    $script:localGames = @(Get-LocalGames)
    Add-MaProfileTags $script:localGames
}
Update-LocalGames

if ($List) {
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
function Set-ConsoleFullscreen {
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
'@
        $out = [CLI.Native]::GetStdHandle(-11)

        $font = New-Object CLI.Native+CONSOLE_FONT_INFOEX
        $font.cbSize = [System.Runtime.InteropServices.Marshal]::SizeOf($font)
        $font.SizeY = 28; $font.FontFamily = 54; $font.FontWeight = 400
        $font.FaceName = 'Consolas'
        [CLI.Native]::SetCurrentConsoleFontEx($out, $false, [ref]$font) | Out-Null

        # conhost's native fullscreen (what Alt+Enter toggles): borderless,
        # at the origin, with black padding to the screen edges
        $coords = 0
        [CLI.Native]::SetConsoleDisplayMode($out, 1, [ref]$coords) | Out-Null
        Start-Sleep -Milliseconds 200

        # buffer == window so there are no scrollbars
        $ws = $Host.UI.RawUI.WindowSize
        $Host.UI.RawUI.BufferSize = New-Object System.Management.Automation.Host.Size($ws.Width, $ws.Height)
    } catch {}
}

# One mascot per tab: rocket = Steam launches, handheld = local games on
# the GPD itself, VHS = videos.
$logos = @(
    @(
    '    /\'
    '   /##\'
    '  / o o \'
    '  | \_/ |'
    ' /|#####|\'
    '   ^^ ^^'
    ),
    @(
    '.---------.'
    '| .-----. |'
    '|+| o o |b|'
    '| | \_/ |a|'
    '| ''-----'' |'
    '''---------'''
    ),
    @(
    '.----------.'
    '| (o)  (o) |'
    '|   \__/   |'
    '| [======] |'
    '''----------'''
    ),
    @(
    '    ___'
    '  .[___].'
    '  | o o |'
    '  | \_/ |'
    '  ''-----'''
    )
)
# ------------------------------------------------------------- Videos ---
$videoRoot  = $settings.VideoRoot
$vlcExe     = 'C:\Program Files\VideoLAN\VLC\vlc.exe'
$videoExtRe = '^\.(mp4|mkv|avi|webm|mov|m4v|wmv|mpg|mpeg|ts|flv)$'

# The videos tab is a folder browser rooted at $videoRoot: '..' first (in
# subfolders), then folders that contain at least one video somewhere below
# (hides e.g. Subs folders), then the video files themselves.
function Get-VideoItems([string]$dir) {
    $list = @()
    if ($dir -ne $videoRoot) {
        $list += [pscustomobject]@{ Name = '..'; Path = (Split-Path $dir -Parent); Type = 'Up' }
    }
    $list += @(Get-ChildItem $dir -Directory -ErrorAction SilentlyContinue | Sort-Object Name |
        Where-Object { @(Get-ChildItem $_.FullName -File -Recurse -ErrorAction SilentlyContinue |
            Where-Object { $_.Extension -match $videoExtRe }).Count -gt 0 } |
        ForEach-Object { [pscustomobject]@{ Name = $_.Name + '\'; Path = $_.FullName; Type = 'Dir' } })
    $list += @(Get-ChildItem $dir -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Extension -match $videoExtRe } | Sort-Object Name |
        ForEach-Object { [pscustomobject]@{ Name = $_.Name; Path = $_.FullName; Type = 'File' } })
    return $list
}

$videoDir   = $videoRoot
$videoStack = New-Object System.Collections.Stack   # (dir, selected, offset) per level
$videoItems = @(Get-VideoItems $videoRoot)

# Tabs: 0 = Steam games, 1 = local game shortcuts, 2 = video browser,
# 3 = settings. Left/right cycles; each tab remembers its own cursor.
$tabNames     = @('STEAM GAMES', 'LOCAL GAMES', 'VIDEOS', 'SETTINGS')
$VIDEO_TAB    = 2
$SETTINGS_TAB = 3
$tab          = 0
$tabSel       = @(0, 0, 0, 0)
$tabOff       = @(0, 0, 0, 0)
$items        = $games   # the list the current tab shows

$selected = 0
$offset   = 0    # first item index shown in the viewport

function Get-SettingsItems {
    @(
        [pscustomobject]@{ Key = 'VideoRoot';        Label = 'Video folder'
                           Name = ('Video folder'.PadRight(24) + $settings.VideoRoot) }
        [pscustomobject]@{ Key = 'LocalShortcutDir'; Label = 'Game shortcuts folder'
                           Name = ('Game shortcuts folder'.PadRight(24) + $settings.LocalShortcutDir) }
    )
}

function Get-TabItems([int]$t) {
    switch ($t) {
        0 { return $games }
        1 { return $localGames }
        2 { return $script:videoItems }
        3 { return Get-SettingsItems }
    }
}

function Switch-Tab([int]$delta) {
    $tabSel[$script:tab] = $script:selected
    $tabOff[$script:tab] = $script:offset
    $script:tab = ($script:tab + $delta + $tabNames.Count) % $tabNames.Count
    $script:items    = @(Get-TabItems $script:tab)
    $script:selected = $tabSel[$script:tab]
    $script:offset   = $tabOff[$script:tab]
    Draw-All
}

function Enter-VideoDir([string]$path) {
    $videoStack.Push(@($script:videoDir, $script:selected, $script:offset))
    $script:videoDir   = $path
    $script:videoItems = @(Get-VideoItems $path)
    $script:items      = $script:videoItems
    $script:selected = 0
    $script:offset   = 0
    Draw-All
}

# Go up one folder; returns $false when already at the root.
function Exit-VideoDir {
    if ($script:videoDir -eq $videoRoot) { return $false }
    if ($videoStack.Count -gt 0) {
        $prev = $videoStack.Pop()
        $script:videoDir = $prev[0]; $sel = $prev[1]; $off = $prev[2]
    } else {
        $script:videoDir = Split-Path $script:videoDir -Parent; $sel = 0; $off = 0
    }
    $script:videoItems = @(Get-VideoItems $script:videoDir)
    $script:items      = $script:videoItems
    $script:selected = [Math]::Min($sel, [Math]::Max(0, $script:items.Count - 1))
    $script:offset   = $off
    Draw-All
    return $true
}

function Write-At([int]$x, [int]$y, [string]$text, $fg, $bg) {
    [Console]::SetCursorPosition($x, $y)
    if ($bg) { Write-Host $text -ForegroundColor $fg -BackgroundColor $bg -NoNewline }
    else     { Write-Host $text -ForegroundColor $fg -NoNewline }
}

function Pad([string]$s, [int]$w) {
    if ($s.Length -gt $w) { return $s.Substring(0, $w - 3) + '...' }
    return $s.PadRight($w)
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
    $w = $W - 3
    $label = $items[$i].Name
    if ($tab -le 1) {
        $tdp = Get-GameTdp $items[$i]
        if ($items[$i].MaProfile) { $label += "  [MA profile]" }
        elseif ($tdp)             { $label += "  [$($tdp)W]" }
    }
    if ($i -eq $selected) {
        Write-At 1 $y (Pad ("  >> " + $label + "  ") $w) 'Black' 'Cyan'
    } else {
        $fg = if ($tab -eq $VIDEO_TAB -and $items[$i].Type -ne 'File') { 'White' } else { 'Gray' }
        Write-At 1 $y (Pad ("     " + $label + "  ") $w) $fg
    }
}

$noticeShown = $false
function Show-Notice([string]$text) {
    Write-At 15 4 (Pad $text ($W - 16)) 'Yellow'
    $script:noticeShown = $true
}
function Clear-Notice {
    if ($script:noticeShown) {
        Write-At 15 4 (' ' * ($W - 16)) 'Gray'
        $script:noticeShown = $false
    }
}

function Draw-All {
    Clear-Host
    Get-Layout
    $script:noticeShown = $false
    $logo = $logos[$tab]
    for ($i = 0; $i -lt $logo.Count; $i++) {
        Write-At 2 $i $logo[$i] 'Magenta'
    }
    $x = 15
    for ($t = 0; $t -lt $tabNames.Count; $t++) {
        $txt = "  $($tabNames[$t])  "
        if ($t -eq $tab) { Write-At $x 0 $txt 'Black' 'Cyan' }
        else             { Write-At $x 0 $txt 'DarkGray' }
        $x += $txt.Length + 2
    }
    $count = switch ($tab) {
        0 { "$($games.Count) Steam games installed" }
        1 { "$($localGames.Count) local games" }
        2 { Pad "$videoDir  ($($items.Count) items)" ($W - 16) }
        3 { 'settings are saved automatically' }
    }
    Write-At 15 1 $count 'DarkCyan'
    $help = if ($tab -eq $SETTINGS_TAB) { "[ D-pad: move    </>: switch tab    A: change    B: quit ]" }
            elseif ($tdpEnabled -and $tab -le 1) { "[ D-pad: move    </>: switch tab    A: launch    RB: TDP    B: quit ]" }
            else { "[ D-pad: move    </>: switch tab    A: launch    B: quit ]" }
    Write-At 15 3 $help 'DarkGray'
    if ($items.Count -eq 0) { Write-At 6 $listTop 'Nothing found here.' 'DarkGray' }
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
        Write-At 1 $y (' ' * ($W - 3)) 'Gray'
    }
    Write-At ($W - 2) $listTop ' ' 'Gray'
    Write-At ($W - 2) ($listTop + $visible - 1) ' ' 'Gray'
    # scroll indicators
    if ($offset -gt 0)                       { Write-At ($W - 8) $listTop '/\ more' 'DarkMagenta' }
    if ($offset + $visible -lt $items.Count) { Write-At ($W - 8) ($listTop + $visible - 1) '\/ more' 'DarkMagenta' }
}

# ------------------------------------------------------ folder picker ---

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
    @{ Mask = 0x0004; Key = [ConsoleKey]::LeftArrow;  Repeat = $true  }   # d-pad left
    @{ Mask = 0x0008; Key = [ConsoleKey]::RightArrow; Repeat = $true  }   # d-pad right
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
function Read-InputKey {
    while ($true) {
        if ([Console]::KeyAvailable) { return ([Console]::ReadKey($true)).Key }
        $k = Get-PadKey
        if ($null -ne $k) { return $k }
        Start-Sleep -Milliseconds 16
    }
}

function Get-PickerEntries($dir) {
    $list = @()
    if ($null -eq $dir) {   # drive list
        foreach ($d in (Get-PSDrive -PSProvider FileSystem | Sort-Object Name)) {
            if (Test-Path $d.Root) {
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
    if (-not (Test-Path $dir)) { $dir = $env:USERPROFILE }
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
        Write-At 2 0 (Pad "CHOOSE FOLDER  --  $label" ($W - 4)) 'Cyan'
        Write-At 2 1 (Pad ("Now: " + $(if ($dir) { $dir } else { 'select a drive' })) ($W - 4)) 'DarkCyan'
        Write-At 2 3 '[ D-pad: move    A: open / choose    B: up / cancel ]' 'DarkGray'
        $top = 5
        $rows = [Math]::Max(1, $H - $top - 1)
        if ($sel -lt $off) { $off = $sel }
        if ($sel -ge $off + $rows) { $off = $sel - $rows + 1 }
        for ($r = 0; $r -lt $rows; $r++) {
            $i = $off + $r
            $w = $W - 3
            if ($i -lt $entries.Count) {
                if ($i -eq $sel) { Write-At 1 ($top + $r) (Pad ('  >> ' + $entries[$i].Name + '  ') $w) 'Black' 'Cyan' }
                else             { Write-At 1 ($top + $r) (Pad ('     ' + $entries[$i].Name + '  ') $w) 'Gray' }
            } else {
                Write-At 1 ($top + $r) (' ' * $w) 'Gray'
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

# Persist a changed folder setting and refresh the affected tab's data.
function Apply-Setting([string]$key, [string]$path) {
    $settings[$key] = $path
    Save-Settings
    if ($key -eq 'VideoRoot') {
        $script:videoRoot  = $path
        $script:videoDir   = $path
        $script:videoStack.Clear()
        $script:videoItems = @(Get-VideoItems $path)
    } else {
        Update-LocalGames
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
    Set-ConsoleFullscreen
    Draw-All
    # Drop any keypress still buffered from launching the shortcut (e.g. the
    # Enter that opened it), otherwise it instantly launches the first game.
    Start-Sleep -Milliseconds 400
    while ([Console]::KeyAvailable) { [Console]::ReadKey($true) | Out-Null }
    while ($true) {
        $key = Read-InputKey
        switch ($key) {
            'UpArrow'   { Move-Selection -1 }
            'DownArrow' { Move-Selection 1 }
            'Home'      { Move-Selection (-$selected) }
            'End'       { Move-Selection ($items.Count - 1 - $selected) }
            'LeftArrow'  { Switch-Tab -1 }
            'RightArrow' { Switch-Tab 1 }
            'Enter'     {
                if ($items.Count -eq 0) { break }
                if ($tab -eq $SETTINGS_TAB) {
                    $s = $items[$selected]
                    $picked = Pick-Folder $s.Label $settings[$s.Key]
                    if ($picked) { Apply-Setting $s.Key $picked }
                    $script:items = @(Get-TabItems $tab)
                    Draw-All
                    break
                }
                if ($tab -eq $VIDEO_TAB) {
                    $v = $items[$selected]
                    if ($v.Type -eq 'Dir') { Enter-VideoDir $v.Path; break }
                    if ($v.Type -eq 'Up')  { Exit-VideoDir | Out-Null; break }
                    Clear-Host
                    Write-Host ""
                    Write-Host "     _____" -ForegroundColor Cyan
                    Write-Host "    | |>  |    NOW PLAYING" -ForegroundColor Cyan
                    Write-Host "    |_|___|    $($v.Name)" -ForegroundColor Magenta
                    Write-Host ""
                    Write-Host "   (menu will return here when VLC closes)" -ForegroundColor DarkGray
                    if (Test-Path $vlcExe) {
                        Start-Process $vlcExe -ArgumentList '--fullscreen', '--play-and-exit', "`"$($v.Path)`""
                        Wait-ForGameExit ([pscustomobject]@{ Exe = 'vlc.exe' })
                    } else {
                        Start-Process $v.Path   # no VLC: default player, untrackable
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
                Write-Host "      _" -ForegroundColor Cyan
                Write-Host "     /^\      LAUNCHING" -ForegroundColor Cyan
                Write-Host "    |___|" -ForegroundColor Cyan
                Write-Host "    |   |     $($g.Name)" -ForegroundColor Magenta
                Write-Host "    |___|" -ForegroundColor Cyan
                Write-Host "   /|   |\    GLHF o7" -ForegroundColor DarkCyan
                Write-Host "    ^^^^^" -ForegroundColor DarkCyan
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
                    Write-Host "   TDP: $($tdpWatts)W (reverts on exit)" -ForegroundColor Yellow
                }
                if ($tab -eq 1) { Start-Process $g.Path }   # local game: run its shortcut
                else            { Start-Process "steam://rungameid/$($g.LaunchId)" }
                Write-Host "   (menu will return here when the game closes)" -ForegroundColor DarkGray
                Wait-ForGameExit $g
                if ($prevTdp) { Set-Tdp $prevTdp.Stapm $prevTdp.Fast $prevTdp.Slow }
                # bring the menu window back to the front, drop any keys
                # pressed while the game was running, and redraw
                try { (New-Object -ComObject WScript.Shell).AppActivate('CLInt') | Out-Null } catch {}
                while ([Console]::KeyAvailable) { [Console]::ReadKey($true) | Out-Null }
                Draw-All
            }
            'F5'        {   # RB on the gamepad (read natively via XInput)
                if ($tdpEnabled -and $tab -le 1 -and $items.Count -gt 0) {
                    $g = $games[$selected]
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
            'Escape'    {   # in a video subfolder: go up a level; otherwise quit
                if ($tab -eq $VIDEO_TAB -and (Exit-VideoDir)) { break }
                Clear-Host; exit 0
            }
            'Q'         { Clear-Host; exit 0 }
        }
        # redraw if the window was resized
        if ($W -ne [Console]::WindowWidth -or $H -ne [Console]::WindowHeight) { Draw-All }
    }
} finally {
    [Console]::CursorVisible = $true
}
