<#
Install-FreezeWatch.ps1 - installs FreezeWatch for the current user (no admin needed).
  * copies the scripts to %USERPROFILE%\FreezeWatch\app (logs and reports go in %USERPROFILE%\FreezeWatch)
  * registers a per-user Task Scheduler task that starts it at logon
  * starts it now
Use -Uninstall to stop it and remove the task and scripts (logs are kept).

Note: files are kept under the user profile root on purpose. If this script is run from a packaged
app's shell (for example the Claude desktop app), anything written under AppData is silently
redirected into that app's private folder, where other programs such as a browser cannot see it.
#>
[CmdletBinding()]
param([switch]$Uninstall)
$ErrorActionPreference = 'Stop'

$root = Join-Path $env:USERPROFILE 'FreezeWatch'
$app = Join-Path $root 'app'
$taskName = 'FreezeWatch'
$ps = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$oldLnk = Join-Path ([Environment]::GetFolderPath('Startup')) 'FreezeWatch.lnk'

function Stop-Running {
    Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" |
        Where-Object { $_.CommandLine -match 'FreezeWatch\.ps1' -and $_.ProcessId -ne $PID } |
        ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
}

Stop-Running
Remove-Item $oldLnk -Force -ErrorAction SilentlyContinue   # from an earlier install method
Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue

if ($Uninstall) {
    Remove-Item $app -Recurse -Force -ErrorAction SilentlyContinue
    Write-Host 'FreezeWatch stopped and removed from startup. Logs kept in' $root
    return
}

New-Item -ItemType Directory -Force -Path $app | Out-Null
foreach ($f in 'FreezeWatch.ps1', 'New-FreezeWatchReport.ps1') {
    Copy-Item (Join-Path $PSScriptRoot $f) (Join-Path $app $f) -Force
}
$script = Join-Path $app 'FreezeWatch.ps1'
$psArgs = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$script`""
$me = "$env:USERDOMAIN\$env:USERNAME"

$action = New-ScheduledTaskAction -Execute $ps -Argument $psArgs -WorkingDirectory $app
$trigger = New-ScheduledTaskTrigger -AtLogOn -User $me
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit ([TimeSpan]::Zero) -MultipleInstances IgnoreNew -StartWhenAvailable
$principal = New-ScheduledTaskPrincipal -UserId $me -LogonType Interactive -RunLevel Limited
try {
    [void](Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -Settings $settings -Principal $principal -Description 'FreezeWatch background watcher (starts at logon)')
    Start-ScheduledTask -TaskName $taskName
    Write-Host "Registered scheduled task '$taskName' (runs at logon) and started it."
} catch {
    Write-Host "Task Scheduler registration failed: $($_.Exception.Message)"
    Write-Host 'Falling back to a Startup-folder shortcut.'
    $sh = New-Object -ComObject WScript.Shell
    $s = $sh.CreateShortcut($oldLnk)
    $s.TargetPath = $ps; $s.Arguments = $psArgs; $s.WorkingDirectory = $app; $s.WindowStyle = 7
    $s.Save()
    Start-Process $ps -WindowStyle Hidden -ArgumentList $psArgs
}
Write-Host "Installed to $app"
Write-Host 'Look for the green dot in the system tray (it may be under the ^ overflow arrow).'
