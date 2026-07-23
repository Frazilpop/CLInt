# Hotkey.ps1 - the global menu key, in one place. Dot-sourced by CLInt.ps1
# (SETTINGS -> Menu key), Install.ps1 and Uninstall.ps1, so all three drive
# the hotkey exactly the same way.
#
# The binding lives in data\menu-key.txt and CLIntKey.ahk WATCHES that file:
# changing the key never restarts the script. That is the whole design, and
# it exists because restarting was where every rebind went wrong:
#   - AutoHotkey's #SingleInstance replacement asks the running copy to quit
#     through its message loop. A copy sitting inside a key handler never
#     answers, and the new one gives up with "could not close the existing
#     instance" - leaving two scripts fighting for the key, or none at all.
#   - Re-binding the key that is ALREADY bound meant pressing it during
#     setup, which launched CLInt over the top of whatever was doing the
#     setup - and made the handler block, causing exactly the above.
#   - Stop-Process cannot touch a copy that was started elevated.
# Writing one small file has none of those failure modes.
#
# Files, all in data\:
#   menu-key.txt         the wanted key, one AutoHotkey key name, or "off"
#   menu-key-cmd.txt     one-shot order for the script ("exit"); it deletes it
#   menu-key-status.txt  written BY the script: "ok|F13", "fail|F13", "off|"
# The status file is the handshake. Delete it, and a live script rewrites it
# within one tick - which is how we tell "bound and running" from "the file
# says F13 but nothing is listening".

$script:HotkeyRunKey  = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
$script:HotkeyRunName = 'CLIntKey'

function Get-HotkeyPaths([string]$Root) {
    $data = Join-Path $Root 'data'
    $ahkScript = Join-Path $Root 'app\CLIntKey.ahk'
    if (-not (Test-Path $ahkScript)) { $ahkScript = Join-Path $Root 'CLIntKey.ahk' }   # flat copy
    return [pscustomobject]@{
        Data   = $data
        Key    = Join-Path $data 'menu-key.txt'
        Cmd    = Join-Path $data 'menu-key-cmd.txt'
        Status = Join-Path $data 'menu-key-status.txt'
        Script = $ahkScript
    }
}

# _UIA first. That build runs with UI Access, and without it a global hotkey
# silently stops working whenever anything elevated is in front (a game with
# anti-cheat, an admin console): Windows won't deliver the key to a
# lower-privilege process, and won't let it pull a window to the foreground
# either. It only exists in an admin-installed AutoHotkey, hence the plain
# build right behind it.
#
# The logon entry wins over both, because it records a build already proven
# to START on this machine - _UIA refuses to on some, and re-discovering
# that costs several seconds of waiting every single time.
function Find-AhkExe {
    try {
        $cmd = (Get-ItemProperty $script:HotkeyRunKey -Name $script:HotkeyRunName -ErrorAction SilentlyContinue).$script:HotkeyRunName
        if ($cmd -match '^"([^"]+)"') { if (Test-Path $Matches[1]) { return $Matches[1] } }
    } catch {}
    $roots = @("$env:ProgramFiles\AutoHotkey\v2", "${env:ProgramFiles(x86)}\AutoHotkey\v2",
               "$env:LOCALAPPDATA\Programs\AutoHotkey\v2")
    foreach ($exe in @('AutoHotkey64_UIA.exe', 'AutoHotkey64.exe', 'AutoHotkey32.exe', 'AutoHotkey.exe')) {
        foreach ($r in $roots) { if (Test-Path (Join-Path $r $exe)) { return (Join-Path $r $exe) } }
    }
    return $null
}

# Cheap gate: is ANY AutoHotkey running? No WMI, no command lines.
function Test-AnyAhkProcess {
    return [bool]@(Get-Process -Name 'AutoHotkey*' -ErrorAction SilentlyContinue).Count
}

