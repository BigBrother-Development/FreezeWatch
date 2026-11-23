<#
FreezeWatch.ps1 - lightweight background watcher for whole-system stalls and
interrupt/DPC storms ("System Interrupts" CPU spikes).

What it does (no admin needed):
  * Once a second, reads total % Interrupt Time, % DPC Time, Interrupts/sec and
    DPC rate, and logs them to a daily log file.
  * Every 5 seconds (and right after a stall) records the top CPU processes and
    GPU engine use (3D, VideoDecode, Copy ...) including which process owns it.
  * Detects a STALL: its own 1-second loop took longer than -StallSec, which
    means the whole machine (or at least this process) was frozen.
  * Detects an IRQ STORM: interrupt + DPC time stays at or above -IrqPct for
    -IrqSustainSec seconds.
  * On either, writes incidents\incident-*.txt with the 2 minutes before it, the
    PostSec seconds after it, and relevant System / Application event-log entries.

With -Trace (needs admin, heavy, off by default): keeps a circular Windows
Performance Recorder "Video" trace in memory (includes DPC/ISR and driver load
events) and saves an .etl next to each incident, so the offending driver can be
identified in Windows Performance Analyzer.
#>
[CmdletBinding()]
param(
    [string]$OutDir = (Join-Path $env:USERPROFILE 'FreezeWatch'),
    [double]$StallSec = 2.5,
    [double]$IrqPct = 15,
    [int]$IrqSustainSec = 3,
    [int]$PostSec = 20,
    [int]$KeepDays = 7,
    [int]$RunSeconds = 0,
    [switch]$Trace,
    [switch]$NoTray
)

$ErrorActionPreference = 'Stop'
$ncpu = [Environment]::ProcessorCount
$incDir = Join-Path $OutDir 'incidents'
New-Item -ItemType Directory -Force -Path $OutDir, $incDir | Out-Null

$mutex = New-Object System.Threading.Mutex($false, 'Local\FreezeWatch')
if (-not $mutex.WaitOne(0)) { Write-Host 'FreezeWatch is already running.'; exit 1 }

# Slightly raised priority so a measured gap is the system's stall, not this process being starved.
try { (Get-Process -Id $PID).PriorityClass = 'AboveNormal' } catch {}

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if ($Trace -and -not $isAdmin) { Write-Host 'Note: -Trace needs an elevated shell; continuing without it.'; $Trace = $false }

# ---------- counters ----------
function New-Ctr($name) {
    $c = New-Object System.Diagnostics.PerformanceCounter('Processor Information', $name, '_Total', $true)
    [void]$c.NextValue()
    $c
}
$cInt = New-Ctr '% Interrupt Time'
$cDpc = New-Ctr '% DPC Time'
$cIps = New-Ctr 'Interrupts/sec'
$cDpr = New-Ctr 'DPC Rate'

# ---------- log + ring buffer ----------
$script:logDay = ''
$script:logWriter = $null
$ring = New-Object 'System.Collections.Generic.Queue[string]'

function Write-Log([string]$line) {
    $day = (Get-Date).ToString('yyyyMMdd')
    if ($day -ne $script:logDay) {
        if ($script:logWriter) { $script:logWriter.Dispose() }
        $path = Join-Path $OutDir "samples-$day.log"
        $fs = [IO.File]::Open($path, [IO.FileMode]::Append, [IO.FileAccess]::Write, [IO.FileShare]::ReadWrite)
        $script:logWriter = New-Object IO.StreamWriter($fs)
        $script:logWriter.AutoFlush = $true
        $script:logDay = $day
    }
    $script:logWriter.WriteLine($line)
}
function Add-Line([string]$line) {
    $ring.Enqueue($line)
    while ($ring.Count -gt 120) { [void]$ring.Dequeue() }
    Write-Log $line
    if ($script:inc) { [IO.File]::AppendAllText($script:inc.Path, $line + "`r`n") }
}

