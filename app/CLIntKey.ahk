#Requires AutoHotkey v2.0
#SingleInstance Force
Persistent         ; with the key set to "off" there are no hotkeys left to
                   ; hold the script open, and it must stay up to see the
                   ; next one arrive
InstallKeybdHook   ; hook-based registration: fires even for keys another
                   ; program has claimed through RegisterHotKey

; Global hardware key that toggles the CLInt menu: closed -> launch
; fullscreen (conhost, immune to Windows Terminal's WinUI gamepad
; navigation), frontmost -> minimize, minimized or behind -> bring to
; front. Identical behavior to the desktop shortcut (Launch.ps1);
; CLInt.ps1 itself also enforces single-instance, so the two paths can
; never race into duplicate windows.
;
; NOTHING here may block. The whole script is one thread, so a slow step
; doesn't just delay one press - it makes every press during that time do
; nothing at all (which is what "the hotkey isn't working" looks like from
; the outside), AND it stops the script answering the message that
; #SingleInstance uses to replace it, which is what produced "could not
; close the existing instance" whenever anyone re-ran the installer just
; after using the key.

appDir   := A_ScriptDir
dataDir  := A_ScriptDir "\..\data"
keyFile  := dataDir "\menu-key.txt"
cmdFile  := dataDir "\menu-key-cmd.txt"
statFile := dataDir "\menu-key-status.txt"

; Re-binding is a FILE WRITE, not a restart: data\menu-key.txt is re-read a
; few times a second and applied live. See app\Hotkey.ps1 for the why -
; every restart-based rebind had a way to fail (a busy script, an elevated
; script, or the old key firing during its own replacement).
bound      := ""     ; the key currently registered ("" = none)
applied    := ""     ; the file value that produced it
lastState  := ""     ; what we last told CLInt through statFile
lastKey    := ""
waitUntil  := 0

; NOTHING here may ever put a dialog on screen. This script has no window,
; no taskbar button and starts at logon, so AutoHotkey's default error box
; arrives as a modal from an application the user doesn't know is running -
; on top of a fullscreen game, or invisible behind it with the script frozen
; until something dismisses it. An unhandled error ends that one thread
; quietly and goes in the log instead.
OnError LogError
LogError(err, mode) {
    global dataDir
    try FileAppend FormatTime(, "yyyy-MM-dd HH:mm:ss") "  CLIntKey: " err.Message "`n", dataDir "\error.log"
    return 1   ; exit this thread silently; the script stays up
}

ApplyKey(ReadWantedKey())
SetTimer WatchFiles, 400

WatchFiles() {
    global keyFile, cmdFile, statFile, applied, lastState, lastKey
    ; One-shot orders. The uninstaller asks this way because killing the
    ; process outright fails when this copy was started elevated.
    if FileExist(cmdFile) {
        cmd := ""
        try cmd := Trim(FileRead(cmdFile), " `t`r`n")
        try FileDelete cmdFile
        if (cmd = "exit") {
            try FileDelete statFile
            ExitApp
        }
    }
    wanted := ReadWantedKey()
    if (wanted != applied) {
        applied := wanted
        ApplyKey(wanted)
    } else if !FileExist(statFile) {
        ; CLInt deletes the status file and waits for it to come back: that
        ; round trip is how it knows a script is alive AND holding the key,
        ; rather than a file that merely says so.
        WriteStatus(lastState, lastKey)
    }
}

ReadWantedKey() {
    global keyFile
    ; A missing or unreadable file keeps the historic default: AppsKey, the
    ; menu key beside right Ctrl and the GPD Win "page icon" button.
    try {
        k := Trim(FileRead(keyFile), " `t`r`n")
        if (k != "")
            return k
    }
    return "AppsKey"
}

ApplyKey(wanted) {
    global bound, applied
    applied := wanted
    if (bound != "") {
        try Hotkey bound, , "Off"
        bound := ""
    }
    if (wanted = "" || wanted = "off" || wanted = "none") {
        WriteStatus("off", "")
        A_IconTip := "CLInt menu key: off"
        return
    }
    ; Check the name BEFORE handing it to Hotkey. A name AutoHotkey can't
    ; parse doesn't come back as a catchable failure - it surfaces later as
    ; an error the try never sees, which is how a typo in menu-key.txt used
    ; to turn into a stuck script. GetKeyVK answers on the spot: 0 means no
    ; such key.
    if (!KeyNameValid(wanted)) {
        WriteStatus("unknown", wanted)
        A_IconTip := "CLInt menu key: " wanted " - NOT A KEY NAME"
        return
    }
    ok := false
    try {
        Hotkey wanted, ToggleMenu, "On"
        ok := true
    }
    if (ok) {
        bound := wanted
        WriteStatus("ok", wanted)
        A_IconTip := "CLInt menu key: " wanted (A_IsAdmin ? " (admin)" : "")
    } else {
        ; A real key, but Windows wouldn't hand it over. This used to be a
        ; MsgBox - a modal dialog over whatever was fullscreen at the time,
        ; from a script the user had no reason to think was running. CLInt
        ; reads the result out of statFile and says so in SETTINGS instead.
        WriteStatus("fail", wanted)
        A_IconTip := "CLInt menu key: " wanted " - NOT AVAILABLE"
    }
}

; Modifier prefixes (^ Ctrl, ! Alt, + Shift, # Win, and the wildcard/pass
; -through marks) sit in front of the key itself and mean nothing to
; GetKeyVK, so strip them before asking about the key.
KeyNameValid(name) {
    base := name
    while (StrLen(base) > 1 && InStr("^!+#<>*~$", SubStr(base, 1, 1)))
        base := SubStr(base, 2)
    try
        return GetKeyVK(base) != 0
    return false
}

WriteStatus(state, key) {
    global statFile, lastState, lastKey
    lastState := state
    lastKey   := key
    try FileDelete statFile
    try FileAppend state "|" key, statFile
}

ToggleMenu(*) {
    global waitUntil
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
    ; reacting to the gamepad. Activate it explicitly once it appears, on a
    ; timer rather than in this handler: waiting here used to hold the only
    ; thread for up to eight seconds (see the header).
    waitUntil := A_TickCount + 8000
    SetTimer FocusWhenUp, 100
}

FocusWhenUp() {
    global waitUntil
    if hwnd := MenuWindow() {
        SetTimer , 0
        Activate(hwnd)
        return
    }
    if (A_TickCount > waitUntil)
        SetTimer , 0
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