# Win32_Process is the only way to see a command line, so this costs a few
# hundred ms - never call it while drawing the menu.
#
# It also has a blind spot that caused real damage: a process running at
# higher privilege than we are reports an EMPTY command line, so a copy of
# CLIntKey.ahk started elevated (or by the _UIA build) looks like "no hotkey
# running" here. Something then started a SECOND copy, AutoHotkey's
# #SingleInstance tried to close the first, couldn't - because it can't
# touch a more privileged process either - and put up "could not close the
# existing instance of the script". Test-MenuKeyLive below is the answer
# that doesn't care about privilege; this one only exists to hand out PIDs.
function Get-HotkeyProcess {
    try {
        return @(Get-CimInstance Win32_Process -Filter "Name LIKE 'AutoHotkey%'" |
            Where-Object { $_.CommandLine -match 'CLIntKey\.ahk' })
    } catch { return @() }
}
function Test-HotkeyRunning { return [bool]@(Get-HotkeyProcess).Count }

# Processes we are not allowed to look inside, and equally not allowed to
# stop. If one of these turns out to be the hotkey, saying so beats trying.
function Get-OpaqueAhkProcess {
    try {
        return @(Get-CimInstance Win32_Process -Filter "Name LIKE 'AutoHotkey%'" |
            Where-Object { -not $_.CommandLine })
    } catch { return @() }
}

# --- The files ---------------------------------------------------------

# Write via a temp file and rename: the script re-reads menu-key.txt every
# few hundred ms and must never catch a half-written one.
function Set-MenuKeyFile([string]$Root, [string]$Key) {
    $p = Get-HotkeyPaths $Root
    New-Item -ItemType Directory -Force $p.Data | Out-Null
    $tmp = "$($p.Key).tmp"
    Set-Content -Path $tmp -Value $Key -Encoding Ascii
    Move-Item $tmp $p.Key -Force
}

# Both readers are called in polling loops and one of them runs every time
# the settings list is rebuilt. Test-Path first and SilentlyContinue after:
# a missing file is the NORMAL case here, not an error, and Get-Content's
# is non-terminating - so it slips straight past a try/catch and prints red
# text over the menu unless it is asked not to.
function Get-MenuKeyName([string]$Root) {
    $p = Get-HotkeyPaths $Root
    if (-not (Test-Path $p.Key)) { return '' }
    $raw = Get-Content $p.Key -TotalCount 1 -ErrorAction SilentlyContinue
    if (-not $raw) { return '' }
    return ([string]$raw).Trim()
}

# Returns @{ State = 'ok'|'fail'|'unknown'|'off'; Key = '<name>' }, or $null
# when the script has never reported (not running, or a pre-v1.0.2 copy).
function Get-MenuKeyStatus([string]$Root) {
    $p = Get-HotkeyPaths $Root
    if (-not (Test-Path $p.Status)) { return $null }
    $raw = Get-Content $p.Status -TotalCount 1 -ErrorAction SilentlyContinue
    if (-not $raw) { return $null }
    $bits = ([string]$raw).Trim() -split '\|', 2
    if (-not $bits[0]) { return $null }
    return [pscustomobject]@{ State = $bits[0]; Key = $(if ($bits.Count -gt 1) { $bits[1] } else { '' }) }
}

# Clear the handshake and wait for a live script to rewrite it. This is the
# one honest test of "is the hotkey actually working right now".
function Wait-MenuKeyStatus([string]$Root, [int]$TimeoutMs = 2500) {
    $p = Get-HotkeyPaths $Root
    $deadline = [Environment]::TickCount + $TimeoutMs
    while ([Environment]::TickCount -lt $deadline) {
        $s = Get-MenuKeyStatus $Root
        if ($s) { return $s }
        Start-Sleep -Milliseconds 100
    }
    return $null
}
function Clear-MenuKeyStatus([string]$Root) {
    Remove-Item (Get-HotkeyPaths $Root).Status -Force -ErrorAction SilentlyContinue
}