# ---------- process + GPU snapshots ----------
$script:procPrev = @{}
$script:pidName = @{}

function Read-Procs {
    # One bulk read of the 'Process' counter category (a few ms), instead of opening every process.
    # Pct is percent of TOTAL CPU capacity (all cores), keyed by PID so instance renumbering is harmless.
    $res = New-Object System.Collections.Generic.List[object]
    try {
        $col = (New-Object System.Diagnostics.PerformanceCounterCategory('Process')).ReadCategory()
        $cpu = $col['% Processor Time']; $ids = $col['ID Process']
    } catch { return @() }
    $new = @{}
    $names = @{}
    foreach ($k in $cpu.Keys) {
        if ($k -eq '_Total' -or $k -eq 'Idle') { continue }
        try {
            $procId = [int]$ids[$k].Sample.RawValue
            $s = $cpu[$k].Sample
            $new[$procId] = $s
            $names[$procId] = $k -replace '#\d+$', ''
            if ($script:procPrev.ContainsKey($procId)) {
                $v = [Diagnostics.CounterSample]::Calculate($script:procPrev[$procId], $s)
                if ($v -gt 0) { $res.Add([pscustomobject]@{ Id = $procId; Name = $names[$procId]; Pct = $v / $ncpu }) }
            }
        } catch {}
    }
    $script:procPrev = $new
    $script:pidName = $names
    $res | Sort-Object Pct -Descending | Select-Object -First 5
}

$script:gpuPrev = @{}
$script:gpuTypes = @{}
function Read-Gpu {
    # returns @{ Types = engtype -> max engine %; Top = top (pid,engtype,%) }
    try {
        $cat = New-Object System.Diagnostics.PerformanceCounterCategory('GPU Engine')
        $dc = $cat.ReadCategory()['Utilization Percentage']
    } catch { return @{ Types = @{}; Top = @() } }
    $newPrev = @{}
    $perEngine = @{}   # "phys_eng_type" -> sum across pids
    $perPid = @{}      # "pid|type" -> sum
    foreach ($k in $dc.Keys) {
        $s = $dc[$k].Sample
        $newPrev[$k] = $s
        if ($script:gpuPrev.ContainsKey($k)) {
            $v = [Diagnostics.CounterSample]::Calculate($script:gpuPrev[$k], $s)
            if ($v -gt 0 -and $k -match 'pid_(\d+)_.*phys_(\d+)_eng_(\d+)_engtype_(\w+)') {
                $procId = $matches[1]; $phys = $matches[2]; $eng = $matches[3]; $type = $matches[4]
                $ek = "$phys|$eng|$type"
                $perEngine[$ek] = [double]$perEngine[$ek] + $v
                $pk = "$procId|$type"
                $perPid[$pk] = [double]$perPid[$pk] + $v
            }
        }
    }
    $script:gpuPrev = $newPrev
    $types = @{}
    foreach ($ek in $perEngine.Keys) {
        $type = $ek.Split('|')[2]
        if (-not $types.ContainsKey($type) -or $perEngine[$ek] -gt $types[$type]) { $types[$type] = $perEngine[$ek] }
    }
    $top = $perPid.GetEnumerator() | Where-Object { $_.Value -ge 1 } | Sort-Object Value -Descending | Select-Object -First 3 | ForEach-Object {
        $parts = $_.Key.Split('|')
        [pscustomobject]@{ Id = [int]$parts[0]; Type = $parts[1]; Pct = $_.Value }
    }
    @{ Types = $types; Top = @($top) }
}

