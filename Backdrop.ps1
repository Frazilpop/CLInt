# Backdrop.ps1 - solid black fullscreen window kept just behind the CLInt
# console. Conhost's fullscreen mode quantizes to whole character cells;
# the leftover edge strips are supposed to be painted black by conhost,
# but some (mostly older) graphics stacks leave stale pixels there. This
# window owns those pixels instead.
#
# Launched by CLInt.ps1; exits by itself when the menu process is gone.
# Only visible while the console is the foreground window, so it never
# blacks out the desktop when the menu is minimized or in the background.

param(
    [Parameter(Mandatory)] [int]   $OwnerPid,
    [Parameter(Mandatory)] [int64] $ConsoleHwnd
)

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type -Namespace CLIntBd -Name Win -MemberDefinition @'
[DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
[DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr h, IntPtr after, int x, int y, int cx, int cy, uint flags);
'@

$conHwnd = [IntPtr]$ConsoleHwnd

$f = New-Object System.Windows.Forms.Form
$f.FormBorderStyle = 'None'
$f.StartPosition   = 'Manual'
$f.Bounds          = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
$f.BackColor       = [System.Drawing.Color]::Black
$f.ShowInTaskbar   = $false
$f.Visible         = $false

$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 300
$timer.Add_Tick({
    if (-not (Get-Process -Id $OwnerPid -ErrorAction SilentlyContinue)) {
        [System.Windows.Forms.Application]::Exit()
        return
    }
    $isFg = [CLIntBd.Win]::GetForegroundWindow() -eq $conHwnd
    if ($isFg -and -not $f.Visible) {
        $f.Visible = $true
        # slot in directly beneath the console, without taking focus
        # (0x0010 SWP_NOACTIVATE | 0x0002 SWP_NOMOVE | 0x0001 SWP_NOSIZE)
        [CLIntBd.Win]::SetWindowPos($f.Handle, $conHwnd, 0, 0, 0, 0, 0x0013) | Out-Null
    } elseif (-not $isFg -and $f.Visible) {
        $f.Visible = $false
    }
})
$timer.Start()

[System.Windows.Forms.Application]::Run()