# THE liveness test: clear the handshake and see whether it comes back. A
# running script rewrites it within a tick or two, whatever privilege either
# side is running at - which is exactly what process inspection can't do
# (see Get-HotkeyProcess). Returns the fresh status, or $null.
function Test-MenuKeyLive([string]$Root, [int]$TimeoutMs = 2500) {
    if (-not (Test-AnyAhkProcess)) { return $null }
    Clear-MenuKeyStatus $Root
    return Wait-MenuKeyStatus $Root $TimeoutMs
}

# Same question, but paced for the interactive path: give a live script a
# tick or two to answer, and only keep waiting if there is something
# plausibly ours to wait FOR. Process inspection is the slow part, so it
# happens after the quick answer has already failed - not before.
function Resolve-MenuKeyLive([string]$Root) {
    $s = Test-MenuKeyLive $Root 1200
    if ($s) { return $s }
    if ((Test-HotkeyRunning) -or @(Get-OpaqueAhkProcess).Count) { return (Wait-MenuKeyStatus $Root 1800) }
    return $null
}

# --- Starting and stopping ---------------------------------------------

function Register-HotkeyStartup([string]$Root, [string]$AhkExe) {
    $p = Get-HotkeyPaths $Root
    if (-not (Test-Path $script:HotkeyRunKey)) { New-Item $script:HotkeyRunKey -Force | Out-Null }
    Set-ItemProperty $script:HotkeyRunKey -Name $script:HotkeyRunName -Value "`"$AhkExe`" `"$($p.Script)`""
}
function Unregister-HotkeyStartup {
    if (Get-ItemProperty $script:HotkeyRunKey -Name $script:HotkeyRunName -ErrorAction SilentlyContinue) {
        Remove-ItemProperty $script:HotkeyRunKey -Name $script:HotkeyRunName -Force
        return $true
    }
    return $false
}

