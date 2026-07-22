#Requires AutoHotkey v2.0
#SingleInstance Force
InstallKeybdHook   ; hook-based registration: fires even for keys another
                   ; program has claimed through RegisterHotKey

; Global hardware key that toggles the CLInt menu: closed -> launch
; fullscreen (conhost, immune to Windows Terminal's WinUI gamepad
; navigation), frontmost -> minimize, minimized or behind -> bring to
; front. Identical behavior to the desktop shortcut (Launch.ps1);
; CLInt.ps1 itself also enforces single-instance, so the two paths can
; never race into duplicate windows.
;
; Everything in the key press is designed to finish in milliseconds. The
; handler runs single-threaded (AutoHotkey's default), so any slow step
; here doesn't just delay one press - it makes every press during that
; time do nothing at all, which is what "the hotkey isn't working" looks
; like from the outside.

appDir  := A_ScriptDir
dataDir := A_ScriptDir "\..\data"

; The key comes from data\menu-key.txt (one AutoHotkey key name, e.g.
; "AppsKey", "F13", "vk5D" - written by the installer's hotkey setup).
; No file, or a name AutoHotkey rejects, falls back to AppsKey (the GPD
; Win "page icon" key).
keyName := "AppsKey"
try {
    k := Trim(FileRead(dataDir "\menu-key.txt"), " `t`r`n")
    if (k != "")
        keyName := k
}

; Registering can still fail if another program already owns the key.
; That used to leave the script running with no working key and no hint
; why - exactly what "the hotkey just doesn't work" looks like - so a
; total failure says so out loud instead of dying quietly.
bound := ""
for candidate in [keyName, "AppsKey"] {
    try {
        Hotkey candidate, ToggleMenu
        bound := candidate
        break
    }
}
if (bound = "") {
    MsgBox "CLInt could not register the menu key (" keyName ").`n`nAnother "
         . "program is probably already using it. Re-run Install.bat to pick "
         . "a different key.", "CLInt", "Icon!"
    ExitApp
}
A_IconTip := "CLInt menu key: " bound (A_IsAdmin ? " (admin)" : "")

ToggleMenu(*) {
    if hwnd := MenuWindow() {
        ; Minimized wins over "active": right after minimizing, Windows can
        ; still report the window as active (focus sits on the taskbar), and
        ; checking active first made the second press a no-op.
        if WinGetMinMax(hwnd) = -1
            Activate(hwnd)
        else if WinActive(hwnd)
            WinMinimize hwnd
        else
            Activate(hwnd)
        return
    }
    Run 'conhost.exe powershell.exe -NoProfile -ExecutionPolicy Bypass -File "' appDir '\CLInt.ps1"'
    ; Focus-steal protection can leave the new window fullscreen on top but
    ; without keyboard focus - the previously focused app then keeps
    ; reacting to the gamepad. Activate it explicitly once it appears.
    ; Bounded, because presses are ignored until this returns.
    deadline := A_TickCount + 8000
    while (A_TickCount < deadline) {
        if hwnd := MenuWindow() {
            Activate(hwnd)
            return
        }
        Sleep 100
    }
}

; Bringing a window forward is the step most likely to fail silently.
; Windows refuses foreground changes from a process that doesn't own the
; foreground, so behind a fullscreen game a plain WinActivate can be
; dropped with no error at all - the key "did nothing". Check the result
; and escalate instead of assuming it worked.
Activate(hwnd) {
    if WinGetMinMax(hwnd) = -1
        try WinRestore hwnd
    loop 3 {
        try WinActivate hwnd
        if WinActive(hwnd)
            return
        Sleep 50
    }
    ; Last resort: a round trip through minimized. Restoring a minimized
    ; window is allowed to take the foreground even when a direct activate
    ; request is refused.
    try {
        WinMinimize hwnd
        WinRestore hwnd
        WinActivate hwnd
    }
}

; CLInt.ps1 writes its own console window handle to data\clint.hwnd as it
; starts, so finding the menu is a single existence check. It replaces a
; WMI command-line query that ran once per candidate window on every key
; press - slow enough on a cold WMI service to swallow presses outright,
; and silently returning "not running" whenever it failed. Matching on the
; title alone is not an option: any console sitting in a folder named
; CLInt (a dev shell, Claude Code's own conhost) carries the identical
; title. Handle AND title must match here, so a stale file left behind by
; a crash can't resolve to some unrelated recycled window - and when it
; doesn't match, the key just launches, where CLInt.ps1's own
; single-instance check catches any duplicate.
MenuWindow() {
    try hwnd := Integer(Trim(FileRead(dataDir "\clint.hwnd"), " `t`r`n"))
    catch
        return 0
    SetTitleMatchMode 3   ; exact title
    return WinExist("CLInt ahk_id " hwnd)
}
