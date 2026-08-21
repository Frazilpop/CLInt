# Launch.ps1 - single-instance launcher for the CLInt menu.
# If the menu window already exists, the shortcut behaves like a taskbar
# button: bring it to the front, or minimize it if it's already in front.
# Only when no instance is running does it start a new fullscreen terminal.
# A film playing in the built-in player is closed first, because the icon
# means "take me to CLInt" and the film is what is standing in the way.

$ErrorActionPreference = 'SilentlyContinue'

Add-Type -Namespace Win32 -Name Native -MemberDefinition @'
[DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
[DllImport("user32.dll")] public static extern bool IsIconic(IntPtr h);
[DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int cmd);
[DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
[DllImport("user32.dll")] public static extern bool IsWindow(IntPtr h);
[DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
[DllImport("user32.dll")] public static extern bool PostMessage(IntPtr h, uint msg, IntPtr w, IntPtr l);
[DllImport("user32.dll")] public static extern int GetWindowThreadProcessId(IntPtr h, out int pid);
[DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetWindowText(IntPtr h, System.Text.StringBuilder buf, int n);
'@

function Find-CLIntWindow {
    # CLInt.ps1 records its own console window handle at startup, so the
    # usual case is one existence check. Handle AND title have to match: a
    # stale file left behind by a crash must resolve to nothing rather than
    # to an unrelated window Windows has recycled the handle for.
    try {
        $h = [IntPtr][int64](Get-Content (Join-Path $PSScriptRoot 'data\clint.hwnd') -TotalCount 1).Trim()
        if ([Win32.Native]::IsWindow($h)) {
            $sb = New-Object System.Text.StringBuilder 32
            [void][Win32.Native]::GetWindowText($h, $sb, $sb.Capacity)
            if ($sb.ToString() -eq 'CLInt') { return $h }
        }
    } catch {}
    # Fallback for an instance that started before this version: find it by
    # OWNER, not by window title, because any other console sitting in a
    # folder named CLInt (a dev shell, Claude Code's own conhost) carries
    # the identical title, and title-matching used to grab whichever was
    # higher in z-order. Console windows report the attached shell's PID,
    # so the real menu is the powershell running CLInt.ps1.
    foreach ($p in Get-CimInstance Win32_Process -Filter "Name='powershell.exe'") {
        if ($p.ProcessId -ne $PID -and $p.CommandLine -like '*CLInt.ps1*') {
            $wnd = (Get-Process -Id $p.ProcessId -ErrorAction SilentlyContinue).MainWindowHandle
            if ([int64]$wnd -ne 0) { return $wnd }   # 0 = hidden or gone (e.g. a test probe)
        }
    }
    return [IntPtr]::Zero
}

# The built-in player announces its window in player.hwnd for exactly this
# kind of question (CLIntKey.ahk asks it too) and removes the file on the
# way out. A hard crash removes nothing, so the file alone proves nothing:
# the handle has to still be a window, and that window has to still belong
# to a Player.ps1. Title is no use here - the player names its window
# 'CLInt' as well, so a recycled handle could be the MENU'S console, and
# what happens next is a close.
function Find-PlayerWindow {
    try {
        $f = Join-Path $PSScriptRoot 'data\player.hwnd'
        if (-not (Test-Path $f)) { return [IntPtr]::Zero }
        $h = [IntPtr][int64](Get-Content $f -TotalCount 1).Trim()
        if (-not [Win32.Native]::IsWindow($h)) { return [IntPtr]::Zero }
        $ppid = 0
        [void][Win32.Native]::GetWindowThreadProcessId($h, [ref]$ppid)
        if ($ppid -eq 0) { return [IntPtr]::Zero }
        $cmd = (Get-CimInstance Win32_Process -Filter "ProcessId=$ppid").CommandLine
        if ($cmd -like '*Player.ps1*') { return $h }
    } catch {}
    return [IntPtr]::Zero
}

# A film is playing, so the menu is not reachable: windowed, the player
# HIDES the console outright (a small film window with a fullscreen CLInt
# behind it reads as two programs), and a hidden window cannot be brought
# to the front - which is why the shortcut used to look dead. Fullscreen,
# the console is merely buried. Either way the icon means the same thing,
# and the honest answer to it is to end the film.
#
# WM_CLOSE, not a kill: it is the same close the player performs for Esc,
# so the resume position and the watched flag are written, and CLInt - which
# is sitting in a loop waiting on the player's process - takes the screen
# back on its own within a tick or two.
$pwnd = Find-PlayerWindow
if ($pwnd -ne [IntPtr]::Zero) {
    [Win32.Native]::PostMessage($pwnd, 0x0010, [IntPtr]::Zero, [IntPtr]::Zero) | Out-Null
    # Wait for the film to actually go, then for CLInt to put its own window
    # back up. Both are bounded: a player that will not close, or a menu that
    # died while the film was up, must still leave the code below able to
    # unhide what is there or start a fresh instance.
    for ($i = 0; $i -lt 60; $i++) {
        if (-not [Win32.Native]::IsWindow($pwnd)) { break }
        Start-Sleep -Milliseconds 100
    }
    $menu = Find-CLIntWindow
    if ($menu -ne [IntPtr]::Zero) {
        for ($i = 0; $i -lt 30; $i++) {
            if ([Win32.Native]::IsWindowVisible($menu)) { break }
            Start-Sleep -Milliseconds 100
        }
    }
}

$hwnd = Find-CLIntWindow
if ($hwnd -ne [IntPtr]::Zero) {
    # Hidden wins over everything: the only thing that hides the menu is a
    # film, so this is a player that died without CLInt noticing yet, or one
    # that would not answer the close above. Whatever left it invisible, an
    # invisible window cannot be raised or minimized - it has to be put back
    # on screen first, or the shortcut does nothing at all.
    if (-not [Win32.Native]::IsWindowVisible($hwnd)) {
        [Win32.Native]::ShowWindow($hwnd, 5) | Out-Null           # SW_SHOW
        [Win32.Native]::SetForegroundWindow($hwnd) | Out-Null
    }
    # Minimized wins over "foreground": right after minimizing, Windows can
    # still report the window as foreground, which made a second press no-op.
    elseif ([Win32.Native]::IsIconic($hwnd)) {
        [Win32.Native]::ShowWindow($hwnd, 9) | Out-Null       # SW_RESTORE
        [Win32.Native]::SetForegroundWindow($hwnd) | Out-Null
    } elseif ([Win32.Native]::GetForegroundWindow() -eq $hwnd) {
        [Win32.Native]::ShowWindow($hwnd, 6) | Out-Null       # SW_MINIMIZE
    } else {
        [Win32.Native]::SetForegroundWindow($hwnd) | Out-Null
    }
    exit 0
}

# conhost, NOT Windows Terminal: WT's WinUI tab bar responds to the physical
# gamepad (XAML directional navigation, not disableable) and steals focus.
# Conhost has no WinUI, and CLInt.ps1 makes it borderless fullscreen.
Start-Process "$env:SystemRoot\System32\conhost.exe" -ArgumentList `
    "powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"$PSScriptRoot\app\CLInt.ps1`""
# Focus-steal protection can leave the new window fullscreen but unfocused,
# with the previous app still eating gamepad input; activate it explicitly.
for ($i = 0; $i -lt 40; $i++) {
    Start-Sleep -Milliseconds 250
    $new = Find-CLIntWindow
    if ($new -ne [IntPtr]::Zero) {
        [Win32.Native]::SetForegroundWindow($new) | Out-Null
        break
    }
}