# Ask the script to quit, then insist. The polite route comes first because
# the blunt one has two blind spots: a copy started elevated refuses
# Stop-Process, and a copy busy inside a key handler ignores AutoHotkey's own
# replacement request. Reading a file needs neither privilege nor a free
# message loop. Returns $true when nothing is left holding the key.
function Stop-HotkeyScript([string]$Root, [int]$TimeoutMs = 3000) {
    if (-not (Test-AnyAhkProcess)) { return $true }
    # Plenty of people run AutoHotkey for their own reasons (this machine
    # has a Mac-keyboard remapper on it). If every copy running is one we
    # can see into and none of them is ours, there is nothing to stop - and
    # no reason to spend three seconds establishing that.
    if (-not (Test-HotkeyRunning) -and -not @(Get-OpaqueAhkProcess).Count `
        -and -not (Test-MenuKeyLive $Root 900)) { return $true }
    $p = Get-HotkeyPaths $Root
    try {
        New-Item -ItemType Directory -Force $p.Data | Out-Null
        Set-Content -Path $p.Cmd -Value 'exit' -Encoding Ascii
    } catch {}
    $deadline = [Environment]::TickCount + $TimeoutMs
    while ([Environment]::TickCount -lt $deadline) {
        Start-Sleep -Milliseconds 250
        if (-not (Test-HotkeyRunning) -and -not (Test-MenuKeyLive $Root 900)) {
            Remove-Item $p.Cmd -Force -ErrorAction SilentlyContinue
            return $true
        }
    }
    Remove-Item $p.Cmd -Force -ErrorAction SilentlyContinue   # a pre-v1.0.2 copy never read it
    foreach ($proc in Get-HotkeyProcess) {
        try { Stop-Process -Id $proc.ProcessId -Force -Confirm:$false } catch {}
    }
    Start-Sleep -Milliseconds 400
    return (-not (Test-HotkeyRunning) -and -not (Test-MenuKeyLive $Root 900))
}

# Start the script (and keep the logon entry pointing at the right exe).
# Returns $null on success, or a sentence explaining why not.
function Start-HotkeyScript([string]$Root) {
    $p = Get-HotkeyPaths $Root
    if (-not (Test-Path $p.Script)) { return "CLIntKey.ahk is missing from app\ - re-run Install.bat." }
    $ahk = Find-AhkExe
    if (-not $ahk) { return "AutoHotkey v2 isn't installed (autohotkey.com)." }
    try { Register-HotkeyStartup $Root $ahk } catch {}   # no startup entry is survivable; no hotkey is not
    Clear-MenuKeyStatus $Root
    Start-Process $ahk -ArgumentList "`"$($p.Script)`""
    if (Wait-MenuKeyStatus $Root 4000) { return $null }
    # The UI Access build refuses to start on some systems, and a script that
    # died on launch looks identical to one that was never set up.
    $plain = $ahk -replace '_UIA', ''
    if ($ahk -match '_UIA' -and (Test-Path $plain)) {
        try { Register-HotkeyStartup $Root $plain } catch {}
        Start-Process $plain -ArgumentList "`"$($p.Script)`""
        if (Wait-MenuKeyStatus $Root 4000) { return $null }
    }
    return "The hotkey script didn't start. Try: `"$ahk`" `"$($p.Script)`""
}

# --- Applying a key ----------------------------------------------------

# Take the key out of service BEFORE anything else happens. Without this,
# re-binding the key you already use means pressing it while the old binding
# is still live, which opens CLInt over the top of the rebind. Returns
# @{ Ok; Message } - Ok=$false means something is still listening.
function Suspend-MenuKey([string]$Root) {
    $ok   = [pscustomobject]@{ Ok = $true;  Message = $null }
    $dead = 'A hotkey script is running with more privilege than CLInt has, so the old key cannot be released or replaced. Sign out and back in - or end AutoHotkey in Task Manager - then set the key again.'
    if (-not (Test-AnyAhkProcess)) { return $ok }
    Set-MenuKeyFile $Root 'off'
    $s = Resolve-MenuKeyLive $Root
    if ($s -and $s.State -eq 'off') { return $ok }
    # No answer: either nothing of ours is running, or a pre-v1.0.2 copy that
    # doesn't watch the file. The second can only be silenced by stopping it.
    if (Stop-HotkeyScript $Root) { return $ok }
    return [pscustomobject]@{ Ok = $false; Message = $dead }
}

# Bind $Key ('off' to unbind), starting or replacing the script as needed.
# Returns @{ Ok; Message }.
function Set-MenuKey([string]$Root, [string]$Key) {
    if (-not $Key) { $Key = 'off' }
    Set-MenuKeyFile $Root $Key
    # The happy path from v1.0.2 on: a running script notices the file and
    # re-binds itself. No process is started, stopped or replaced.
    $s = Resolve-MenuKeyLive $Root
    if (-not $s) {
        # Nothing answered. Clear out any deaf copy BEFORE starting ours -
        # letting #SingleInstance do it is what fails when the old copy is
        # busy or privileged.
        $stopped = Stop-HotkeyScript $Root
        if ($Key -eq 'off') {
            if ($stopped) { return [pscustomobject]@{ Ok = $true; Message = 'Menu key turned off.' } }
            return [pscustomobject]@{ Ok = $false
                Message = 'Menu key set to off, but a hotkey script CLInt cannot stop is still running. It goes away at your next sign-in.' }
        }
        $err = Start-HotkeyScript $Root
        if ($err) { return [pscustomobject]@{ Ok = $false; Message = $err } }
        $s = Get-MenuKeyStatus $Root
    }
    if ($Key -eq 'off') { return [pscustomobject]@{ Ok = $true; Message = 'Menu key turned off.' } }
    if ($s -and $s.State -eq 'ok' -and $s.Key -eq $Key) {
        return [pscustomobject]@{ Ok = $true; Message = "Menu key is live: $(Get-MenuKeyLabel $Key)  -  press it to test." }
    }
    if ($s -and $s.State -eq 'unknown') {
        return [pscustomobject]@{ Ok = $false
            Message = "'$Key' isn't a key AutoHotkey knows. Choose from the list instead." }
    }
    if ($s -and $s.State -eq 'fail') {
        return [pscustomobject]@{ Ok = $false
            Message = "Windows wouldn't hand over $(Get-MenuKeyLabel $Key) - another program already owns it. Pick a different key." }
    }
    return [pscustomobject]@{ Ok = $false; Message = 'The hotkey script never confirmed the key. Re-run Install.bat.' }
}

# --- The key list ------------------------------------------------------
# Names AutoHotkey understands, each with what it is worth knowing about it.
# Selecting from this list is the reliable route on keyboards where the key
# you want needs Fn held down: the console sees an Fn combination
# inconsistently (or not at all), but the key it SENDS is a plain F-key,
# and binding that by name works regardless.
function Get-MenuKeyChoices {
    $g1 = 'Spare F-keys (F13-F24)'; $g2 = 'Function keys (F1-F12)'
    $g3 = 'Special keys';           $g4 = 'Key combinations';        $g5 = 'Extra / media keys'
    $list = @()
    foreach ($n in 13..24) { $list += @{ Group = $g1; Key = "F$n"; Label = "F$n"; Hint = 'spare F-key - nothing else uses these' } }
    $list += @{ Group = $g3; Key = 'AppsKey';    Label = 'AppsKey';      Hint = 'menu key, next to right Ctrl (handheld "page" button)' }
    $list += @{ Group = $g3; Key = 'ScrollLock'; Label = 'ScrollLock';   Hint = 'safe - almost nothing reads it' }
    $list += @{ Group = $g3; Key = 'Pause';      Label = 'Pause/Break';  Hint = 'safe - almost nothing reads it' }
    $list += @{ Group = $g3; Key = 'PrintScreen';Label = 'PrintScreen';  Hint = 'takes over the screenshot key' }
    $list += @{ Group = $g3; Key = 'Insert';     Label = 'Insert';       Hint = 'safe on most keyboards' }
    foreach ($n in 1..12) { $list += @{ Group = $g2; Key = "F$n"; Label = "F$n"; Hint = 'pick it here if Fn+F-keys send plain F-keys' } }
    $list += @{ Group = $g4; Key = '^!m';   Label = 'Ctrl+Alt+M';     Hint = 'combination - safe anywhere, needs both hands' }
    $list += @{ Group = $g4; Key = '^!c';   Label = 'Ctrl+Alt+C';     Hint = 'combination - safe anywhere, needs both hands' }
    $list += @{ Group = $g4; Key = '^+F12'; Label = 'Ctrl+Shift+F12'; Hint = 'combination - safe anywhere' }
    $list += @{ Group = $g5; Key = 'Launch_App1';      Label = 'My Computer key';  Hint = 'extra key on some keyboards' }
    $list += @{ Group = $g5; Key = 'Launch_App2';      Label = 'Calculator key';   Hint = 'extra key on some keyboards' }
    $list += @{ Group = $g5; Key = 'Launch_Mail';      Label = 'Mail key';         Hint = 'extra key on some keyboards' }
    $list += @{ Group = $g5; Key = 'Media_Play_Pause'; Label = 'Play/Pause key';   Hint = 'media key - stops working as play/pause' }
    $list += @{ Group = $g5; Key = 'Media_Stop';       Label = 'Stop key';         Hint = 'media key - stops working as stop' }
    $list += @{ Group = $g5; Key = 'Browser_Home';     Label = 'Browser Home key'; Hint = 'extra key on some keyboards' }
    $list += @{ Group = $g5; Key = 'NumpadMult';       Label = 'Numpad *';         Hint = 'numeric keypad' }
    $list += @{ Group = $g5; Key = 'NumpadDiv';        Label = 'Numpad /';         Hint = 'numeric keypad' }
    return @($list | ForEach-Object { [pscustomobject]$_ })
}
# Group names in list order - the installer's console chooser can only show
# a screenful at a time, so it asks for a group first.
function Get-MenuKeyGroups {
    $seen = @(); $out = @()
    foreach ($c in Get-MenuKeyChoices) { if ($seen -notcontains $c.Group) { $seen += $c.Group; $out += $c.Group } }
    return $out
}

# Friendly name for whatever is in menu-key.txt, including keys captured by
# raw virtual-key code (vk5D) that the list above never mentions.
function Get-MenuKeyLabel([string]$Key) {
    if (-not $Key -or $Key -eq 'off') { return 'off' }
    $hit = @(Get-MenuKeyChoices | Where-Object { $_.Key -eq $Key })
    if ($hit.Count) { return $hit[0].Label }
    $mods = ''
    $base = $Key
    while ($base.Length -gt 1 -and '^!+#'.Contains($base[0])) {
        $mods += switch ($base[0]) { '^' { 'Ctrl+' } '!' { 'Alt+' } '+' { 'Shift+' } '#' { 'Win+' } }
        $base = $base.Substring(1)
    }
    $named = @(Get-MenuKeyChoices | Where-Object { $_.Key -eq $base })
    if ($named.Count) { return $mods + $named[0].Label }
    if ($base -match '^vk([0-9A-Fa-f]{2})$') {
        $vk = [Convert]::ToInt32($Matches[1], 16)
        # A printable key is worth spelling out - it is also the one binding
        # people regret, because it then opens the menu every time they type.
        if ($vk -ge 0x30 -and $vk -le 0x5A) { return $mods + [char]$vk }
        return $mods + $base
    }
    return $mods + $base
}

# One line for the SETTINGS row. Deliberately file-only (no process query):
# this runs every time the settings list is rebuilt, and Win32_Process there
# would stall the menu. The real "is it running" check happens when the user
# opens the menu-key screen, where a pause costs nothing.
function Get-MenuKeySummary([string]$Root) {
    $name   = Get-MenuKeyName $Root
    $status = Get-MenuKeyStatus $Root
    # No file yet, but a script reporting in: it is running on its built-in
    # default, so show what is actually bound rather than "off".
    if (-not $name -and $status) { $name = $status.Key }
    if (-not $name) { return 'not set' }
    $label = Get-MenuKeyLabel $name
    if ($status -and $status.Key -eq $name -and $status.State -in 'fail', 'unknown') {
        return "$label  (not working - open to fix)"
    }
    return $label
}

# A console keypress -> an AutoHotkey key name. Modifiers included, so
# Ctrl+Alt+M captures as "^!vk4D".
function Convert-KeyPressToAhk($KeyInfo) {
    $vk = [int]$KeyInfo.Key
    if ($vk -eq 0) { return $null }
    $prefix = ''
    if (($KeyInfo.Modifiers -band [ConsoleModifiers]::Control) -ne 0) { $prefix += '^' }
    if (($KeyInfo.Modifiers -band [ConsoleModifiers]::Alt)     -ne 0) { $prefix += '!' }
    if (($KeyInfo.Modifiers -band [ConsoleModifiers]::Shift)   -ne 0) { $prefix += '+' }
    $base = if ($vk -ge 0x70 -and $vk -le 0x87) { "F$($vk - 0x6F)" }        # F1-F24
            elseif ($vk -eq 0x5D) { 'AppsKey' }
            else { 'vk{0:X2}' -f $vk }                                       # AutoHotkey takes raw VK codes
    return $prefix + $base
}

# Bare letters, digits and space open the menu every time they are typed,
# everywhere - worth saying out loud before someone commits to one.
function Test-MenuKeyIsTypingKey([string]$Key) {
    if ($Key -match '^vk([0-9A-Fa-f]{2})$') {
        $vk = [Convert]::ToInt32($Matches[1], 16)
        return ($vk -ge 0x30 -and $vk -le 0x5A) -or $vk -eq 0x20
    }
    return $false
}
