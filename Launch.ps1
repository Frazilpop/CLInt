# Launch.ps1 - single-instance launcher for the CLInt menu.
# If the menu window already exists, the shortcut behaves like a taskbar
# button: bring it to the front, or minimize it if it's already in front.
# Only when no instance is running does it start a new fullscreen terminal.

$ErrorActionPreference = 'SilentlyContinue'

Add-Type -Namespace Win32 -Name Native -MemberDefinition @'
[DllImport("user32.dll", CharSet = CharSet.Unicode)]
public static extern IntPtr FindWindowW(string cls, string title);
[DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
[DllImport("user32.dll")] public static extern bool IsIconic(IntPtr h);
[DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int cmd);
[DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
'@

$hwnd = [Win32.Native]::FindWindowW($null, 'CLInt')
if ($hwnd -ne [IntPtr]::Zero) {
    # Minimized wins over "foreground": right after minimizing, Windows can
    # still report the window as foreground, which made a second press no-op.
    if ([Win32.Native]::IsIconic($hwnd)) {
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
    "powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"$PSScriptRoot\CLInt.ps1`""
# Focus-steal protection can leave the new window fullscreen but unfocused,
# with the previous app still eating gamepad input; activate it explicitly.
for ($i = 0; $i -lt 40; $i++) {
    Start-Sleep -Milliseconds 250
    $new = [Win32.Native]::FindWindowW($null, 'CLInt')
    if ($new -ne [IntPtr]::Zero) {
        [Win32.Native]::SetForegroundWindow($new) | Out-Null
        break
    }
}