function Format-Snapshot($procs, $gpu) {
    $p = ($procs | ForEach-Object { '{0}({1}) {2:N1}%' -f $_.Name, $_.Id, $_.Pct }) -join ', '
    $g = ($gpu.Types.GetEnumerator() | Where-Object { $_.Value -ge 1 } | Sort-Object Value -Descending | ForEach-Object { '{0}={1:N0}%' -f $_.Key, $_.Value }) -join ' '
    $gt = ($gpu.Top | ForEach-Object { $n = $script:pidName[$_.Id]; if (-not $n) { $n = '?' }; '{0}({1}) {2} {3:N0}%' -f $n, $_.Id, $_.Type, $_.Pct }) -join ', '
    "# SNAP cpu-top: $p | gpu-engines: $g | gpu-top: $gt"
}

# ---------- event-log lookup for incidents ----------
function Get-IncidentEvents([datetime]$from, [datetime]$to) {
    $out = New-Object System.Collections.Generic.List[string]
    $fmt = {
        param($e)
        $m = ($e.Message -replace '\s+', ' ')
        if ($m.Length -gt 200) { $m = $m.Substring(0, 200) }
        '{0:HH:mm:ss} {1} [{2} {3}] {4}' -f $e.TimeCreated, $e.LevelDisplayName, $e.ProviderName, $e.Id, $m
    }
    try {
        Get-WinEvent -FilterHashtable @{ LogName = 'System'; StartTime = $from; EndTime = $to } -ErrorAction SilentlyContinue |
            Where-Object { $_.Level -le 3 -or $_.ProviderName -match 'nvlddmkm|Display|WHEA|DxgKrnl|Kernel-Power|Kernel-PnP|stornvme|disk|Ntfs' } |
            Select-Object -First 40 | ForEach-Object { $out.Add('SYSTEM  ' + (& $fmt $_)) }
    } catch {}
    try {
        Get-WinEvent -FilterHashtable @{ LogName = 'Application'; StartTime = $from; EndTime = $to; ProviderName = 'Windows Error Reporting', 'Application Hang', 'Application Error' } -ErrorAction SilentlyContinue |
            Select-Object -First 20 | ForEach-Object { $out.Add('APP     ' + (& $fmt $_)) }
    } catch {}
    if ($out.Count -eq 0) { $out.Add('(no matching events)') }
    $out
}

# ---------- optional WPR trace ----------
function Start-WprTrace { if ($Trace) { try { & wpr.exe -cancel 2>&1 | Out-Null } catch {}; & wpr.exe -start Video 2>&1 | Out-Null } }
function Save-WprTrace([string]$path) {
    if (-not $Trace) { return 'not enabled' }
    try {
        $r = & wpr.exe -stop $path 2>&1 | Out-String
        Start-WprTrace
        # keep only the 3 newest traces (they can be large)
        Get-ChildItem $incDir -Filter 'trace-*.etl' | Sort-Object LastWriteTime -Descending | Select-Object -Skip 3 | Remove-Item -Force -ErrorAction SilentlyContinue
        if (Test-Path $path) { "saved $path" } else { "wpr stop output: $($r.Trim())" }
    } catch { "failed: $($_.Exception.Message)" }
}

# ---------- tray icon (skipped with -NoTray) ----------
$script:ni = $null
$script:ctx = $null
$script:stop = $false
$script:unseen = 0
$script:latestIncident = $null

