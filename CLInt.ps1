# CLInt.ps1 - compatibility shim; the app itself lives in app\CLInt.ps1.
# Desktop shortcuts, hotkey scripts and updaters from before v0.2.10 all
# launch this path - forward them so every old reference keeps working.
& (Join-Path $PSScriptRoot 'app\CLInt.ps1') @args
