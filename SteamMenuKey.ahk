#Requires AutoHotkey v2.0
#SingleInstance Force

; Menu/application key (GPD Win "page icon" key) toggles the CLInt
; menu: closed -> launch fullscreen (conhost, immune to Windows
; Terminal's WinUI gamepad navigation), frontmost -> minimize, minimized or
; behind -> bring to front. Identical behavior to the desktop shortcut
; (Launch.ps1); SteamMenu.ps1 itself also enforces single-instance, so the
; two paths can never race into duplicate windows.
AppsKey:: {
    SetTitleMatchMode 3  ; exact title only
    if hwnd := WinExist("CLInt") {
        if WinActive(hwnd) {
            WinMinimize hwnd
        } else {
            if WinGetMinMax(hwnd) = -1
                WinRestore hwnd
            WinActivate hwnd
        }
    } else {
        Run 'conhost.exe powershell.exe -NoProfile -ExecutionPolicy Bypass -File "' A_ScriptDir '\SteamMenu.ps1"'
    }
}
