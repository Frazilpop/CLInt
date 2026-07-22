#Requires AutoHotkey v2.0
#SingleInstance Force

; Global hardware key that toggles the CLInt menu: closed -> launch
; fullscreen (conhost, immune to Windows Terminal's WinUI gamepad
; navigation), frontmost -> minimize, minimized or behind -> bring to
; front. Identical behavior to the desktop shortcut (Launch.ps1);
; CLInt.ps1 itself also enforces single-instance, so the two paths
; can never race into duplicate windows.
;
; The key comes from data\menu-key.txt (one AutoHotkey key name, e.g.
; "AppsKey", "F13", "vk5D" - written by the installer's optional hotkey
; setup). No file, or an invalid name, falls back to AppsKey (the GPD
; Win "page icon" key).

keyName := "AppsKey"
cfg := A_ScriptDir "\..\data\menu-key.txt"
if FileExist(cfg) {
    k := Trim(FileRead(cfg), " `t`r`n")
    if (k != "")
        keyName := k
}
try {
    Hotkey keyName, ToggleMenu
} catch {
    keyName := "AppsKey"
    Hotkey keyName, ToggleMenu
}
A_IconTip := "CLInt menu key: " keyName

ToggleMenu(*) {
    if hwnd := FindCLIntWindow() {
        ; Minimized wins over "active": right after minimizing, Windows can
        ; still report the window as active (focus sits on the taskbar), and
        ; checking active first made the second press a no-op.
        if WinGetMinMax(hwnd) = -1 {
            WinRestore hwnd
            WinActivate hwnd
        } else if WinActive(hwnd) {
            WinMinimize hwnd
        } else {
            WinActivate hwnd
        }
    } else {
        Run 'conhost.exe powershell.exe -NoProfile -ExecutionPolicy Bypass -File "' A_ScriptDir '\CLInt.ps1"'
        ; Focus-steal protection can leave the new window fullscreen on top
        ; but without keyboard focus - the previously focused app then keeps
        ; reacting to the gamepad. Activate it explicitly once it appears,
        ; polling the verified finder rather than WinWait so an unrelated
        ; terminal that happens to be titled "CLInt" can't hijack the wait.
        deadline := A_TickCount + 10000
        while A_TickCount < deadline {
            if hwnd := FindCLIntWindow() {
                WinActivate hwnd
                return
            }
            Sleep 250
        }
    }
}

; A bare title match is ambiguous: any console sitting in a folder named
; CLInt (a dev shell, Claude Code's own conhost) carries the identical
; title, and matching one of those made the key activate/minimize the
; wrong terminal or refuse to launch the real menu. Console windows report
; the attached shell's PID, so the real menu is the candidate whose
; powershell is actually running CLInt.ps1.
FindCLIntWindow() {
    SetTitleMatchMode 3  ; exact title only
    for hwnd in WinGetList("CLInt ahk_class ConsoleWindowClass") {
        try {
            pid := WinGetPID(hwnd)
            q := "SELECT CommandLine FROM Win32_Process WHERE ProcessId=" pid
            for p in ComObjGet("winmgmts:").ExecQuery(q)
                if InStr(p.CommandLine, "CLInt.ps1")
                    return hwnd
        }
    }
    return 0
}
