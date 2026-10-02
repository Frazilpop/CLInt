# Player.ps1 - CLInt's built-in video player. Fullscreen by default;
# F, Alt+Enter or a double-click on the picture drop it into a resizable
# window and back (the same three toggles VLC itself answers to).
#
# Runs as its own process, not inside CLInt. Two reasons, and the first is
# the hard one: the engine is the libvlc that ships inside an installed
# VLC, and a 32-bit VLC cannot be loaded into 64-bit PowerShell. CLInt
# reads libvlc's PE header and launches this script with the matching
# host, so the bitness question is settled before we get here. The second
# reason falls out for free - a codec that takes the process down takes
# the player with it, and CLInt is still sitting there when it happens.
#
# CLInt hands over a file and a start position, and gets back a state file
# saying where playback stopped and whether anything played to the end.
# That is the whole contract: no window handles are shared, nothing is
# called back into, and killing this process at any moment costs at most
# the last few seconds of resume position.
#
# It also hands over its look. This is a WinForms window rather than a
# console, but nothing about that should show: the overlay is drawn on a
# character grid, in the console font at the console's size, in the
# console's own colours, with no transparency anywhere. Someone pressing A
# on a video should not feel they have left the menu.
param(
    # Not -File: that is powershell.exe's own switch, and the two would be
    # indistinguishable on the command line CLInt builds.
    [Parameter(Mandatory)][string]$Video,
    [Parameter(Mandatory)][string]$VlcDir,
    [int]$Start = 0,                  # resume position in seconds (0 = from the top)
    [string]$StateFile,               # where to write results for CLInt
    # CLInt's palette as Role=RRGGBB pairs (Bg, Accent, Logo, ...), already
    # resolved from the live console colour table on its side - see
    # Get-ThemeRgbArg there. Every role has a default here, so the player
    # still runs standalone for a quick test.
    [string]$Theme = '',
    # The console font height CLInt is using, in scaled pixels (its
    # CONSOLE_FONT_INFOEX.SizeY - 20/28/34 for small/medium/large).
    [int]$TextPx = 28,
    [string]$Accent = '',             # older CLInt: a ConsoleColor name, accent only
    # Which buttons the hint row names, from CLInt's own SETTINGS so the
    # overlay and the menu speak the same one. Anything but 'keyboard'
    # means the gamepad set.
    [string]$Controls = 'gamepad',
    # Drop the bottom row of button hints (SETTINGS -> Video settings). The
    # overlay loses exactly that row's height; nothing else moves.
    [switch]$NoHints,
    # Start every file with subtitles showing (SETTINGS -> Video settings).
    # Absent means off: a file carrying a subtitle track is not a reason to
    # put it on screen. Either way X cycles them by hand during playback.
    [switch]$Subtitles,
    # Open windowed instead of fullscreen. CLInt passes this when its own
    # menu is in windowed mode: display mode is something the user chose
    # once, not per program, so the film opens the way the menu was. The
    # mode at EXIT travels back the same way, in the state file's Windowed
    # field.
    [switch]$Windowed,
    [int]$Volume = 100,               # starting volume, in percent (see $VOL_MAX)
    # Past this percentage of the file, stopping still counts as a full
    # watch (SETTINGS -> Video settings) - nobody owes the credits a
    # viewing. 100 keeps the strict rule: only the last half-minute counts.
    [int]$WatchedPct = 100
)

$ErrorActionPreference = 'Stop'

