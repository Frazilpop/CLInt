#Requires AutoHotkey v2.0
#SingleInstance Force

; Global hardware key that toggles the CLInt menu: closed -> launch
; fullscreen (conhost, immune to Windows Terminal's WinUI gamepad
; navigation), frontmost -> minimize, minimized or behind -> bring to
; front. Identical behavior to the desktop shortcut (Launch.ps1);
; SteamMenu.ps1 itself also enforces single-instance, so the two paths
; can never race into duplicate windows.
;
; The key comes from menu-key.txt next to this script (one AutoHotkey
; key name, e.g. "AppsKey", "F13", "vk5D" - written by Install.ps1's
; optional hotkey setup). No file, or an invalid name, falls back to
; AppsKey (the GPD Win "page icon" key).

keyName := "AppsKey"
cfg := A_ScriptDir "\menu-key.txt"
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