function New-DotIcon([int]$r, [int]$g, [int]$b) {
    $bmp = New-Object System.Drawing.Bitmap 16, 16
    $gfx = [System.Drawing.Graphics]::FromImage($bmp)
    $gfx.SmoothingMode = 'AntiAlias'
    $gfx.Clear([System.Drawing.Color]::Transparent)
    $gfx.FillEllipse((New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb($r, $g, $b))), 1, 1, 13, 13)
    $gfx.DrawEllipse((New-Object System.Drawing.Pen ([System.Drawing.Color]::FromArgb(255, 255, 255)), 1), 1, 1, 13, 13)
    $gfx.Dispose()
    [System.Drawing.Icon]::FromHandle($bmp.GetHicon())   # two icons for the whole run; handles are intentionally kept
}
function Set-Tray([bool]$alert, [string]$text) {
    if (-not $script:ni) { return }
    $script:ni.Icon = $(if ($alert) { $script:icoRed } else { $script:icoGreen })
    $script:ni.Text = $text.Substring(0, [Math]::Min(63, $text.Length))
}
function Send-Alert([string]$kind, [string]$detail, [string]$path) {
    $script:unseen++
    $script:latestIncident = $path
    if (-not $script:ni) { return }
    Set-Tray $true ('FreezeWatch: {0} new incident(s), last {1:HH:mm}' -f $script:unseen, (Get-Date))
    $title = if ($kind -eq 'stall') { 'System stall detected' } else { 'Interrupt/DPC storm detected' }
    $script:ni.ShowBalloonTip(8000, $title, ($detail + "`nClick to open the report."), [System.Windows.Forms.ToolTipIcon]::Warning)
}
function Clear-Alerts { $script:unseen = 0; Set-Tray $false 'FreezeWatch: watching' }
function Open-LatestIncident {
    $f = $script:latestIncident
    if (-not $f -or -not (Test-Path $f)) {
        $f = Get-ChildItem $incDir -Filter 'incident-*.txt' -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1 -ExpandProperty FullName
    }
    if ($f) { Start-Process $f } else { Start-Process explorer.exe $OutDir }
    Clear-Alerts
}
function Open-Report {
    $rep = Join-Path $PSScriptRoot 'New-FreezeWatchReport.ps1'
    if (Test-Path $rep) {
        Start-Process powershell.exe -WindowStyle Hidden -ArgumentList '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$rep`"", '-LogDir', "`"$OutDir`"", '-Open'
        Clear-Alerts
    }
}
function Stop-Watcher {
    if ($script:ctx) { $script:ctx.ExitThread() } else { $script:stop = $true }
}
function Initialize-Tray {
    Add-Type -AssemblyName System.Windows.Forms, System.Drawing
    [System.Windows.Forms.Application]::EnableVisualStyles()
    $script:icoGreen = New-DotIcon 40 167 69
    $script:icoRed = New-DotIcon 220 53 69
    $ni = New-Object System.Windows.Forms.NotifyIcon
    $script:ni = $ni
    $menu = New-Object System.Windows.Forms.ContextMenuStrip
    [void]$menu.Items.Add('Open report (last 24 h)').Add_Click({ try { Open-Report } catch {} })
    [void]$menu.Items.Add('Open latest incident').Add_Click({ try { Open-LatestIncident } catch {} })
    [void]$menu.Items.Add('Open log folder').Add_Click({ try { Start-Process explorer.exe $OutDir } catch {} })
    [void]$menu.Items.Add('Mark all seen').Add_Click({ try { Clear-Alerts } catch {} })
    [void]$menu.Items.Add('-')
    [void]$menu.Items.Add('Exit FreezeWatch').Add_Click({ Stop-Watcher })
    $ni.ContextMenuStrip = $menu
    $ni.Add_DoubleClick({ try { Open-Report } catch {} })
    $ni.Add_BalloonTipClicked({ try { Open-LatestIncident } catch {} })
    Set-Tray $false 'FreezeWatch: watching'
    $ni.Visible = $true
    $script:ctx = New-Object System.Windows.Forms.ApplicationContext
}