# --------------------------------------------------------------- libvlc ---
# Only the calls this player actually makes. libvlc's ABI is stable across
# 3.x, and everything here has existed since 2.x - no version probing.
Add-Type -Namespace CLIntVlc -Name N -MemberDefinition @'
[DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
public static extern IntPtr LoadLibraryW(string lpFileName);
[DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
public static extern IntPtr LoadLibraryExW(string lpFileName, IntPtr hFile, uint dwFlags);
[DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
public static extern bool SetDllDirectoryW(string lpPathName);
[DllImport("kernel32.dll")]
private static extern uint SetThreadExecutionState(uint esFlags);
// Kept on this side of the boundary because PowerShell reads 0x80000000 as
// a negative Int32 and the marshaller then refuses it as a DWORD.
public static void KeepAwake(bool on) {
    const uint ES_CONTINUOUS = 0x80000000, ES_SYSTEM_REQUIRED = 0x1, ES_DISPLAY_REQUIRED = 0x2;
    SetThreadExecutionState(on ? (ES_CONTINUOUS | ES_SYSTEM_REQUIRED | ES_DISPLAY_REQUIRED)
                               : ES_CONTINUOUS);
}
[DllImport("user32.dll")]
public static extern bool SetForegroundWindow(IntPtr hWnd);
[DllImport("user32.dll")]
public static extern IntPtr GetForegroundWindow();
[DllImport("user32.dll")]
public static extern short GetAsyncKeyState(int vKey);
[DllImport("user32.dll")]
public static extern uint GetDoubleClickTime();
[DllImport("user32.dll")]
public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
[DllImport("user32.dll")]
public static extern bool IsWindow(IntPtr hWnd);
[DllImport("user32.dll")]
public static extern bool IsWindowVisible(IntPtr hWnd);
[DllImport("user32.dll", CharSet = CharSet.Unicode)]
private static extern int GetWindowTextW(IntPtr hWnd, System.Text.StringBuilder sb, int max);
public static string WindowTitle(IntPtr hWnd) {
    var sb = new System.Text.StringBuilder(64);
    GetWindowTextW(hWnd, sb, 64);
    return sb.ToString();
}
[DllImport("dwmapi.dll")]
private static extern int DwmSetWindowAttribute(IntPtr hwnd, int attr, ref int val, int size);
// DWMWA_TRANSITIONS_FORCEDISABLED (3): while set, DWM plays no
// minimize/maximize/restore animation for the window. Wrapped because the
// attribute is an int-sized BOOL passed by reference - not marshalling to
// do in script.
public static void SetTransitions(IntPtr hwnd, bool enabled) {
    int disabled = enabled ? 0 : 1;
    DwmSetWindowAttribute(hwnd, 3, ref disabled, 4);
}
[StructLayout(LayoutKind.Sequential)]
public struct RECT { public int L; public int T; public int R; public int B; }
[DllImport("user32.dll")]
public static extern bool GetWindowRect(IntPtr hWnd, out RECT r);

[DllImport("libvlc.dll", CallingConvention = CallingConvention.Cdecl)]
public static extern IntPtr libvlc_new(int argc, string[] argv);
[DllImport("libvlc.dll", CallingConvention = CallingConvention.Cdecl)]
public static extern void libvlc_release(IntPtr inst);
[DllImport("libvlc.dll", CallingConvention = CallingConvention.Cdecl)]
public static extern IntPtr libvlc_media_new_path(IntPtr inst, string path);
[DllImport("libvlc.dll", CallingConvention = CallingConvention.Cdecl)]
public static extern void libvlc_media_release(IntPtr media);
[DllImport("libvlc.dll", CallingConvention = CallingConvention.Cdecl)]
public static extern IntPtr libvlc_media_player_new_from_media(IntPtr media);
[DllImport("libvlc.dll", CallingConvention = CallingConvention.Cdecl)]
public static extern void libvlc_media_player_release(IntPtr mp);
[DllImport("libvlc.dll", CallingConvention = CallingConvention.Cdecl)]
public static extern int libvlc_media_player_play(IntPtr mp);
[DllImport("libvlc.dll", CallingConvention = CallingConvention.Cdecl)]
public static extern void libvlc_media_player_stop(IntPtr mp);
[DllImport("libvlc.dll", CallingConvention = CallingConvention.Cdecl)]
public static extern void libvlc_media_player_set_hwnd(IntPtr mp, IntPtr drawable);
[DllImport("libvlc.dll", CallingConvention = CallingConvention.Cdecl)]
public static extern void libvlc_video_set_key_input(IntPtr mp, uint on);
[DllImport("libvlc.dll", CallingConvention = CallingConvention.Cdecl)]
public static extern void libvlc_video_set_mouse_input(IntPtr mp, uint on);
[DllImport("libvlc.dll", CallingConvention = CallingConvention.Cdecl)]
public static extern long libvlc_media_player_get_length(IntPtr mp);
[DllImport("libvlc.dll", CallingConvention = CallingConvention.Cdecl)]
public static extern long libvlc_media_player_get_time(IntPtr mp);
[DllImport("libvlc.dll", CallingConvention = CallingConvention.Cdecl)]
public static extern void libvlc_media_player_set_time(IntPtr mp, long t);
[DllImport("libvlc.dll", CallingConvention = CallingConvention.Cdecl)]
public static extern void libvlc_media_player_set_pause(IntPtr mp, int pause);
[DllImport("libvlc.dll", CallingConvention = CallingConvention.Cdecl)]
public static extern int libvlc_media_player_is_playing(IntPtr mp);
[DllImport("libvlc.dll", CallingConvention = CallingConvention.Cdecl)]
public static extern int libvlc_media_player_get_state(IntPtr mp);
[DllImport("libvlc.dll", CallingConvention = CallingConvention.Cdecl)]
public static extern int libvlc_video_get_spu_count(IntPtr mp);
[DllImport("libvlc.dll", CallingConvention = CallingConvention.Cdecl)]
public static extern int libvlc_video_get_spu(IntPtr mp);
[DllImport("libvlc.dll", CallingConvention = CallingConvention.Cdecl)]
public static extern int libvlc_video_set_spu(IntPtr mp, int spu);
[DllImport("libvlc.dll", CallingConvention = CallingConvention.Cdecl)]
public static extern IntPtr libvlc_video_get_spu_description(IntPtr mp);
[DllImport("libvlc.dll", CallingConvention = CallingConvention.Cdecl)]
public static extern int libvlc_audio_get_track(IntPtr mp);
[DllImport("libvlc.dll", CallingConvention = CallingConvention.Cdecl)]
public static extern int libvlc_audio_set_track(IntPtr mp, int track);
[DllImport("libvlc.dll", CallingConvention = CallingConvention.Cdecl)]
public static extern IntPtr libvlc_audio_get_track_description(IntPtr mp);
[DllImport("libvlc.dll", CallingConvention = CallingConvention.Cdecl)]
public static extern void libvlc_track_description_list_release(IntPtr p);
[DllImport("libvlc.dll", CallingConvention = CallingConvention.Cdecl)]
public static extern int libvlc_audio_set_volume(IntPtr mp, int volume);
[DllImport("libvlc.dll", CallingConvention = CallingConvention.Cdecl)]
public static extern void libvlc_audio_set_mute(IntPtr mp, int status);
[DllImport("libvlc.dll", CallingConvention = CallingConvention.Cdecl)]
public static extern int libvlc_video_get_size(IntPtr mp, uint num, out uint px, out uint py);

// --- taskbar identity: the same one CLInt puts on its own window (see
// Set-MenuIdentity there), so the menu and the film are one button.
[DllImport("user32.dll")]
public static extern bool SetWindowPos(IntPtr hWnd, IntPtr after, int x, int y, int cx, int cy, uint flags);
[DllImport("shell32.dll")]
static extern int SHGetPropertyStoreForWindow(IntPtr hwnd, ref Guid iid, out IPropStore store);
[StructLayout(LayoutKind.Sequential, Pack = 4)] public struct PKEY { public Guid fmtid; public uint pid; }
[StructLayout(LayoutKind.Explicit, Size = 24)] public struct PVAR { [FieldOffset(0)] public ushort vt; [FieldOffset(8)] public IntPtr p; }
[ComImport, Guid("886D8EEB-8CF2-4446-8D02-CDBA1DBDCF99"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
public interface IPropStore {
    [PreserveSig] int GetCount(out uint c);
    [PreserveSig] int GetAt(uint i, out PKEY k);
    [PreserveSig] int GetValue(ref PKEY k, out PVAR v);
    [PreserveSig] int SetValue(ref PKEY k, ref PVAR v);
    [PreserveSig] int Commit();
}
[ComImport, Guid("602D4995-B13A-429b-A66E-1935E44F4317"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
public interface ITaskbarList {   // ITaskbarList2
    [PreserveSig] int HrInit();
    [PreserveSig] int AddTab(IntPtr hwnd);
    [PreserveSig] int DeleteTab(IntPtr hwnd);
    [PreserveSig] int ActivateTab(IntPtr hwnd);
    [PreserveSig] int SetActiveAlt(IntPtr hwnd);
    [PreserveSig] int MarkFullscreenWindow(IntPtr hwnd, [MarshalAs(UnmanagedType.Bool)] bool full);
}
static void PutProp(IPropStore ps, uint pid, string val) {
    PKEY k = new PKEY(); k.fmtid = new Guid("9F4C2855-9F79-4B39-A8D0-E1D42DE1D5F3"); k.pid = pid;
    PVAR v = new PVAR();
    if (val != null) { v.vt = 31; v.p = Marshal.StringToCoTaskMemUni(val); }   // VT_LPWSTR
    ps.SetValue(ref k, ref v);
    if (val != null) Marshal.FreeCoTaskMem(v.p);
}
// System.AppUserModel.* on one window: RelaunchCommand (2),
// RelaunchIconResource (3), RelaunchDisplayNameResource (4), then ID (5).
public static bool SetAppIdentity(IntPtr hwnd, string id, string command, string icon, string name) {
    Guid iid = new Guid("886D8EEB-8CF2-4446-8D02-CDBA1DBDCF99");
    IPropStore ps;
    if (SHGetPropertyStoreForWindow(hwnd, ref iid, out ps) != 0 || ps == null) return false;
    try {
        PutProp(ps, 2, command);
        PutProp(ps, 3, icon);
        PutProp(ps, 4, command == null ? null : name);
        PutProp(ps, 5, id);
        ps.Commit();
    } finally { Marshal.ReleaseComObject(ps); }
    return true;
}
// A button going back on can be marked fullscreen in the same breath - see
// Set-MenuTab for why it has to be.
public static void TaskbarTab(IntPtr hwnd, bool show, bool fullscreen) {
    ITaskbarList t = (ITaskbarList)Activator.CreateInstance(Type.GetTypeFromCLSID(new Guid("56FDF344-FD6D-11d0-958A-006097C9A090")));
    try {
        t.HrInit();
        if (show) { t.AddTab(hwnd); if (fullscreen) t.MarkFullscreenWindow(hwnd, true); }
        else t.DeleteTab(hwnd);
    }
    finally { Marshal.ReleaseComObject(t); }
}
'@

# --- Subtitle margin ------------------------------------------------------
# Lifting the subtitles clear of the overlay means changing "sub-margin" on
# a video output that is already running, and libvlc's public API has no
# call for that - VLC's own interface sets the variable on the vout object
# directly, so this does the same through libvlccore. The vout is found by
# asking each object under the player whether it HAS the variable (only a
# vout does), which needs no knowledge of how the tree is arranged.
#
# That is reaching past the stable ABI, so it is fenced: libvlc 3.x only
# (the list struct read here is 3.x's), and a type of its own so that a
# build missing any of these exports costs the feature and nothing else.
$script:marginOk = $true
try {
    Add-Type -Namespace CLIntVlc -Name Core -MemberDefinition @'
[DllImport("libvlc.dll", CallingConvention = CallingConvention.Cdecl)]
private static extern IntPtr libvlc_get_version();
[DllImport("libvlccore.dll", CallingConvention = CallingConvention.Cdecl)]
private static extern IntPtr vlc_list_children(IntPtr obj);
[DllImport("libvlccore.dll", CallingConvention = CallingConvention.Cdecl)]
private static extern void vlc_list_release(IntPtr list);
[DllImport("libvlccore.dll", CallingConvention = CallingConvention.Cdecl)]
private static extern int var_Type(IntPtr obj, string name);
[DllImport("libvlccore.dll", CallingConvention = CallingConvention.Cdecl)]
private static extern int var_GetChecked(IntPtr obj, string name, int type, out long val);
[DllImport("libvlccore.dll", CallingConvention = CallingConvention.Cdecl)]
private static extern int var_SetChecked(IntPtr obj, string name, int type, long val);
private const int VLC_VAR_INTEGER = 0x0030;
public static bool Supported() {
    string v = Marshal.PtrToStringAnsi(libvlc_get_version());
    return v != null && v.StartsWith("3.");
}
// True when a vout was found. Written only when the value differs: a set
// wakes the vout, and this is asked five times a second.
public static bool SetSubMargin(IntPtr obj, int px, int depth) {
    IntPtr list = vlc_list_children(obj);
    if (list == IntPtr.Zero) return false;
    bool hit = false;
    try {
        // vlc_list_t: int i_type; int i_count; vlc_value_t *p_values - and a
        // vlc_value_t is eight bytes on either bitness.
        int n = Marshal.ReadInt32(list, 4);
        IntPtr vals = Marshal.ReadIntPtr(list, 8);
        if (n < 0 || n > 64 || vals == IntPtr.Zero) return false;
        for (int i = 0; i < n; i++) {
            IntPtr child = Marshal.ReadIntPtr(vals, i * 8);
            if (child == IntPtr.Zero) continue;
            if (var_Type(child, "sub-margin") != 0) {
                long cur;
                if (var_GetChecked(child, "sub-margin", VLC_VAR_INTEGER, out cur) != 0 || cur != px)
                    var_SetChecked(child, "sub-margin", VLC_VAR_INTEGER, px);
                hit = true;
            } else if (depth > 1 && SetSubMargin(child, px, depth - 1)) {
                hit = true;
            }
        }
    } finally { vlc_list_release(list); }
    return hit;
}
'@
} catch { $script:marginOk = $false }

# --- Native gamepad input (XInput) -------------------------------------
# The same reading CLInt's menu does, minus the auto-repeat table: a video
# player repeats different things (seek and volume, never a track cycle),
# so the repeat rules live with the key map below instead.
$script:padOk = $true
try {
    Add-Type -Namespace CLIntVlc -Name Pad -MemberDefinition @'
[StructLayout(LayoutKind.Sequential)]
private struct XINPUT_GAMEPAD { public ushort wButtons; public byte bLeftTrigger; public byte bRightTrigger; public short sThumbLX; public short sThumbLY; public short sThumbRX; public short sThumbRY; }
[StructLayout(LayoutKind.Sequential)]
private struct XINPUT_STATE { public uint dwPacketNumber; public XINPUT_GAMEPAD Gamepad; }
[DllImport("xinput1_4.dll")]
private static extern uint XInputGetState(uint dwUserIndex, ref XINPUT_STATE pState);
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

Add-Type -AssemblyName System.Windows.Forms, System.Drawing

# Before any control exists on this thread, or WinForms refuses to change it.
# Without this a WinForms exception raises the stock "Unhandled exception"
# dialog - a modal box over a fullscreen video, on a machine that may have no
# keyboard and no pointer to dismiss it with. Letting it throw instead means
# the run ends, the screen is put back, and CLInt gets a non-zero exit.
try {
    [Windows.Forms.Application]::SetUnhandledExceptionMode(
        [Windows.Forms.UnhandledExceptionMode]::ThrowException)
} catch {}

# The OSD is a second, owned window sitting over the video. It has to be,
# because libvlc's video output is a child window of its own that paints
# straight over anything on the form beneath it. Owned means it can never
# fall behind the video; NOACTIVATE means showing it cannot pull focus off
# the player and strand the key handlers.
Add-Type -ReferencedAssemblies System.Windows.Forms, System.Drawing -TypeDefinition @'
using System;
using System.Windows.Forms;
public class ClintOsdForm : Form {
    public ClintOsdForm() {
        // The strip is opaque and repaints five times a second while it is
        // up. Without double buffering that reads as a flicker over the
        // video, which is exactly the sort of thing the menu never does.
        SetStyle(ControlStyles.OptimizedDoubleBuffer | ControlStyles.AllPaintingInWmPaint |
                 ControlStyles.UserPaint, true);
    }
    protected override bool ShowWithoutActivation { get { return true; } }
    protected override CreateParams CreateParams {
        get {
            CreateParams cp = base.CreateParams;
            cp.ExStyle |= 0x08000000;   // WS_EX_NOACTIVATE
            cp.ExStyle |= 0x00000080;   // WS_EX_TOOLWINDOW - keep it off alt-tab
            return cp;
        }
    }
}
'@

# ----------------------------------------------------------- the engine ---
$env:VLC_PLUGIN_PATH = Join-Path $VlcDir 'plugins'
[CLIntVlc.N]::SetDllDirectoryW($VlcDir) | Out-Null
[CLIntVlc.N]::LoadLibraryW((Join-Path $VlcDir 'libvlccore.dll')) | Out-Null
# LOAD_WITH_ALTERED_SEARCH_PATH: libvlc.dll's own folder is where its
# dependencies live, and that folder is not on any search path of ours.
if ([CLIntVlc.N]::LoadLibraryExW((Join-Path $VlcDir 'libvlc.dll'), [IntPtr]::Zero, 0x8) -eq [IntPtr]::Zero) {
    exit 2   # CLInt treats a non-zero exit as "engine unavailable" and says so
}

# --no-video-title-show / --no-osd: this player draws its own overlay, and
# VLC's would sit on top of it saying the same thing twice.
$vlcArgs = @(
    '--no-video-title-show'
    '--no-osd'
    '--no-snapshot-preview'
    '--quiet'
    '--no-stats'
)
$inst = [CLIntVlc.N]::libvlc_new($vlcArgs.Count, $vlcArgs)
if ($inst -eq [IntPtr]::Zero) { exit 2 }
if ($script:marginOk) {
    try { $script:marginOk = [CLIntVlc.Core]::Supported() } catch { $script:marginOk = $false }
}

# --------------------------------------------------------------- state ---
$script:mp        = [IntPtr]::Zero
$script:media     = [IntPtr]::Zero
$script:current   = $Video
$script:results   = @{}          # path -> @{ Seconds; Finished }
$script:lastTime  = 0            # last good position, for the resume write
$script:lastLen   = 0
$script:paused    = $false
# Volume ceiling. 100 stays exactly what it always was - nominal, 0 dB, the
# track at the level it was mastered - and everything above it is libvlc
# amplifying in software, the same thing VLC's own slider does past 100%.
# Quiet dialogue in a film mixed for a cinema is the case this is for.
#
# Past 100 there is nothing left in the headroom, so peaks clip: loud
# passages distort, and the louder the setting the more of the track is
# loud enough to be caught. That is inherent to amplifying an already
# mastered mix, not a bug to be fixed here, and 150 is about as far as it
# stays worth having.
$VOL_MAX = 150
$script:volume    = [Math]::Max(0, [Math]::Min($VOL_MAX, $Volume))
$script:seekTo    = $Start
$script:osdUntil  = 0            # tick count the OSD hides at (0 = hidden)
$script:osdPinned = $false
$script:osdNote   = ''           # transient right-hand message ("Volume 60%")
$script:quitting  = $false
# Subtitle auto-pick, once per file. See the block in the timer that uses it.
$script:subsPicked = $false
# Tick count a file's track lists are taken as complete at; $null until the
# file is first seen playing. See Test-TracksPending.
$script:tracksUntil = $null
# For a few hundred ms after a seek libvlc still reports the OLD position,
# which would snap the clock and the bar back to where they just came from.
# Our own figure is the right one until the demuxer catches up.
$script:seekGuard = 0

# Sibling episodes, in the order the browser lists them, so LB/RB walks the
# season the same way the menu does.
$videoExtRe = '^\.(mp4|mkv|avi|webm|mov|m4v|wmv|mpg|mpeg|ts|flv)$'
$script:siblings = @()
try {
    $dir = Split-Path -LiteralPath $Video -Parent
    $script:siblings = @(Get-ChildItem -LiteralPath $dir -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Extension -match $videoExtRe } |
        Sort-Object Name | Select-Object -ExpandProperty FullName)
} catch {}
if ($script:siblings.Count -eq 0) { $script:siblings = @($Video) }

function Get-SiblingIndex {
    for ($i = 0; $i -lt $script:siblings.Count; $i++) {
        if ($script:siblings[$i] -eq $script:current) { return $i }
    }
    return -1
}

# CLInt reads this after we exit. Written on every file change as well as
# at the end, so a player that is killed outright still leaves the truth
# behind for everything it finished with.
function Save-State {
    if (-not $StateFile) { return }
    try {
        $rows = @()
        foreach ($k in $script:results.Keys) {
            $rows += [pscustomobject]@{
                Path     = $k
                Seconds  = [int]$script:results[$k].Seconds
                Finished = [bool]$script:results[$k].Finished
                Last     = [string]$script:results[$k].Last
            }
        }
        # Windowed rides along so CLInt can come back in the mode the film
        # was LEFT in - quit a windowed film, get a windowed menu. Bounds
        # rides with it so the menu can come back in the PLACE the film was
        # left in too - the swap keeps using the one spot the user chose.
        # The live frame when it is still up; the remembered one (kept by
        # the toggle) when the form is already gone.
        $state = @{ Results = $rows; Windowed = (-not $script:isFull) }
        if (-not $script:isFull) {
            $b = $null
            try { if ($form.WindowState -eq 'Normal') { $b = $form.Bounds } } catch {}
            if (-not $b) { $b = $script:winBounds }
            if ($b) { $state.Bounds = @{ X = $b.X; Y = $b.Y; W = $b.Width; H = $b.Height } }
        }
        $state | ConvertTo-Json -Depth 4 | Set-Content $StateFile -Encoding utf8
    } catch {}
}

# A video within half a minute of its end is a video that was watched: VLC
# drops its own resume entry at that point too, so CLInt's [>>] tag and the
# CURRENTLY WATCHING section agree whichever player wrote the state.
# WatchedPct widens that: credits are part of the file but not part of the
# watch, so stopping past (say) 95% counts too. Min of the two marks, so
# the half-minute rule still catches a short video whose credits window
# would be only seconds wide - and at 100 it IS the old rule, unchanged.
function Record-Position {
    if (-not $script:current) { return }
    $done = $false
    if ($script:lastLen -gt 0) {
        $mark = [Math]::Min($script:lastLen - 30, $script:lastLen * $WatchedPct / 100.0)
        if ($script:lastTime -ge $mark) { $done = $true }
    }
    # Last is what orders CURRENTLY WATCHING back in CLInt, and it is also
    # how CLInt tells which file a multi-episode run stopped on.
    $script:results[$script:current] = @{
        Seconds  = $(if ($done) { 0 } else { $script:lastTime })
        Finished = $done
        Last     = [DateTime]::Now.ToString('s')
    }
}

function Format-Time([int]$sec) {
    if ($sec -lt 0) { $sec = 0 }
    $h = [int][Math]::Floor($sec / 3600)
    $m = [int][Math]::Floor(($sec % 3600) / 60)
    $s = $sec % 60
    if ($h -gt 0) { return ('{0}:{1:d2}:{2:d2}' -f $h, $m, $s) }
    return ('{0}:{1:d2}' -f $m, $s)
}

# Track names arrive as UTF-8 - an MKV is free to call a track "Francais"
# with a cedilla, or name it in Japanese - and PtrToStringAnsi would decode
# those in the machine's ANSI codepage and mangle them. .NET Framework has
# no PtrToStringUTF8 (it arrived in .NET Core), so read to the NUL and
# decode by hand.
function Read-Utf8Ptr([IntPtr]$p) {
    if ($p -eq [IntPtr]::Zero) { return '' }
    $len = 0
    while ([Runtime.InteropServices.Marshal]::ReadByte($p, $len) -ne 0) { $len++ }
    if ($len -eq 0) { return '' }
    $buf = New-Object byte[] $len
    [Runtime.InteropServices.Marshal]::Copy($p, $buf, 0, $len)
    return [Text.Encoding]::UTF8.GetString($buf)
}

# Track lists come back as a linked list of { int id; char* name; next; }.
function Get-TrackList([IntPtr]$head) {
    $out = @()
    $p = $head
    while ($p -ne [IntPtr]::Zero) {
        $id   = [Runtime.InteropServices.Marshal]::ReadInt32($p, 0)
        $namP = [Runtime.InteropServices.Marshal]::ReadIntPtr($p, [IntPtr]::Size)
        $out += [pscustomobject]@{
            Id   = $id
            Name = Read-Utf8Ptr $namP
        }
        $p = [Runtime.InteropServices.Marshal]::ReadIntPtr($p, [IntPtr]::Size * 2)
    }
    if ($head -ne [IntPtr]::Zero) { [CLIntVlc.N]::libvlc_track_description_list_release($head) }
    return @($out)
}

# ----------------------------------------------------------------- look ---
# CLInt paints with sixteen console colours, and which RGB each of those
# names actually is depends on the theme AND on the console the user
# happens to be running in - so the resolving happens over there and the
# answers arrive here. The defaults below are the classic theme on a stock
# Campbell console, i.e. what CLInt looks like out of the box.
$inkDefault = [ordered]@{
    Bg = '0C0C0C'; Accent = '61D6D6'; Logo = 'B4009E'; Info = '3A96DD'
    Hint = '767676'; Text = 'CCCCCC'; Bright = 'F2F2F2'; Notice = 'F9F1A5'
}
# An older CLInt sends only -Accent, as a colour name. Honour it: a player
# in the wrong accent still beats one that refuses the argument.
if (-not $Theme -and $Accent) {
    $byName = @{
        Black = '0C0C0C'; DarkBlue = '0037DA'; DarkGreen = '13A10E'; DarkCyan = '3A96DD'
        DarkRed = 'C50F1F'; DarkMagenta = '881798'; DarkYellow = 'C19C00'; Gray = 'CCCCCC'
        DarkGray = '767676'; Blue = '3B78FF'; Green = '16C60C'; Cyan = '61D6D6'
        Red = 'E74856'; Magenta = 'B4009E'; Yellow = 'F9F1A5'; White = 'F2F2F2'
    }
    if ($byName.ContainsKey($Accent)) { $inkDefault.Accent = $byName[$Accent] }
}
$ink = @{}
foreach ($role in @($inkDefault.Keys)) {
    $hex = $inkDefault[$role]
    foreach ($pair in ($Theme -split ',')) {
        $kv = $pair -split '=', 2
        if ($kv.Count -eq 2 -and $kv[0].Trim() -eq $role) { $hex = $kv[1].Trim() }
    }
    # A malformed pair falls back to the default rather than throwing. A
    # player that will not start is a far worse outcome than a wrong blue.
    $rgb = try { [Convert]::ToInt32($hex, 16) } catch { [Convert]::ToInt32($inkDefault[$role], 16) }
    $ink[$role] = [Drawing.Color]::FromArgb(($rgb -shr 16) -band 0xFF, ($rgb -shr 8) -band 0xFF, $rgb -band 0xFF)
}

# The console font, at the size the menu is using. Pixel units, not points -
# CLInt sets CONSOLE_FONT_INFOEX.SizeY in scaled pixels, and the same number
# of POINTS would land a third larger again.
#
# The catch, and it is the whole reason this is not a one-liner: SizeY is the
# CELL height. Conhost fits the font inside that cell. GDI+ takes an EM size
# and derives the cell from it, and for Consolas the cell comes out 1.171x
# the em (2398/2048 design units) - so handing GDI+ the console's SizeY
# renders every glyph 17% larger than the menu's. Divide it back out through
# the family's own metrics and the cell height lands exactly on SizeY, which
# is the number CLInt actually set.
#
# The DPI term keeps "scaled pixels" honest. Under Windows PowerShell
# (DPI-unaware, which is what CLInt launches) the screen DC reports 96 and
# Windows stretches the window afterwards; under a DPI-aware host it reports
# the real figure and nothing is stretched. Both land the same size on glass.
$dpiScale = 1.0
try {
    $sg = [Drawing.Graphics]::FromHwnd([IntPtr]::Zero)
    $dpiScale = $sg.DpiY / 96.0
    $sg.Dispose()
} catch {}
$fontFam = New-Object Drawing.FontFamily('Consolas')
$emPx    = $TextPx * ($fontFam.GetEmHeight([Drawing.FontStyle]::Regular) /
                      [double]$fontFam.GetLineSpacing([Drawing.FontStyle]::Regular))
$font = New-Object Drawing.Font($fontFam, [Math]::Max(8.0, $emPx * $dpiScale),
                                [Drawing.FontStyle]::Regular, [Drawing.GraphicsUnit]::Pixel)

# --- the overlay's grid -------------------------------------------------
# Worked out once, from the font. Everything the OSD draws is placed in
# character cells, the same unit CLInt's Write-At uses, so changing the
# text size moves the whole strip together instead of pulling it apart.
$script:cw       = 8      # one cell wide
$script:ch       = 16     # one cell tall
$script:padTop   = 2
$script:padBot   = 5
$script:cols     = 80
$script:c0       = 15     # content column - CLInt's, to the right of the mascot
$script:showTape = $true
$script:hint     = ''
$script:osdRows  = 4
$script:tapeTop  = 1      # body row; the lid hangs a cell above it

# CLInt's tape, off the NOW PLAYING screen this player was launched from.
# The button follows the transport, borrowing the wrap screen's for a tape
# that is not running.
#
# Which row it starts on follows the hint row (see $tapeTop). With hints
# there are four rows and the tape drops one, so it sits in the middle
# rather than jammed against the top edge; without them there are three
# and it goes back up, or it would hang off the bottom of the strip.
#
# Either way it costs no rows of its own: the body shares two text rows,
# and the lid is drawn a whole cell above the body - the console's own
# third row. That works because an underscore paints at the very BOTTOM
# of its cell, so all it needs is the two or three pixels of ink, clear
# of whatever is above it.
$script:tapeLid   = '_____'
$script:tapePlay  = @('| |>  |', '|_|___|')
$script:tapePause = @('| |[] |', '|_|___|')

# Hints in CLInt's bracket style, widest first. CLInt fits its tab bar by
# trimming until it fits; same idea, coarser. A hint row that runs off the
# edge of the screen is worse than a shorter one that does not.
#
# Both sets name real bindings from the handlers below - the keyboard one
# is not a translation of the gamepad one, and does not pretend the two
# have the same keys for everything (X/Y are V and B here).
$hintTiers = if ($Controls -eq 'keyboard') {
    @(
        '[ Space: pause    Esc: back    Arrows: seek + volume    F: window    V: subs    B: audio    PgUp/PgDn: episode ]'
        '[ Space: pause    Esc: back    Arrows: seek    V: subs    B: audio ]'
        '[ Space: pause    Esc: back    Arrows: seek ]'
    )
} else {
    @(
        '[ A: pause    B: back    D-pad: seek + volume    X: subs    Y: audio    LB/RB: episode ]'
        '[ A: pause    B: back    D-pad: seek    X: subs    Y: audio ]'
        '[ A: pause    B: back    D-pad: seek ]'
    )
}

function Set-OsdLayout([int]$screenW, [int]$screenH) {
    # Measured off a run of glyphs rather than one, so the per-character
    # rounding cannot accumulate into a visible drift across the bar.
    $sz = [Windows.Forms.TextRenderer]::MeasureText(('M' * 50), $script:font,
              (New-Object Drawing.Size(10000, 1000)), [Windows.Forms.TextFormatFlags]::NoPadding)
    $script:cw   = [Math]::Max(1, [int][Math]::Round($sz.Width / 50.0))
    $script:ch   = $script:font.Height
    # Enough dark above the first row and below the last that the strip
    # reads as a panel rather than text sitting on a cut edge. The bottom
    # gets slightly more because a row carries a few pixels of headroom
    # above its glyphs already, but its descenders reach its last pixel -
    # split evenly it looks top-heavy.
    $script:padTop = [Math]::Max(4, [int]($script:ch * 0.30))
    $script:padBot = [Math]::Max(5, [int]($script:ch * 0.36))
    $script:cols = [Math]::Max(20, [int][Math]::Floor($screenW / $script:cw))
    # Under 60 columns - a small screen at the large text size - the tape
    # and the indent it needs cost more room than they are worth.
    $script:showTape = $script:cols -ge 60
    $script:c0       = if ($script:showTape) { 15 } else { 2 }
    $script:hint = ''
    if (-not $script:NoHints) {
        foreach ($h in $script:hintTiers) {
            if ($script:c0 + $h.Length -le $script:cols - 2) { $script:hint = $h; break }
        }
    }
    # heading, name, and the clock-and-bar row - the tape rides alongside
    # two of them and costs nothing - plus the hints if they fit.
    $script:osdRows = 3
    if ($script:hint) { $script:osdRows++ }
    # This is a strip over a film, not a takeover of it. A backstop only,
    # now that four rows is the most it ever draws: if even those clear a
    # third of the picture the hints go, being the only row here that is
    # help rather than fact. The buttons they describe still work.
    #
    # Settled BEFORE the tape is placed: dropping the hints here moves the
    # tape up a row too, and reading $hint any earlier would place it
    # against a row that is about to be taken away.
    if ($script:hint -and $screenH -gt 0) {
        $h = ($script:osdRows * $script:ch) + $script:padTop + $script:padBot
        if ($h -gt ($screenH * 0.30)) { $script:hint = ''; $script:osdRows-- }
    }
    # Where the tape's body starts. Beside the name when a hint row sits
    # underneath to balance it, beside the heading when there is none - on
    # three rows the lower position would hang the tape off the bottom.
    $script:tapeTop = if ($script:hint) { 1 } else { 0 }
    # A body on row 0 puts its lid above the strip's first row, so the top
    # padding has to receive it - the underscore's few pixels only, but they
    # have to land somewhere. Lower down the lid falls inside the heading's
    # own row and no allowance is needed.
    if ($script:showTape -and $script:tapeTop -eq 0) {
        $script:padTop += [int]($script:ch * 0.22)
    }
}

# CLInt's Write-At, on this side of the window boundary. TextRenderer
# rather than Graphics.DrawString because it is GDI, the same as the
# console's own text - DrawString lays glyphs out fractionally and the
# result does not sit on a grid.
# $dy nudges a string off the grid by whole pixels. Only the tape's lid uses
# it, and only because the cell it wants is mostly empty air (see $tapeLid).
function Write-Cell($g, [int]$cx, [int]$cy, [string]$text, $fg, [int]$dy = 0) {
    if (-not $text) { return }
    [Windows.Forms.TextRenderer]::DrawText($g, $text, $script:font,
        (New-Object Drawing.Point(($cx * $script:cw), ($script:padTop + $cy * $script:ch + $dy))),
        $fg, [Windows.Forms.TextFormatFlags]::NoPadding)
}

# CLInt's Pad, minus the padding: the strip's background is already down,
# so only the truncation half is wanted here.
function Fit([string]$s, [int]$width) {
    if ($width -lt 1) { return '' }
    if ($s.Length -le $width) { return $s }
    if ($width -le 3) { return $s.Substring(0, $width) }
    return $s.Substring(0, $width - 3) + '...'
}

# ---------------------------------------------------------------- forms ---

$form = New-Object Windows.Forms.Form
$form.Text            = 'CLInt'
$form.FormBorderStyle = 'None'
# Black, not the theme background: what shows here is the letterbox around
# the picture, and bars around a film are black in every player there has
# ever been. The theme dresses the overlay, not the screen the video is on.
$form.BackColor       = [Drawing.Color]::Black
# A windowed launch must never pass through Maximized: WindowState set
# before the handle is on screen is applied AT SHOW, and the 'Normal' the
# windowed setup writes over it pre-show loses that race - the form came
# up as a maximized-with-border window (measured, v1.4.0).
if (-not $Windowed) { $form.WindowState = 'Maximized' }
$form.KeyPreview      = $true
$form.TopMost         = $true
# One CLInt on the taskbar, whichever face it is showing. This window
# carries CLInt's icon and the same app identity as the menu's console,
# and while a film is up it holds the only button: the menu's own is taken
# away at Shown and handed back at FormClosing (see Set-MenuTab). So the
# button under a windowed film - where the menu is hidden outright and
# used to leave nothing down there at all - and the one left after the
# menu key puts everything away are both this one, and clicking it brings
# the film back.
$script:appIco = Join-Path $PSScriptRoot 'CLInt.ico'
if (Test-Path $script:appIco) {
    try { $form.Icon = New-Object Drawing.Icon($script:appIco) } catch {}
}
$form.Add_HandleCreated({
    try {
        $launch  = Join-Path (Split-Path $PSScriptRoot -Parent) 'Launch.ps1'
        $command = $null
        if (Test-Path $launch) {
            $command = "`"$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe`" -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$launch`""
        }
        $icon = if (Test-Path $script:appIco) { "$($script:appIco),0" } else { $null }
        [CLIntVlc.N]::SetAppIdentity($form.Handle, 'CLInt.Launcher', $command, $icon, 'CLInt') | Out-Null
    } catch {}
    # No opening animation: the film CUTS in over the menu, the way a
    # screen of one program replaces another, rather than gliding up like
    # a second program starting. Put back once the window is on screen
    # (see Shown), so the menu key's minimize keeps its glide.
    try { [CLIntVlc.N]::SetTransitions($form.Handle, $false) } catch {}
})

# Opaque, in the theme's own background. The console has no transparency to
# be consistent with, and a strip you can see the film through is the one
# thing here that could never be mistaken for part of CLInt.
$osd = New-Object ClintOsdForm
$osd.FormBorderStyle = 'None'
$osd.BackColor       = $ink.Bg
$osd.ShowInTaskbar   = $false
$osd.StartPosition   = 'Manual'
$osd.Visible         = $false

function Show-Osd([string]$note = '', [int]$ms = 3000) {
    if ($note) { $script:osdNote = $note }
    $script:osdUntil = [Environment]::TickCount + $ms
    if (-not $osd.Visible) { $osd.Show($form) }
    $osd.Invalidate()
    Sync-SubMargin
}

function Hide-Osd {
    $script:osdUntil = 0
    if ($osd.Visible -and -not $script:osdPinned) { $osd.Hide() }
    Sync-SubMargin
}

# Subtitles ride above the strip while it is up and drop back when it goes,
# so the two never share the same rows. The strip covers the bottom of the
# WINDOW and subtitles are placed off the bottom of the PICTURE, so a film
# with black bars of its own has already cleared part of the strip - only
# the rest is asked for, or a letterboxed film's subtitles would jump
# further than the strip is tall.
#
# Called from the tick as well as from show and hide: a vout does not exist
# until a moment after play(), which is after the strip first goes up, and
# the strip has ways of leaving (the pin toggle) that do not pass through
# Hide-Osd.
function Sync-SubMargin {
    if (-not $script:marginOk -or $script:mp -eq [IntPtr]::Zero) { return }
    try {
        $px = 0
        if ($osd.Visible) {
            $px = $osd.Height
            $b  = Get-PlayerBounds
            $vw = [uint32]0; $vh = [uint32]0
            if ([CLIntVlc.N]::libvlc_video_get_size($script:mp, 0, [ref]$vw, [ref]$vh) -eq 0 -and
                $vw -gt 0 -and $vh -gt 0 -and $b.Width -gt 0) {
                $picH = [Math]::Min([double]$b.Height, $b.Width * [double]$vh / $vw)
                $px  -= [int](($b.Height - $picH) / 2)
                # The margin is counted in the pixels subtitles are DRAWN
                # in, and VLC draws them at the film's own size whenever
                # that is bigger than the window (measured: on a 4K file
                # the unscaled figure moved them a third of the way).
                if ($px -gt 0 -and $picH -ge 1 -and $vh -gt $picH) {
                    $px = [int][Math]::Ceiling($px * $vh / $picH)
                }
            }
            $px = [Math]::Max(0, $px)
        }
        [CLIntVlc.Core]::SetSubMargin($script:mp, $px, 3) | Out-Null
    } catch { $script:marginOk = $false }
}

# The corner card: one line of text, top-right, the way VLC announces a
# track change. Subtitle and audio switches use this instead of the full
# strip because the strip lands exactly where subtitles render - putting
# it up to say "Subs: English" would cover the first line of the thing
# just switched on.
$toast = New-Object ClintOsdForm
$toast.FormBorderStyle = 'None'
$toast.BackColor       = $ink.Bg
$toast.ShowInTaskbar   = $false
$toast.StartPosition   = 'Manual'
$toast.Visible         = $false
$script:toastText  = ''
$script:toastUntil = 0

$toast.Add_Paint({
    param($sender, $e)
    if (-not $script:toastText) { return }
    [Windows.Forms.TextRenderer]::DrawText($e.Graphics, $script:toastText, $script:font,
        (New-Object Drawing.Point($script:cw, $script:padTop)),
        $ink.Notice, [Windows.Forms.TextFormatFlags]::NoPadding)
})

function Show-Note([string]$text, [int]$ms = 3000) {
    $sc = Get-PlayerBounds
    $script:toastText  = Fit $text ($script:cols - 4)
    $script:toastUntil = [Environment]::TickCount + $ms
    # A cell of quiet either side of the text, the strip's own padding above
    # and below, and a margin off the screen's edges. The margin is the cell
    # WIDTH on both sides - a cell is taller than it is wide, so using the
    # height above put the card visibly lower than it sat from the right.
    $w = ($script:toastText.Length + 2) * $script:cw
    $h = $script:ch + $script:padTop + $script:padBot
    $toast.Size     = New-Object Drawing.Size($w, $h)
    $toast.Location = New-Object Drawing.Point(($sc.X + $sc.Width - $w - $script:cw), ($sc.Y + $script:cw))
    if (-not $toast.Visible) { $toast.Show($form) }
    $toast.Invalidate()
}

# The overlay, laid out the way CLInt lays out a screen: mascot at the far
# left, everything else in one column to the right of it, a bracketed hint
# row along the bottom. Nothing here is anti-aliased, rounded or floated -
# it is characters on a grid, because that is what CLInt is.
#
#     _____    NOW PLAYING  [PAUSED]                     Volume 60%
#    | |>  |   The.Expanse.S01E03
#    |_|___|   12:34 [####################-----------] 47:02
#              [ A: pause    B: back    D-pad: seek + volume    ... ]
$osd.Add_Paint({
    param($sender, $e)
    $g     = $e.Graphics
    $c0    = $script:c0
    $right = $script:cols - 2          # last column anything may touch

    $rHead = 0
    $rName = 1
    $rBar  = 2
    $rHint = 3

    # Accent on the heading row and logo on the name row, tape included -
    # the console screen this replaces colours by row, not by element.
    if ($script:showTape) {
        $tape = if ($script:paused) { $script:tapePause } else { $script:tapePlay }
        $rt   = $script:tapeTop
        # Lid a full cell above the body - it lands low in whatever row is
        # up there, an underscore painting at its cell's floor. Two tones
        # rather than three, so the tape keeps the console's own colouring
        # instead of picking up a third from whichever row it reaches.
        Write-Cell $g 5 $rt $script:tapeLid $ink.Accent (-$script:ch)
        Write-Cell $g 4 $rt        $tape[0] $ink.Accent
        Write-Cell $g 4 ($rt + 1)  $tape[1] $ink.Logo
    }

    $head = 'NOW PLAYING'
    Write-Cell $g $c0 $rHead $head $ink.Accent
    if ($script:paused) {
        Write-Cell $g ($c0 + $head.Length + 2) $rHead '[PAUSED]' $ink.Notice
    }

    # Transient messages ("Volume 60%", "+15s") ride the heading row,
    # right-aligned, in the colour CLInt shows its own notices in.
    if ($script:osdNote) {
        $note = Fit $script:osdNote ($right - $c0 - $head.Length - 12)
        if ($note) { Write-Cell $g ($right - $note.Length + 1) $rHead $note $ink.Notice }
    }

    $name = Fit ([System.IO.Path]::GetFileNameWithoutExtension($script:current)) ($right - $c0 + 1)
    Write-Cell $g $c0 $rName $name $ink.Logo

    # Elapsed, bar, total on one row. Progress in characters rather than a
    # painted rectangle - same reason the menu draws '/\ more' instead of a
    # scrollbar - and the elapsed side is padded to the total's width so the
    # bar's ends stay put as the clock runs rather than jittering a column
    # every time the minutes gain a digit.
    $tot = Format-Time $script:lastLen
    $el  = (Format-Time $script:lastTime).PadLeft($tot.Length)
    $frac = 0.0
    if ($script:lastLen -gt 0) {
        $frac = [Math]::Max(0.0, [Math]::Min(1.0, $script:lastTime / [double]$script:lastLen))
    }
    $barX = $c0 + $el.Length + 1
    $barW = $right - $tot.Length - $barX          # room for '[', track, ']'
    if ($barW -ge 8) {
        Write-Cell $g $c0 $rBar $el $ink.Info
        Write-Cell $g ($right - $tot.Length + 1) $rBar $tot $ink.Info
        $inner = $barW - 2
        $fill  = [int][Math]::Round($inner * $frac)
        Write-Cell $g $barX $rBar ('[' + ('-' * $inner) + ']') $ink.Hint
        if ($fill -gt 0) { Write-Cell $g ($barX + 1) $rBar ('#' * $fill) $ink.Accent }
    } else {
        # Too narrow for a bar worth looking at: the numbers alone, then.
        Write-Cell $g $c0 $rBar (Fit "$el / $tot" ($right - $c0 + 1)) $ink.Info
    }

    if ($script:hint) { Write-Cell $g $c0 $rHint $script:hint $ink.Hint }
})

# --------------------------------------------------- fullscreen/windowed ---
# The video's own rectangle, in screen coordinates. Fullscreen the client
# area IS the screen; windowed it is whatever the user has dragged the
# frame to. Every screen-shaped decision (the strip, the toast, where a
# click counts) goes through this, so both modes are the same code.
function Get-PlayerBounds {
    return $form.RectangleToScreen($form.ClientRectangle)
}

# (Re)fit the strip to the current picture: on show, on every mode toggle,
# and on every windowed move or resize. The layout maths already answers a
# smaller screen - a windowed player just IS one - so the strip narrows,
# sheds the tape, then the hints, exactly as it does on a small display.
function Place-Osd {
    $b = Get-PlayerBounds
    if ($b.Width -lt 1 -or $b.Height -lt 1) { return }
    Set-OsdLayout $b.Width $b.Height
    $osdH = ($script:osdRows * $script:ch) + $script:padTop + $script:padBot
    $osd.Size     = New-Object Drawing.Size($b.Width, $osdH)
    $osd.Location = New-Object Drawing.Point($b.X, ($b.Y + $b.Height - $osdH))
    if ($osd.Visible) { $osd.Invalidate() }
}

$script:isFull       = $true
$script:winBounds    = $null    # last windowed frame, so the toggle round-trips
$script:cursorHidden = $false   # Cursor.Hide/Show keep a COUNT - never call the same one twice
# Up while a mode toggle is rearranging the frame. WinForms raises Resize
# and Move from inside those property setters, and the frame is mid-change
# when they fire - a half-applied rectangle is not a windowed frame worth
# remembering. Only the handlers' winBounds capture honours this; their
# strip re-fit is harmless either way.
$script:switching    = $false

# Windowed, this window IS CLInt as far as the eye goes - the fullscreen
# menu (painted with the wrap screen) hanging around behind a small film
# window reads as two programs where the user launched one. So the menu
# window is hidden outright for as long as the player is windowed, and put
# back - shown, never activated; it belongs BEHIND the film - on the way
# to fullscreen and on the way out. Handle AND title must match, the same
# rule CLIntKey.ahk applies: a stale clint.hwnd left by a crashed menu
# must not hide whatever stranger's window recycled the handle. And CLInt
# covers the crash on THIS side: its Show-MenuWindow re-shows a hidden
# console, so a killed player cannot strand the menu invisible.
$script:menuHwnd = [IntPtr]::Zero
if ($StateFile) {
    try {
        $f = Join-Path (Split-Path $StateFile -Parent) 'clint.hwnd'
        if (Test-Path $f) {
            $cand = [IntPtr][int64]((Get-Content $f -Raw).Trim())
            if ([CLIntVlc.N]::IsWindow($cand) -and [CLIntVlc.N]::WindowTitle($cand) -eq 'CLInt') {
                $script:menuHwnd = $cand
            }
        }
    } catch {}
}

function Set-MenuVisible([bool]$show) {
    if ($script:menuHwnd -eq [IntPtr]::Zero) { return }
    # A windowed LAUNCH hides the menu only once this window is on screen
    # in its place (see Shown) - hidden before that, there is a beat with
    # neither of them up and the desktop showing through.
    if (-not $show -and $script:preShow) { return }
    try {
        if (-not [CLIntVlc.N]::IsWindow($script:menuHwnd)) { return }
        if ($show) {
            if (-not [CLIntVlc.N]::IsWindowVisible($script:menuHwnd)) {
                [CLIntVlc.N]::ShowWindow($script:menuHwnd, 8) | Out-Null   # SW_SHOWNA
            }
        } elseif ([CLIntVlc.N]::IsWindowVisible($script:menuHwnd)) {
            [CLIntVlc.N]::ShowWindow($script:menuHwnd, 0) | Out-Null       # SW_HIDE
        }
    } catch {}
}

# The menu's taskbar button, taken away for as long as the film is up and
# given back on the way out, so there is only ever one CLInt down there.
# CLInt re-adds it itself when it comes back (Show-MenuWindow), which
# covers a player that was killed before it could.
#
# A button put back has lost what the taskbar knew about its window - that
# it is fullscreen, and so something to stay behind. Left at that, the
# taskbar jumps in front of the menu the moment this window goes, and
# stays there until CLInt notices the player has exited and says so itself
# (measured: on top for a third of a second after every fullscreen film,
# v1.5.1). So a fullscreen menu's button goes back already marked, while
# the film is still covering the screen, and the taskbar never moves.
function Set-MenuTab([bool]$show) {
    if ($script:menuHwnd -eq [IntPtr]::Zero) { return }
    try {
        if (-not [CLIntVlc.N]::IsWindow($script:menuHwnd)) { return }
        $full = $false
        if ($show) {
            $mr = New-Object CLIntVlc.N+RECT
            if ([CLIntVlc.N]::GetWindowRect($script:menuHwnd, [ref]$mr)) {
                $full = Test-CoversScreen (New-Object Drawing.Rectangle($mr.L, $mr.T, ($mr.R - $mr.L), ($mr.B - $mr.T)))
            }
        }
        [CLIntVlc.N]::TaskbarTab($script:menuHwnd, $show, $full)
    } catch {}
}

# A console covering its screen IS a fullscreen console: conhost's
# fullscreen has no frame and takes the whole monitor, while CLInt's
# windowed menu is a miniature of it - $windowedFontScale, 75% of the
# screen in each direction. The two are far enough apart that the line
# goes between them rather than at the edge: an exact-rect test would have
# to assume conhost sizes its fullscreen window to the pixel, and anything
# it leaves over is grid remainder we cannot predict.
function Test-CoversScreen([Drawing.Rectangle]$rect) {
    $scrB = [Windows.Forms.Screen]::FromRectangle($rect).Bounds
    return ($rect.Width -ge ($scrB.Width * 0.9) -and $rect.Height -ge ($scrB.Height * 0.9))
}

function Set-PlayerDisplay([bool]$full) {
    # Remember the windowed frame before fullscreen swallows it - but only
    # a real one. Maximized-with-a-border is the frame's own state, not a
    # size worth restoring to.
    if ($full -and $form.FormBorderStyle -ne 'None' -and $form.WindowState -eq 'Normal') {
        $script:winBounds = $form.Bounds
    }
    # DWM animates the maximize/restore below, but only for the FORM - the
    # strip and toast are windows of their own and snap straight to their
    # new spots, and a picture that glides while its controls teleport
    # reads as broken. So the toggle plays with no animation at all: a
    # film player's fullscreen switch is expected to CUT, the way VLC's
    # does. Off only for the toggle itself - the menu key's minimize keeps
    # its glide.
    try { [CLIntVlc.N]::SetTransitions($form.Handle, $false) } catch {}
    $script:isFull   = $full
    $script:switching = $true
    if ($full) {
        # Through Normal first: a border change while Maximized keeps the
        # OLD maximized bounds, leaving the border's ghost around the
        # picture instead of edge-to-edge film.
        $form.WindowState     = 'Normal'
        $form.FormBorderStyle = 'None'
        $form.TopMost         = $true
        $form.WindowState     = 'Maximized'
        if (-not $script:cursorHidden) { [Windows.Forms.Cursor]::Hide(); $script:cursorHidden = $true }
        # Menu back AFTER the film already covers the screen, so it is
        # never seen returning.
        Set-MenuVisible $true
    } else {
        # Where the window is going, settled BEFORE anything moves. It has
        # to be decided first: leaving Maximized restores the form to its
        # OWN bounds, and for a film that launched fullscreen those have
        # never been set - they are still WinForms' 300x300 default. Read
        # after the fact (directly, or through the Resize this branch
        # raises) that default becomes the answer, which is the tiny window
        # this default exists to prevent.
        if (-not $script:winBounds) {
            # First time out: 75% of the working area, centred - the same
            # miniature proportion CLInt's own windowed menu uses. Measured
            # off the screen the film is playing on, which is still the
            # fullscreen one at this point.
            $wa = [Windows.Forms.Screen]::FromControl($form).WorkingArea
            $w  = [Math]::Max(320, [int]($wa.Width  * 0.75))
            $h  = [Math]::Max(240, [int]($wa.Height * 0.75))
            $script:winBounds = New-Object Drawing.Rectangle(
                ($wa.X + [int](($wa.Width - $w) / 2)),
                ($wa.Y + [int](($wa.Height - $h) / 2)), $w, $h)
        }
        $target = $script:winBounds
        # Menu away BEFORE the frame shrinks, so what the window reveals
        # is the desktop, never a fullscreen CLInt mid-vanish.
        Set-MenuVisible $false
        # A window among windows: a real frame to grab, no TopMost pinning
        # it over whatever else the desktop is doing, and the pointer back
        # - a frame you cannot see your mouse on cannot be moved.
        $form.TopMost         = $false
        $form.FormBorderStyle = 'Sizable'
        $form.WindowState     = 'Normal'
        $form.Bounds = $target
        if ($script:cursorHidden) { [Windows.Forms.Cursor]::Show(); $script:cursorHidden = $false }
    }
    # The state changes above complete inside their setters, so the
    # animation window is already past - this cannot re-animate them.
    try { [CLIntVlc.N]::SetTransitions($form.Handle, $true) } catch {}
    $script:switching = $false
    # The frame the toggle just settled on IS the windowed frame to come
    # back to - recorded here, now that it is whole, rather than from the
    # events the setters raised on the way.
    if (-not $script:isFull -and $form.WindowState -eq 'Normal') {
        $script:winBounds = $form.Bounds
    }
    Place-Osd
}

function Toggle-PlayerDisplay {
    # No note: the frame changing IS the feedback. A word for what you can
    # already see just sits over the film.
    Set-PlayerDisplay (-not $script:isFull)
}

# A windowed launch takes effect HERE, before the form ever shows, so the
# first thing on screen is already the window - not a fullscreen frame
# collapsing out of it. (Set-PlayerDisplay touches $form.Handle, which
# quietly creates the handle early; StartPosition is set first so its
# handle-creation default cannot override the bounds we are about to
# place.) This also hides the menu window straight away - the windowed
# player replaces a windowed CLInt the same way it replaces a fullscreen
# one.
#
# Which mode that is comes from the MENU WINDOW as it stands right now,
# not from the -Windowed switch alone. CLInt reads its console the moment
# it hands over, but this process then takes a second or two to load
# libvlc and put a form up - and conhost owns Alt+Enter, so the display
# mode can flip in that gap without a key ever reaching CLInt's script
# (which is blocked in its wait loop, where even Sync-DisplayMode does not
# run). Someone who hits the fullscreen toggle while the film is still
# loading means it for the FILM, and used to watch it open windowed
# anyway. So: trust the glass, the same rule CLInt applies on its side.
# Read in THIS process - both sides are equally DPI-(un)aware, so the
# numbers line up.
$openWindowed = [bool]$Windowed
$script:menuRect = $null
if ($script:menuHwnd -ne [IntPtr]::Zero) {
    try {
        $mr = New-Object CLIntVlc.N+RECT
        if ([CLIntVlc.N]::GetWindowRect($script:menuHwnd, [ref]$mr) -and
            ($mr.R - $mr.L) -ge 320 -and ($mr.B - $mr.T) -ge 240) {
            $script:menuRect = New-Object Drawing.Rectangle(
                $mr.L, $mr.T, ($mr.R - $mr.L), ($mr.B - $mr.T))
            $openWindowed = -not (Test-CoversScreen $script:menuRect)
        }
    } catch {}
}
if ($openWindowed) {
    # A windowed film takes the STAGE the menu occupied: same frame, same
    # spot, so the launcher and the player read as one window swapping
    # faces rather than two windows in two places. Falls back to
    # Set-PlayerDisplay's 75%-centred default when the menu window is
    # unknown (standalone run, stale hwnd).
    if ($script:menuRect) { $script:winBounds = $script:menuRect }
    $form.StartPosition = 'Manual'
    $script:preShow = $true
    Set-PlayerDisplay $false
    $script:preShow = $false
} elseif ($Windowed) {
    # Handed a windowed launch, but the menu went fullscreen while we were
    # loading. The form never passed through Maximized on the way up (see
    # the border setup), so put it in the fullscreen shape now - pre-show,
    # exactly where a fullscreen launch sets it - and leave $script:isFull
    # at the $true it starts on.
    $form.WindowState = 'Maximized'
}

# ------------------------------------------------------------- playback ---
function Start-File([string]$path) {
    Stop-Current
    $script:current  = $path
    $script:lastTime = 0
    $script:lastLen  = 0
    $script:subsPicked = $false
    # Tracks are not known the instant play() returns; the timer starts the
    # clock on them once the file is actually playing.
    $script:tracksUntil = $null
    $script:media = [CLIntVlc.N]::libvlc_media_new_path($inst, $path)
    if ($script:media -eq [IntPtr]::Zero) { return $false }
    $script:mp = [CLIntVlc.N]::libvlc_media_player_new_from_media($script:media)
    if ($script:mp -eq [IntPtr]::Zero) { return $false }
    [CLIntVlc.N]::libvlc_media_player_set_hwnd($script:mp, $form.Handle)
    # Embedded like this, libvlc's video window claims the keyboard and
    # mouse for its own hotkeys by default - the form then never sees a
    # keypress once that child window has focus, and Space stops pausing.
    # Both stay ours; the form's own handlers are the only input path.
    try {
        [CLIntVlc.N]::libvlc_video_set_key_input($script:mp, 0)
        [CLIntVlc.N]::libvlc_video_set_mouse_input($script:mp, 0)
    } catch {}
    [CLIntVlc.N]::libvlc_media_player_play($script:mp) | Out-Null
    [CLIntVlc.N]::libvlc_audio_set_volume($script:mp, $script:volume) | Out-Null
    # Windows keeps a per-app mute in the volume mixer, keyed to the host
    # exe - so a "Windows PowerShell" once muted there stays muted, and
    # libvlc's mmdevice output honours it forever after: pipeline up,
    # volume 100, not a sound. This player has no mute of its own, so a
    # muted session is never something it wants inherited.
    [CLIntVlc.N]::libvlc_audio_set_mute($script:mp, 0)
    $script:paused = $false
    Show-Osd '' 3500
    return $true
}

function Stop-Current {
    if ($script:mp -ne [IntPtr]::Zero) {
        Record-Position
        Save-State
        try { [CLIntVlc.N]::libvlc_media_player_stop($script:mp) } catch {}
        try { [CLIntVlc.N]::libvlc_media_player_release($script:mp) } catch {}
        $script:mp = [IntPtr]::Zero
    }
    if ($script:media -ne [IntPtr]::Zero) {
        try { [CLIntVlc.N]::libvlc_media_release($script:media) } catch {}
        $script:media = [IntPtr]::Zero
    }
}

function Invoke-Seek([int]$delta) {
    if ($script:mp -eq [IntPtr]::Zero) { return }
    $t = [CLIntVlc.N]::libvlc_media_player_get_time($script:mp)
    if ($t -lt 0) { $t = $script:lastTime * 1000 }
    $new = [Math]::Max(0, $t + ($delta * 1000))
    if ($script:lastLen -gt 0) { $new = [Math]::Min($new, ($script:lastLen - 3) * 1000) }
    [CLIntVlc.N]::libvlc_media_player_set_time($script:mp, [long]$new)
    $script:lastTime  = [int]($new / 1000)
    $script:seekGuard = [Environment]::TickCount + 700
    Show-Osd ('{0}{1}s' -f $(if ($delta -gt 0) { '+' } else { '' }), $delta)
}

function Toggle-Pause {
    if ($script:mp -eq [IntPtr]::Zero) { return }
    $script:paused = -not $script:paused
    [CLIntVlc.N]::libvlc_media_player_set_pause($script:mp, $(if ($script:paused) { 1 } else { 0 }))
    if (-not $script:paused) {
        # Embedded libvlc can come out of a pause with the audio running and
        # the picture frozen on the pre-pause frame: the hardware decoder's
        # surfaces go stale while paused (display power-management, a
        # minimize - and this player pauses itself on every minimize) and
        # the video pipeline never advances again on its own. Re-seeking to
        # the spot we are already at flushes and rebuilds decoder and vout,
        # which un-sticks it, and on a healthy resume changes nothing the
        # eye can see. The guard keeps the clock and bar from snapping to
        # the stale position libvlc reports mid-seek, same as Invoke-Seek.
        $t = [CLIntVlc.N]::libvlc_media_player_get_time($script:mp)
        if ($t -ge 0) {
            [CLIntVlc.N]::libvlc_media_player_set_time($script:mp, $t)
            $script:seekGuard = [Environment]::TickCount + 700
        }
    }
    # A paused film keeps its overlay up - the tape and the [PAUSED] tag on
    # it are the only thing saying why the picture stopped moving.
    Show-Osd '' $(if ($script:paused) { 600000 } else { 2000 })
}

function Adjust-Volume([int]$delta) {
    if ($script:mp -eq [IntPtr]::Zero) { return }
    $script:volume = [Math]::Max(0, [Math]::Min($script:VOL_MAX, $script:volume + $delta))
    [CLIntVlc.N]::libvlc_audio_set_volume($script:mp, $script:volume) | Out-Null
    # Tagged above nominal, in the menu's own bracket style. Without it the
    # only clue that a film has started distorting is the film distorting,
    # and the number alone does not say where the line was.
    $label = "Volume $($script:volume)%"
    if ($script:volume -gt 100) { $label += '  [boost]' }
    Show-Osd $label
}

# Subtitle and audio cycling share a shape: read the list, find where we
# are, step to the next entry, wrap. "Disable" is a real entry in both
# lists (id -1), so switching subtitles off is just another step round.
#
# A file's tracks turn up a moment after it opens, so for its first few
# seconds a short list only means "not loaded yet". Saying "No subtitles"
# then is simply wrong half the time - the same press a second later finds
# them - so until the lists have had their chance, a press that finds
# nothing to step to says nothing at all.
function Test-TracksPending {
    if ($null -eq $script:tracksUntil) { return $true }
    return [Environment]::TickCount -lt $script:tracksUntil
}

function Step-Spu {
    if ($script:mp -eq [IntPtr]::Zero) { return }
    $tracks = Get-TrackList ([CLIntVlc.N]::libvlc_video_get_spu_description($script:mp))
    if ($tracks.Count -le 1) {
        if (-not (Test-TracksPending)) { Show-Note 'No subtitles' }
        return
    }
    $cur = [CLIntVlc.N]::libvlc_video_get_spu($script:mp)
    $i = 0
    for ($j = 0; $j -lt $tracks.Count; $j++) { if ($tracks[$j].Id -eq $cur) { $i = $j; break } }
    $next = $tracks[($i + 1) % $tracks.Count]
    [CLIntVlc.N]::libvlc_video_set_spu($script:mp, $next.Id) | Out-Null
    Show-Note ("Subs: " + $(if ($next.Id -eq -1) { 'off' } else { $next.Name }))
}

function Step-Audio {
    if ($script:mp -eq [IntPtr]::Zero) { return }
    $tracks = @(Get-TrackList ([CLIntVlc.N]::libvlc_audio_get_track_description($script:mp)) |
                Where-Object { $_.Id -ne -1 })   # muting by cycling tracks is a trap, not a feature
    if ($tracks.Count -le 1) {
        if (-not (Test-TracksPending)) { Show-Note 'One audio track' }
        return
    }
    $cur = [CLIntVlc.N]::libvlc_audio_get_track($script:mp)
    $i = 0
    for ($j = 0; $j -lt $tracks.Count; $j++) { if ($tracks[$j].Id -eq $cur) { $i = $j; break } }
    $next = $tracks[($i + 1) % $tracks.Count]
    [CLIntVlc.N]::libvlc_audio_set_track($script:mp, $next.Id) | Out-Null
    Show-Note ("Audio: " + $next.Name)
}

function Step-Episode([int]$delta) {
    $i = Get-SiblingIndex
    if ($i -lt 0) { return }
    $n = $i + $delta
    if ($n -lt 0 -or $n -ge $script:siblings.Count) {
        Show-Osd $(if ($delta -gt 0) { 'Last in folder' } else { 'First in folder' })
        return
    }
    $script:seekTo = 0
    Start-File $script:siblings[$n] | Out-Null
}

function Stop-Player {
    if ($script:quitting) { return }
    $script:quitting = $true
    Stop-Current
    $form.Close()
}

# ----------------------------------------------------------------- input ---
# Keyboard follows VLC where VLC has an opinion (space, f, v, b) so muscle
# memory carries over, and the gamepad follows CLInt's own menu (A acts,
# B goes back) so muscle memory carries over from the other direction.
$form.Add_KeyDown({
    param($sender, $e)
    switch ($e.KeyCode) {
        'Space'      { Toggle-Pause }
        'Escape'     { Stop-Player }
        'Left'       { Invoke-Seek -15 }
        'Right'      { Invoke-Seek 15 }
        'OemMinus'   { Invoke-Seek -15 }
        'Subtract'   { Invoke-Seek -15 }
        'Oemplus'    { Invoke-Seek 15 }
        'Add'        { Invoke-Seek 15 }
        'Up'         { Adjust-Volume 5 }
        'Down'       { Adjust-Volume -5 }
        'V'          { Step-Spu }
        'S'          { Step-Spu }
        'B'          { Step-Audio }
        'F'          { Toggle-PlayerDisplay }
        # PowerShell's switch compares an enum by its STRING - unlike -eq,
        # which converts the label to the enum first - and Keys.ToString()
        # spells these by their canonical names: PageDown is 'Next', Enter
        # is 'Return'. The friendlier aliases would never match; PgDn (and
        # Enter below) sat dead behind them until v1.4.0.
        'PageUp'     { Step-Episode -1 }
        'Next'       { Step-Episode 1 }
        # Media keys, as sent by remotes (Remote Helper's pause button among
        # them) and the media row on most keyboards. They arrive as ordinary
        # KeyDowns on the focused window, so cases here are all it takes.
        'MediaPlayPause'     { Toggle-Pause }
        'MediaStop'          { Stop-Player }
        'MediaPreviousTrack' { Step-Episode -1 }
        'MediaNextTrack'     { Step-Episode 1 }
        'Tab'        { $script:osdPinned = -not $script:osdPinned
                       if ($script:osdPinned) { Show-Osd '' 600000 } else { $script:osdUntil = 0; $osd.Hide() } }
        # Alt+Enter is the fullscreen toggle everywhere else on Windows;
        # Enter on its own pauses. 'Return', not 'Enter' - see PageDown.
        'Return'     { if ($e.Alt) { Toggle-PlayerDisplay } else { Toggle-Pause } }
    }
    $e.Handled = $true
    # Remote-keyboard apps (Remote Helper's Keyboard mode among them) inject
    # characters as KEYEVENTF_UNICODE, which lands here as VK_PACKET with the
    # real character only visible to KeyPress. Let those through to the
    # KeyPress handler below; everything else is done - suppressing its
    # KeyPress keeps a physical Space from firing Toggle-Pause twice.
    if ($e.KeyCode -ne [Windows.Forms.Keys]::Packet) { $e.SuppressKeyPress = $true }
})

# Character bindings, mirroring the KeyDown map above. Only VK_PACKET
# events reach here (see the suppression above), so a physical keypress
# can never run both handlers.
$form.Add_KeyPress({
    param($sender, $e)
    switch ([char]::ToLowerInvariant($e.KeyChar)) {
        ' '         { Toggle-Pause }
        "`r"        { Toggle-Pause }
        ([char]27)  { Stop-Player }
        '-'         { Invoke-Seek -15 }
        '+'         { Invoke-Seek 15 }
        '='         { Invoke-Seek 15 }
        'v'         { Step-Spu }
        's'         { Step-Spu }
        'b'         { Step-Audio }
        'f'         { Toggle-PlayerDisplay }
        "`t"        { $script:osdPinned = -not $script:osdPinned
                      if ($script:osdPinned) { Show-Osd '' 600000 } else { $script:osdUntil = 0; $osd.Hide() } }
    }
    $e.Handled = $true
})

# Gamepad edges, polled. Seek and volume repeat while held (scrubbing is
# the whole point); everything else fires once per press.
$PAD = @(
    @{ Mask = 0x1000; Do = { Toggle-Pause };    Repeat = $false }   # A
    @{ Mask = 0x2000; Do = { Stop-Player };     Repeat = $false }   # B
    @{ Mask = 0x4000; Do = { Step-Spu };        Repeat = $false }   # X
    @{ Mask = 0x8000; Do = { Step-Audio };      Repeat = $false }   # Y
    @{ Mask = 0x0004; Do = { Invoke-Seek -15 }; Repeat = $true  }   # d-pad/stick left
    @{ Mask = 0x0008; Do = { Invoke-Seek 15 };  Repeat = $true  }   # d-pad/stick right
    @{ Mask = 0x0001; Do = { Adjust-Volume 5 }; Repeat = $true  }   # up
    @{ Mask = 0x0002; Do = { Adjust-Volume -5 };Repeat = $true  }   # down
    @{ Mask = 0x0100; Do = { Step-Episode -1 }; Repeat = $false }   # LB
    @{ Mask = 0x0200; Do = { Step-Episode 1 };  Repeat = $false }   # RB
    @{ Mask = 0x0010; Do = { $script:osdPinned = -not $script:osdPinned
                             if ($script:osdPinned) { Show-Osd '' 600000 }
                             else { $script:osdUntil = 0; $osd.Hide() } }; Repeat = $false }   # Start
)
$script:padPrev = 0
$script:padHeld = $null
$PAD_DELAY  = 400
$PAD_REPEAT = 120

function Read-Pad {
    if (-not $script:padOk) { return }
    $b = [CLIntVlc.Pad]::GetButtons()
    if ($b -lt 0) { $script:padOk = $false; return }
    $fresh = $b -band (-bnot $script:padPrev)
    $script:padPrev = $b
    foreach ($m in $PAD) {
        if ($fresh -band $m.Mask) {
            $script:padHeld = if ($m.Repeat) {
                @{ Mask = $m.Mask; Do = $m.Do; Until = [Environment]::TickCount + $PAD_DELAY }
            } else { $null }
            & $m.Do
            return
        }
    }
    if ($script:padHeld) {
        if (-not ($b -band $script:padHeld.Mask)) { $script:padHeld = $null }
        elseif ([Environment]::TickCount -ge $script:padHeld.Until) {
            $script:padHeld.Until = [Environment]::TickCount + $PAD_REPEAT
            & $script:padHeld.Do
        }
    }
}

# Double-click (or double-tap, on a touchscreen) toggles fullscreen and
# windowed, the same thing it does in VLC. (It used to leave the film the
# way Esc does - but ending playback is what Esc, B and the close box are
# FOR, and every player a double-click has ever been learned in toggles.)
# Polled like the pad, not a MouseDoubleClick handler: the vout child
# window owns every pixel the film is on, so the form never hears a click
# land there. GetAsyncKeyState hears it wherever it lands, so two checks
# narrow it to OUR picture: foreground keeps a double-click in some OTHER
# window - a dialog that stole focus - from acting on the film behind it,
# and the bounds check keeps the windowed frame's own chrome out of it
# (dragging the title bar, and Windows' double-click-to-maximize there,
# are the frame's business, not ours).
$script:lmbPrev    = $false
$script:lastClick  = -1000000
$script:dblClickMs = [int][CLIntVlc.N]::GetDoubleClickTime()

function Read-Mouse {
    $down = ([CLIntVlc.N]::GetAsyncKeyState(0x01) -band 0x8000) -ne 0
    if ($down -and -not $script:lmbPrev -and
        [CLIntVlc.N]::GetForegroundWindow() -eq $form.Handle -and
        (Get-PlayerBounds).Contains([Windows.Forms.Cursor]::Position)) {
        $now = [Environment]::TickCount
        if (($now - $script:lastClick) -le $script:dblClickMs) {
            $script:lastClick = -1000000
            Toggle-PlayerDisplay
        } else {
            $script:lastClick = $now
        }
    }
    $script:lmbPrev = $down
}

# ------------------------------------------------------------ main pump ---
# One timer drives everything: gamepad edges at 40ms, and the slower
# position/state work on every fifth tick. libvlc is polled rather than
# subscribed to on purpose - its events arrive on its own threads, and
# calling back into WinForms from there is how a player like this crashes.
$script:tick = 0
$timer = New-Object Windows.Forms.Timer
$timer.Interval = 40
$timer.Add_Tick({
    # XInput is global - it reads the controller whether or not this window
    # has it. Fullscreen that distinction never showed, but a player put
    # away by the menu key - or sitting in a window BEHIND whatever has the
    # focus now - must not keep acting on a controller that is now playing
    # something else: B here is "quit the film".
    $away = ($form.WindowState -eq 'Minimized') -or
            (-not $script:isFull -and [CLIntVlc.N]::GetForegroundWindow() -ne $form.Handle)
    if (-not $away) { Read-Pad; Read-Mouse } else { $script:padHeld = $null }
    $script:tick++
    if ($script:tick % 5 -ne 0) { return }

    if ($script:mp -eq [IntPtr]::Zero) { return }
    $st = [CLIntVlc.N]::libvlc_media_player_get_state($script:mp)

    $len = [CLIntVlc.N]::libvlc_media_player_get_length($script:mp)
    if ($len -gt 0) { $script:lastLen = [int]($len / 1000) }
    $t = [CLIntVlc.N]::libvlc_media_player_get_time($script:mp)
    if ($t -ge 0 -and [Environment]::TickCount -ge $script:seekGuard) { $script:lastTime = [int]($t / 1000) }

    # The resume seek can only land once the demuxer is actually playing;
    # asking earlier is silently dropped and the video starts from zero.
    if ($script:seekTo -gt 0 -and $st -eq 3 -and $script:lastLen -gt 0) {
        [CLIntVlc.N]::libvlc_media_player_set_time($script:mp, [long]($script:seekTo * 1000))
        $script:lastTime  = $script:seekTo
        $script:seekGuard = [Environment]::TickCount + 700
        $script:seekTo = 0
        Show-Osd ("Resumed at " + (Format-Time $script:lastTime)) 4000
    }

    # Settle what CLInt calls "Subtitles on by default", once per file.
    #
    # The two kinds of subtitles do NOT start out alike, which is the whole
    # reason this exists. VLC auto-selects a .srt sitting beside the video,
    # but a track embedded in the file it leaves on Disable unless the
    # track's language matches a preference we never set. Left alone, the
    # same setting would mean "on" for one folder and "off" for another.
    #
    # So it is enforced in both directions: switched on, select a track
    # nothing has selected; switched off, deselect the one VLC took by
    # itself. Off does not mean "unavailable" - the track stays in the list
    # for X to cycle to, it just is not showing to begin with.
    #
    # Once per file, so whichever way the user takes it with X afterwards
    # sticks instead of being undone on the next tick.
    #
    # The few seconds the track lists get to fill in are counted from the
    # first tick the file is seen playing (or paused - a pause can land
    # between two ticks), not from the open: a slow drive can spend longer
    # than that just getting there.
    if ($null -eq $script:tracksUntil -and ($st -eq 3 -or $st -eq 4)) {
        $script:tracksUntil = [Environment]::TickCount + 5000
    }
    if (-not $script:subsPicked -and $st -eq 3) {
        $subs = Get-TrackList ([CLIntVlc.N]::libvlc_video_get_spu_description($script:mp))
        if ($subs.Count -gt 1) {
            $script:subsPicked = $true
            $cur = [CLIntVlc.N]::libvlc_video_get_spu($script:mp)
            if ($Subtitles) {
                if ($cur -eq -1) {
                    $first = @($subs | Where-Object { $_.Id -ne -1 })[0]
                    [CLIntVlc.N]::libvlc_video_set_spu($script:mp, $first.Id) | Out-Null
                    Show-Note ("Subs: " + $first.Name) 3000
                }
            } elseif ($cur -ne -1) {
                [CLIntVlc.N]::libvlc_video_set_spu($script:mp, -1) | Out-Null
            }
        } elseif (-not (Test-TracksPending)) {
            $script:subsPicked = $true      # this file has none; stop asking
        }
    }

    # A windowed film keeps the frame it was given - the menu's own. It
    # used to be trimmed to the picture's shape once the size was known,
    # so the window changed size a moment after the film started (a few
    # pixels for a 16:9 film in the menu's not-quite-16:9 frame, a lot
    # for anything wider) and changed again when the menu came back at
    # its own size: two windows trading places, not one window showing a
    # film. The picture letterboxes inside the frame exactly as it does
    # fullscreen, and the frame is still the user's to drag to any shape.

    if ($st -eq 6 -or $st -eq 7) {        # Ended / Error
        if ($st -eq 6) { $script:lastTime = $script:lastLen }   # ran to the end: a watch, not a bail
        Stop-Player
        return
    }

    if ($osd.Visible) {
        if (-not $script:osdPinned -and $script:osdUntil -and [Environment]::TickCount -gt $script:osdUntil) {
            $script:osdNote = ''
            Hide-Osd
        } else {
            $osd.Invalidate()
        }
    }
    Sync-SubMargin

    if ($toast.Visible -and $script:toastUntil -and [Environment]::TickCount -gt $script:toastUntil) {
        $script:toastText  = ''
        $script:toastUntil = 0
        $toast.Hide()
    }
})

# The menu key works while a film is up: CLIntKey.ahk reads player.hwnd
# (the same handshake as clint.hwnd) and minimizes this window to get out
# of the way. Pausing on minimize lives HERE rather than in the hotkey
# script, so that a film also stops when anything else minimizes the
# window - Win+D, another launcher, whatever. Restoring does not resume:
# coming back to a paused picture and pressing A is better than audio
# starting the instant the window reappears.
$form.Add_Resize({
    if ($script:quitting) { return }
    if ($form.WindowState -eq 'Minimized') {
        if ($script:mp -ne [IntPtr]::Zero -and -not $script:paused) {
            $script:paused = $true
            [CLIntVlc.N]::libvlc_media_player_set_pause($script:mp, 1)
        }
        return
    }
    # Any other size change - a windowed resize, a maximize, a mode toggle,
    # a restore - re-fits the strip to the new frame.
    if (-not $script:switching -and -not $script:isFull -and
        $form.WindowState -eq 'Normal') { $script:winBounds = $form.Bounds }
    Place-Osd
    if ($script:mp -ne [IntPtr]::Zero -and $script:paused) {
        # Back on screen: the strip says why the picture is not moving,
        # the same way a manual pause keeps it up.
        Show-Osd '' 600000
    }
})

# A windowed frame dragged across the screen takes its strip and toast
# with it. Owned windows keep only their z-order coupled to the owner -
# position is ours to chase.
$form.Add_Move({
    if (-not $script:quitting -and $form.WindowState -eq 'Normal') {
        if (-not $script:switching -and -not $script:isFull) { $script:winBounds = $form.Bounds }
        Place-Osd
    }
})

$form.Add_Shown({
    if ($StateFile) {
        try {
            Set-Content (Join-Path (Split-Path $StateFile -Parent) 'player.hwnd') `
                ([int64]$form.Handle) -Encoding Ascii
        } catch {}
    }
    # The strip is as tall as its contents, so the text size decides it -
    # the same setting that decides how big the menu's own rows are.
    Place-Osd
    $form.Activate()
    [CLIntVlc.N]::SetForegroundWindow($form.Handle) | Out-Null
    # On screen now, so the hand-over can finish: this window's button
    # replaces the menu's, and a windowed film - sitting exactly where the
    # menu is - lets the menu go from underneath it, painted first so what
    # the menu uncovers is the film's frame and never the desktop.
    Set-MenuTab $false
    if (-not $script:isFull) { $form.Update(); Set-MenuVisible $false }
    try { [CLIntVlc.N]::SetTransitions($form.Handle, $true) } catch {}
    # Only fullscreen swallows the pointer; a windowed launch keeps it -
    # a frame you cannot see your mouse on cannot be moved or resized.
    if ($script:isFull) { [Windows.Forms.Cursor]::Hide(); $script:cursorHidden = $true }
    # A handheld left to play a film must not black out ten minutes in.
    [CLIntVlc.N]::KeepAwake($true)
    if (-not (Start-File $Video)) { Stop-Player; return }
    $timer.Start()
})

$form.Add_FormClosing({
    $timer.Stop()
    Stop-Current
    Save-State
    # The hand-back, done while this window is still up so there is no
    # beat with nothing on screen: the menu gets its button back, and under
    # a windowed film it is put where the film's frame is and shown BEHIND
    # it (never activated - CLInt takes the foreground itself a moment
    # later). Then this window goes with no closing animation, and what is
    # underneath is already the menu, in the same spot. Position only: the
    # console's size is owned by its grid and font.
    try { [CLIntVlc.N]::SetTransitions($form.Handle, $false) } catch {}
    Set-MenuTab $true
    if (-not $script:isFull -and $script:menuHwnd -ne [IntPtr]::Zero) {
        try {
            if ($form.WindowState -eq 'Normal') {
                [CLIntVlc.N]::SetWindowPos($script:menuHwnd, $form.Handle, $form.Left, $form.Top, 0, 0,
                    0x0011) | Out-Null   # NOSIZE | NOACTIVATE, z-order: directly behind the film
            }
        } catch {}
        Set-MenuVisible $true
    }
})

$code = 0
try {
    [Windows.Forms.Application]::Run($form)
} catch {
    $code = 3
    try {
        $log = if ($StateFile) { Join-Path (Split-Path $StateFile -Parent) 'player-error.txt' }
               else { Join-Path $env:TEMP 'clint-player-error.txt' }
        "$([DateTime]::Now.ToString('s'))  $($_.Exception.ToString())" | Set-Content $log -Encoding utf8
    } catch {}
} finally {
    try { Stop-Current } catch {}
    try { Save-State } catch {}
    if ($StateFile) {
        try { Remove-Item (Join-Path (Split-Path $StateFile -Parent) 'player.hwnd') -Force -ErrorAction SilentlyContinue } catch {}
    }
    try { [Windows.Forms.Cursor]::Show() } catch {}
    # Quitting from windowed mode must not leave the menu hidden - it is
    # about to take the screen back.
    try { Set-MenuVisible $true } catch {}
    try { Set-MenuTab $true } catch {}
    try { [CLIntVlc.N]::KeepAwake($false) } catch {}
    try { [CLIntVlc.N]::libvlc_release($inst) } catch {}
}
exit $code

