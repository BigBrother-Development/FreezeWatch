<#
Capture-DriverTrace.ps1 - names the driver behind an interrupt/DPC freeze. Run from an ELEVATED PowerShell.

It records a small kernel trace (DriverLatency.wprp) in a circular memory buffer, watches the same
signals as FreezeWatch, and when a storm or freeze happens saves the buffer to
%USERPROFILE%\FreezeWatch\traces and summarizes DPC/ISR time per driver (Get-DpcSummary.ps1).
It runs beside the FreezeWatch watcher and changes nothing permanent.

  -SelfTest   record for 10 seconds, save, summarize and exit (checks that capture works)

Stop it with Ctrl+C. If the window is closed instead, the recording keeps running until
"wpr -cancel" is run from an elevated prompt, or the PC restarts.
#>
[CmdletBinding()]
param(
    [string]$OutDir = (Join-Path $env:USERPROFILE 'FreezeWatch\traces'),
    [double]$IrqPct = 15,
    [int]$IrqSustainSec = 3,
    [double]$StallSec = 2.5,
    [int]$SettleSec = 5,
    [int]$QuietSec = 30,
    [int]$MaxCaptures = 3,
    [switch]$SelfTest
)
$ErrorActionPreference = 'Stop'

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) { Write-Host 'This needs an elevated PowerShell (Run as administrator).'; exit 1 }

$wpr = Join-Path $env:SystemRoot 'System32\wpr.exe'
$traceProfile = (Join-Path $PSScriptRoot 'DriverLatency.wprp') + '!DriverLatency'
$summary = Join-Path $PSScriptRoot 'Get-DpcSummary.ps1'

function Invoke-Wpr([string[]]$wprArgs) {
    $ErrorActionPreference = 'Continue'   # stderr from a native tool must not throw here
    $text = & $wpr @wprArgs 2>&1 | Out-String
    [pscustomobject]@{ Code = $LASTEXITCODE; Text = $text.Trim() }
}
function Start-Capture {
    $r = Invoke-Wpr @('-start', $traceProfile)
    if ($r.Code -ne 0) { throw "wpr -start failed ($($r.Code)): $($r.Text)" }
    $script:tracing = $true
}
function Save-Capture([string]$reason) {
    $path = Join-Path $OutDir ('trace-{0:yyyyMMdd-HHmmss}.etl' -f (Get-Date))
    Write-Host ('[{0:HH:mm:ss}] saving trace ({1}). This can take a minute...' -f (Get-Date), $reason)
    $r = Invoke-Wpr @('-stop', $path, 'FreezeWatch driver capture', '-skipPdbGen')
    if ($r.Code -ne 0 -or -not (Test-Path $path)) { throw "wpr -stop failed ($($r.Code)): $($r.Text)" }
    $script:tracing = $false
    Write-Host ('[{0:HH:mm:ss}] saved {1} ({2:N0} MB)' -f (Get-Date), $path, ((Get-Item $path).Length / 1MB))
    $path
}
function Show-Summary([string]$path) {
    try { & $summary -Path $path | Out-Host }
    catch { Write-Host "Summary failed (the trace is kept): $($_.Exception.Message)" }
}

New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
$status = Invoke-Wpr @('-status')
if ($status.Text -notmatch 'WPR is not recording') {
    Write-Host "Another WPR recording seems to be active, so nothing was started. Status:`n$($status.Text)"
    Write-Host 'If it is a leftover from this script, run: wpr -cancel'
    exit 1
}

try { (Get-Process -Id $PID).PriorityClass = 'AboveNormal' } catch {}
Add-Type -Namespace FreezeWatch -Name Awake -MemberDefinition '[DllImport("kernel32.dll")] public static extern bool QueryUnbiasedInterruptTime(out ulong unbiasedTime);'
function Get-AwakeSec { $t = [uint64]0; [void][FreezeWatch.Awake]::QueryUnbiasedInterruptTime([ref]$t); $t / 1e7 }

$script:tracing = $false
try {
    Start-Capture
    if ($SelfTest) {
        Write-Host 'Self-test: recording for 10 seconds...'
        Start-Sleep -Seconds 10
        Show-Summary (Save-Capture 'self-test')
        return
    }

    $cInt = New-Object System.Diagnostics.PerformanceCounter('Processor Information', '% Interrupt Time', '_Total', $true)
    $cDpc = New-Object System.Diagnostics.PerformanceCounter('Processor Information', '% DPC Time', '_Total', $true)
    [void]$cInt.NextValue(); [void]$cDpc.NextValue()
    Write-Host ('Armed. Waiting for interrupt+DPC >= {0}% for {1} s, or a freeze over {2} s. Leave this window open; Ctrl+C stops.' -f $IrqPct, $IrqSustainSec, $StallSec)

    $captures = 0; $run = 0; $quiet = 0; $armed = $true
    $prevUtc = [datetime]::UtcNow; $prevAwake = Get-AwakeSec
    while ($captures -lt $MaxCaptures) {
        Start-Sleep -Seconds 1
        $utc = [datetime]::UtcNow; $awake = Get-AwakeSec
        $gap = $awake - $prevAwake
        $slept = ($utc - $prevUtc).TotalSeconds - $gap
        $prevUtc = $utc; $prevAwake = $awake
        $load = $cInt.NextValue() + $cDpc.NextValue()
        if ($slept -gt 5) { $run = 0; continue }   # resume from sleep, not a freeze

        if ($load -ge $IrqPct) { $run++ } else { $run = 0 }
        $frozen = $gap -gt $StallSec
        if (-not $armed) {
            # one capture per episode: wait for a quiet stretch before arming again
            if ($frozen -or $load -ge $IrqPct) { $quiet = 0 } else { $quiet++ }
            if ($quiet -ge $QuietSec) { $armed = $true; Write-Host ('[{0:HH:mm:ss}] armed again' -f (Get-Date)) }
            continue
        }
        if (-not $frozen -and $run -lt $IrqSustainSec) { continue }

        $reason = if ($frozen) { 'freeze of {0:N1} s' -f $gap } else { 'interrupt+DPC {0:N1}%' -f $load }
        Write-Host ('[{0:HH:mm:ss}] triggered: {1}' -f (Get-Date), $reason)
        Start-Sleep -Seconds $SettleSec
        $path = Save-Capture $reason
        $captures++
        if ($captures -lt $MaxCaptures) { Start-Capture }
        Show-Summary $path
        $armed = $false; $quiet = 0; $run = 0
        $prevUtc = [datetime]::UtcNow; $prevAwake = Get-AwakeSec
    }
    Write-Host "Done: $captures capture(s) saved in $OutDir"
} finally {
    if ($script:tracing) { [void](Invoke-Wpr @('-cancel')); Write-Host 'Recording cancelled.' }
}