# ---------- incidents ----------
$script:inc = $null
function Open-Incident([string]$kind, [string]$detail, [double]$nowSec) {
    if ($script:inc) {
        $script:inc.EndAt = [Math]::Min($nowSec + $PostSec, $script:inc.HardEnd)
        [IO.File]::AppendAllText($script:inc.Path, ("{0:HH:mm:ss} + further trigger: {1} {2}`r`n" -f (Get-Date), $kind, $detail))
        return
    }
    $stamp = Get-Date
    $path = Join-Path $incDir ('incident-{0:yyyyMMdd-HHmmss}-{1}.txt' -f $stamp, $kind)
    $head = @(
        "FreezeWatch incident: $kind",
        "Detected: $($stamp.ToString('yyyy-MM-dd HH:mm:ss'))",
        "Detail:   $detail",
        "Admin: $isAdmin   Trace: $Trace   CPUs: $ncpu",
        '',
        '--- last ~2 minutes before detection (newest last) ---'
    ) + $ring.ToArray() + @('', '--- after detection ---')
    [IO.File]::WriteAllLines($path, $head)
    $script:inc = @{ Path = $path; Kind = $kind; Start = $stamp; EndAt = $nowSec + $PostSec; HardEnd = $nowSec + 300 }
    Write-Host ('[{0:HH:mm:ss}] incident: {1} - {2}' -f $stamp, $kind, $detail)
    Send-Alert $kind $detail $path
}
function Close-Incident {
    $i = $script:inc
    $script:inc = $null
    $ev = Get-IncidentEvents $i.Start.AddSeconds(-40) (Get-Date)
    $tr = Save-WprTrace ($i.Path -replace 'incident-', 'trace-' -replace '\.txt$', '.etl')
    $tail = @('', '--- event log entries around the incident ---') + $ev + @('', "--- WPR trace: $tr ---")
    [IO.File]::AppendAllText($i.Path, ($tail -join "`r`n") + "`r`n")
    Write-Host ('[{0:HH:mm:ss}] incident closed: {1}' -f (Get-Date), $i.Path)
}

# ---------- housekeeping ----------
function Remove-OldFiles {
    $cut = (Get-Date).AddDays(-$KeepDays)
    Get-ChildItem $OutDir -Filter 'samples-*.log' -ErrorAction SilentlyContinue | Where-Object LastWriteTime -lt $cut | Remove-Item -Force -ErrorAction SilentlyContinue
    Get-ChildItem $incDir -Filter 'incident-*.txt' -ErrorAction SilentlyContinue | Where-Object LastWriteTime -lt (Get-Date).AddDays(-30) | Remove-Item -Force -ErrorAction SilentlyContinue
}

# ---------- main loop ----------
$script:sw = [Diagnostics.Stopwatch]::StartNew()
$script:prev = 0.0
$script:tick = 0
$script:irqRun = 0
$script:lastWork = 0.0
$script:lastSelf = 0.0
$script:lastHouse = 0.0
$script:gpuNow = @{ Types = @{}; Top = @() }
$script:selfProc = Get-Process -Id $PID
$script:selfCpu0 = 0.0
$script:selfT0 = 0.0

