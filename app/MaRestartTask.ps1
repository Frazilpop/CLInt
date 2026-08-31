# Registers (or removes, with -Remove) the CLIntMARestart scheduled task.
#
# Why it exists: Motion Assistant only starts watching the gamepad triggers
# when it itself starts up, so a gyro button chosen in CLInt does nothing
# until Motion Assistant has been restarted (see Assert-GyroArmer in
# CLInt.ps1). Motion Assistant runs elevated, which means an unelevated
# CLInt cannot stop it - Windows is right to refuse. This task carries the
# one elevated verb CLInt needs: stop MotionAssistant.exe and start it
# again. Registering it is the single step that needs the UAC prompt; once
# it exists, CLInt can fire it whenever a newly chosen gyro button calls
# for a restart, and the user never sees the prompt again.
#
# The task's action is self-contained (an -EncodedCommand, no script path),
# so moving or deleting the CLInt folder can never turn the task into a
# reference to a file that is not there any more.
param([switch]$Remove)

$taskName = 'CLIntMARestart'

$id = [Security.Principal.WindowsIdentity]::GetCurrent()
if (-not ([Security.Principal.WindowsPrincipal]$id).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host 'This script needs to run elevated - CLInt launches it via a UAC prompt.' -ForegroundColor Yellow
    exit 1
}

if ($Remove) {
    Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
    exit 0
}

# What the task runs, elevated, each time CLInt starts it: put Motion
# Assistant down, then bring it back. The relaunch prefers Motion Assistant's
# own autostart task (that is how the machine normally starts it, elevation
# included) and falls back to the exe path the dying process reported when
# that task is missing or declines to run. If Motion Assistant was not
# running at all there is nothing to do - its next start reads the profile
# CLInt has already written.
$restart = @'
$ma = @(Get-Process MotionAssistant -ErrorAction SilentlyContinue)
if ($ma.Count -eq 0) { exit 0 }
$exe = $null
try { $exe = $ma[0].Path } catch {}
$ma | Stop-Process -Force -ErrorAction SilentlyContinue
$n = 0
while (@(Get-Process MotionAssistant -ErrorAction SilentlyContinue).Count -gt 0 -and $n -lt 40) {
    Start-Sleep -Milliseconds 250; $n++
}
schtasks /run /tn MotionAssistant | Out-Null
$n = 0
while (@(Get-Process MotionAssistant -ErrorAction SilentlyContinue).Count -eq 0 -and $n -lt 20) {
    Start-Sleep -Milliseconds 250; $n++
}
if (@(Get-Process MotionAssistant -ErrorAction SilentlyContinue).Count -eq 0 -and $exe) {
    Start-Process $exe -WorkingDirectory (Split-Path $exe -Parent)
}
'@
$enc = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($restart))

$action    = New-ScheduledTaskAction -Execute 'powershell.exe' `
                 -Argument "-NoProfile -WindowStyle Hidden -EncodedCommand $enc"
$principal = New-ScheduledTaskPrincipal -UserId $id.Name -RunLevel Highest -LogonType Interactive
$settings  = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
                 -ExecutionTimeLimit (New-TimeSpan -Minutes 2)
Register-ScheduledTask -TaskName $taskName -Action $action -Principal $principal `
    -Settings $settings -Force | Out-Null