function Invoke-Tick {
    $now = $script:sw.Elapsed.TotalSeconds
    # interval since the last tick, minus the time we spent on our own snapshot work, so the
    # snapshot cost is never mistaken for a system stall
    $dt = ($now - $script:prev) - $script:lastWork
    $script:prev = $now
    $script:tick++
    if ($dt -lt 0) { $dt = 0 }
    if ($RunSeconds -gt 0 -and $now -gt $RunSeconds) { Stop-Watcher; return }

    $int = $cInt.NextValue(); $dpc = $cDpc.NextValue(); $ips = $cIps.NextValue(); $dpr = $cDpr.NextValue()
    $resume = $dt -gt 120
    $stall = (-not $resume) -and ($dt -gt $StallSec)
    if (($int + $dpc) -ge $IrqPct) { $script:irqRun++ } else { $script:irqRun = 0 }

    $snap = $stall -or ($script:tick % 5 -eq 0) -or ($script:irqRun -eq $IrqSustainSec)
    $snapLine = $null
    $script:lastWork = 0.0
    if ($snap) {
        $w0 = $script:sw.Elapsed.TotalSeconds
        $procs = Read-Procs
        $script:gpuNow = Read-Gpu
        $script:lastWork = $script:sw.Elapsed.TotalSeconds - $w0
        $snapLine = (Format-Snapshot $procs $script:gpuNow) + (' (snapshot took {0:N0}ms)' -f ($script:lastWork * 1000))
    }
    $g3 = [double]$script:gpuNow.Types['3D']; $gv = [double]$script:gpuNow.Types['VideoDecode']; $gc = [double]$script:gpuNow.Types['Copy']
    $row = '{0:HH:mm:ss.f} dt={1,6:N0}ms int={2,5:N1}% dpc={3,5:N1}% irq/s={4,7:N0} dpc/s={5,7:N0} gpu3d={6,3:N0} vdec={7,3:N0} copy={8,3:N0}{9}' -f `
        (Get-Date), ($dt * 1000), $int, $dpc, $ips, $dpr, $g3, $gv, $gc, $(if ($resume) { '  RESUME-GAP(ignored)' } elseif ($stall) { '  STALL' } else { '' })

    # triggers first so the row itself lands in the incident file as the first "after" line
    if ($stall) { Open-Incident 'stall' ('loop gap {0:N1}s (expected 1s); counters below are averaged over the gap' -f $dt) $now }
    elseif ($script:irqRun -ge $IrqSustainSec) { Open-Incident 'irqstorm' ('interrupt+DPC {0:N1}% for {1}+ s' -f ($int + $dpc), $script:irqRun) $now }

    Add-Line $row
    if ($snapLine) { Add-Line $snapLine }

    if ($script:inc -and $now -ge $script:inc.EndAt -and $script:irqRun -lt $IrqSustainSec) { Close-Incident }

    if ($now - $script:lastSelf -ge 60) {
        $script:selfProc.Refresh()
        $cpu = $script:selfProc.TotalProcessorTime.TotalSeconds
        Write-Log ('# self: cpu={0:N2}% of total, ws={1:N0}MB' -f (100 * ($cpu - $script:selfCpu0) / ($now - $script:selfT0) / $ncpu), ($script:selfProc.WorkingSet64 / 1MB))
        $script:selfCpu0 = $cpu; $script:selfT0 = $now; $script:lastSelf = $now
    }
    if ($now - $script:lastHouse -ge 3600) { Remove-OldFiles; $script:lastHouse = $now }
}

Remove-OldFiles
Start-WprTrace
Write-Log ('# FreezeWatch started {0:yyyy-MM-dd HH:mm:ss}  admin={1} trace={2} tray={3} stall>{4}s irq>={5}%x{6}s' -f (Get-Date), $isAdmin, $Trace, (-not $NoTray), $StallSec, $IrqPct, $IrqSustainSec)
Write-Host "FreezeWatch running. Logs: $OutDir"

[void](Read-Procs); [void](Read-Gpu)
$script:selfCpu0 = $script:selfProc.TotalProcessorTime.TotalSeconds
$script:prev = $script:sw.Elapsed.TotalSeconds
$script:selfT0 = $script:prev; $script:lastSelf = $script:prev; $script:lastHouse = $script:prev

try {
    if (-not $NoTray) {
        Initialize-Tray
        $timer = New-Object System.Windows.Forms.Timer
        $timer.Interval = 1000
        $timer.Add_Tick({
            try { Invoke-Tick } catch { try { Write-Log ('# ERROR in tick: ' + $_.Exception.Message) } catch {} }
        })
        $timer.Start()
        [GC]::Collect()
        [System.Windows.Forms.Application]::Run($script:ctx)
        $timer.Stop()
    } else {
        while (-not $script:stop) {
            [Threading.Thread]::Sleep(1000)
            Invoke-Tick
        }
    }
} finally {
    if ($script:inc) { try { Close-Incident } catch {} }
    if ($script:ni) { $script:ni.Visible = $false; $script:ni.Dispose() }
    if ($Trace) { try { & wpr.exe -cancel 2>&1 | Out-Null } catch {} }
    if ($script:logWriter) { $script:logWriter.Dispose() }
    $mutex.ReleaseMutex()
}