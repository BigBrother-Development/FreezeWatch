<#
New-FreezeWatchReport.ps1 - builds a self-contained HTML report from FreezeWatch logs.
Runs only on demand, at BelowNormal priority, and exits. No external libraries or network access.
#>
[CmdletBinding()]
param(
    [string]$LogDir = (Join-Path $env:USERPROFILE 'FreezeWatch'),
    [int]$Hours = 24,
    [string]$OutFile,
    [switch]$Open
)
$ErrorActionPreference = 'Stop'
try { (Get-Process -Id $PID).PriorityClass = 'BelowNormal' } catch {}
if (-not $OutFile) { $OutFile = Join-Path $LogDir 'report.html' }
$enc = { param($s) [System.Net.WebUtility]::HtmlEncode([string]$s) }
$inv = [Globalization.CultureInfo]::InvariantCulture

$to = Get-Date
$from = $to.AddHours(-$Hours)
$bins = [int][Math]::Ceiling(($to - $from).TotalMinutes) + 1
$irq = New-Object 'double[]' $bins
$gap = New-Object 'double[]' $bins
$vdec = New-Object 'double[]' $bins
$have = New-Object 'bool[]' $bins

# ---------- parse sample logs ----------
$rowRx = [regex]'^(\d\d):(\d\d):(\d\d)\.\d dt=\s*([\d,]+)ms int=\s*([\d.]+)% dpc=\s*([\d.]+)% irq/s=\s*[\d,]+ dpc/s=\s*[\d,]+ gpu3d=\s*(\d+) vdec=\s*(\d+) copy=\s*(\d+)'
$selfRx = [regex]'^# self: cpu=([\d.]+)% of total, ws=(\d+)MB'
$samples = 0; $maxIrq = 0.0; $maxGap = 0.0
$selfCpu = New-Object System.Collections.Generic.List[double]; $selfWs = 0
$files = Get-ChildItem $LogDir -Filter 'samples-*.log' -ErrorAction SilentlyContinue | Sort-Object Name
foreach ($f in $files) {
    if ($f.Name -notmatch 'samples-(\d{4})(\d\d)(\d\d)\.log') { continue }
    $day = Get-Date -Year $matches[1] -Month $matches[2] -Day $matches[3] -Hour 0 -Minute 0 -Second 0 -Millisecond 0
    if ($day.AddDays(1) -lt $from -or $day -gt $to) { continue }
    $fs = New-Object IO.FileStream($f.FullName, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
    $sr = New-Object IO.StreamReader($fs)
    try {
        while ($null -ne ($line = $sr.ReadLine())) {
            $m = $rowRx.Match($line)
            if ($m.Success) {
                $g = $m.Groups
                $ts = $day.AddHours([int]$g[1].Value).AddMinutes([int]$g[2].Value).AddSeconds([int]$g[3].Value)
                if ($ts -lt $from -or $ts -gt $to) { continue }
                $b = [int](($ts - $from).TotalMinutes)
                $dt = [double]::Parse(($g[4].Value -replace ',', ''), $inv)
                $v = [double]::Parse($g[5].Value, $inv) + [double]::Parse($g[6].Value, $inv)
                $vd = [double]$g[8].Value
                if ($v -gt $irq[$b]) { $irq[$b] = $v }
                if ($dt -gt $gap[$b]) { $gap[$b] = $dt }
                if ($vd -gt $vdec[$b]) { $vdec[$b] = $vd }
                $have[$b] = $true; $samples++
                if ($v -gt $maxIrq) { $maxIrq = $v }
                if ($dt -gt $maxGap) { $maxGap = $dt }
            } else {
                $s = $selfRx.Match($line)
                if ($s.Success) { $selfCpu.Add([double]::Parse($s.Groups[1].Value, $inv)); $selfWs = [int]$s.Groups[2].Value }
            }
        }
    } finally { $sr.Dispose() }
}

# ---------- parse incidents ----------
$incidents = @()
$incDir = Join-Path $LogDir 'incidents'
foreach ($f in (Get-ChildItem $incDir -Filter 'incident-*.txt' -ErrorAction SilentlyContinue | Sort-Object Name)) {
    if ($f.Name -notmatch 'incident-(\d{8})-(\d{6})-(\w+)\.txt') { continue }
    $when = [datetime]::ParseExact($matches[1] + $matches[2], 'yyyyMMddHHmmss', $inv)
    $kind = $matches[3]
    if ($when -lt $from) { continue }
    $text = [IO.File]::ReadAllText($f.FullName)
    $lines = $text -split "\r?\n"
    $detail = ($lines | Where-Object { $_ -like 'Detail:*' } | Select-Object -First 1) -replace '^Detail:\s*', ''
    $split = [Array]::IndexOf($lines, '--- after detection ---')
    $before = if ($split -gt 0) { $lines[0..($split - 1)] } else { @() }
    $after = if ($split -gt 0) { $lines[$split..($lines.Count - 1)] } else { @() }
    $pre = 0.0; $preVdec = 0; $preGpu3d = 0
    foreach ($l in $before) {
        $m = $rowRx.Match($l)
        if ($m.Success) {
            $v = [double]::Parse($m.Groups[5].Value, $inv) + [double]::Parse($m.Groups[6].Value, $inv)
            if ($v -gt $pre) { $pre = $v }
            if ([int]$m.Groups[8].Value -gt $preVdec) { $preVdec = [int]$m.Groups[8].Value }
            if ([int]$m.Groups[7].Value -gt $preGpu3d) { $preGpu3d = [int]$m.Groups[7].Value }
        }
    }
    $snapAfter = $after | Where-Object { $_ -like '# SNAP*' } | Select-Object -First 1
    $cpuTop = if ($snapAfter -match 'cpu-top: ([^|]*)\|') { $matches[1].Trim() } else { '' }
    $gpuTop = if ($snapAfter -match 'gpu-top: (.*?)(\(snapshot|$)') { $matches[1].Trim() } else { '' }
    $evCount = @($lines | Where-Object { $_ -match '^(SYSTEM|APP)   ' }).Count
    $notes = New-Object System.Collections.Generic.List[string]
    if ($pre -ge 5) { $notes.Add(('Interrupt+DPC load was already elevated before detection (peak {0:N1}%): points at a driver.' -f $pre)) }
    if ($preVdec -gt 0 -or $gpuTop -match 'VideoDecode') { $notes.Add('GPU video decode was active around this time.') }
    if ($evCount -gt 0) { $notes.Add("$evCount related event-log entries recorded (expand to read).") }
    if ($notes.Count -eq 0) { $notes.Add('No clear signal in the counters. A hard freeze stops the watcher too, so check the event-log section and the rows right after.') }
    $incidents += [pscustomobject]@{ When = $when; Kind = $kind; Detail = $detail; Pre = $pre; CpuTop = $cpuTop; GpuTop = $gpuTop; Notes = $notes; Text = $text; Name = $f.Name }
}

# ---------- charts (inline SVG) ----------
function New-Chart([string]$title, [string]$unit, [double[]]$series, [double]$thresh, [double]$minMax, [string]$cls) {
    $W = 1100; $H = 170; $ml = 46; $mr = 10; $mt = 8; $mb = 22
    $pw = $W - $ml - $mr; $ph = $H - $mt - $mb
    $dmax = ($series | Measure-Object -Maximum).Maximum
    $ymax = [Math]::Max([Math]::Max($dmax, $minMax), $(if ($thresh -gt 0) { $thresh * 1.15 } else { 0 }))
    $mag = [Math]::Pow(10, [Math]::Floor([Math]::Log10($ymax)))
    $ymax = [Math]::Ceiling($ymax / $mag * 2) / 2 * $mag
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append("<svg viewBox=`"0 0 $W $H`" class=`"chart`" role=`"img`" aria-label=`"$(& $enc $title)`">")
    foreach ($fr in 0, 0.5, 1) {
        $y = $mt + $ph * (1 - $fr)
        [void]$sb.Append(("<line x1=`"{0}`" x2=`"{1}`" y1=`"{2:N1}`" y2=`"{2:N1}`" class=`"grid`"/><text x=`"{3}`" y=`"{4:N1}`" class=`"axis`" text-anchor=`"end`">{5:0.##}</text>" -f $ml, ($W - $mr), $y, ($ml - 6), ($y + 4), ($ymax * $fr)))
    }
    $stepH = if ($Hours -le 6) { 1 } elseif ($Hours -le 24) { 3 } elseif ($Hours -le 72) { 12 } else { 24 }
    $t = $from.Date.AddHours([Math]::Ceiling($from.Hour / $stepH) * $stepH)
    while ($t -le $to) {
        if ($t -ge $from) {
            $x = $ml + $pw * (($t - $from).TotalMinutes / ($bins - 1))
            $lbl = if ($Hours -gt 24) { $t.ToString('MM-dd HH:mm') } else { $t.ToString('HH:mm') }
            [void]$sb.Append(("<text x=`"{0:N1}`" y=`"{1}`" class=`"axis`" text-anchor=`"middle`">{2}</text>" -f $x, ($H - 6), $lbl))
        }
        $t = $t.AddHours($stepH)
    }
    if ($thresh -gt 0) {
        $y = $mt + $ph * (1 - $thresh / $ymax)
        [void]$sb.Append(("<line x1=`"{0}`" x2=`"{1}`" y1=`"{2:N1}`" y2=`"{2:N1}`" class=`"thr`"/>" -f $ml, ($W - $mr), $y))
    }
    $path = New-Object System.Text.StringBuilder
    $pen = $false
    for ($i = 0; $i -lt $bins; $i++) {
        if (-not $have[$i]) { $pen = $false; continue }
        $x = $ml + $pw * ($i / ($bins - 1)); $y = $mt + $ph * (1 - [Math]::Min($series[$i], $ymax) / $ymax)
        [void]$path.Append($(if ($pen) { 'L' } else { 'M' })); [void]$path.Append(('{0:N1},{1:N1} ' -f $x, $y)); $pen = $true
    }
    [void]$sb.Append("<path d=`"$($path.ToString())`" class=`"line $cls`"/>")
    foreach ($inc in $incidents) {
        $x = $ml + $pw * (($inc.When - $from).TotalMinutes / ($bins - 1))
        [void]$sb.Append(("<line x1=`"{0:N1}`" x2=`"{0:N1}`" y1=`"{1}`" y2=`"{2}`" class=`"mark`"/>" -f $x, $mt, ($mt + $ph)))
    }
    [void]$sb.Append('</svg>')
    "<section><h2>$(& $enc $title) <span class=`"unit`">$unit, peak per minute</span></h2>$($sb.ToString())</section>"
}

$chart1 = New-Chart 'Interrupt + DPC time' '% of CPU' $irq 15 5 'c1'
$chart2 = New-Chart 'Watcher loop gap (freeze indicator)' 'ms, normal is about 1000' $gap 2500 3000 'c2'
$chart3 = New-Chart 'GPU video decode engine' '% busy' $vdec 0 100 'c3'

# ---------- HTML ----------
$sb = New-Object System.Text.StringBuilder
$stallN = @($incidents | Where-Object Kind -eq 'stall').Count
$stormN = @($incidents | Where-Object Kind -eq 'irqstorm').Count
$avgSelf = if ($selfCpu.Count -gt 0) { ($selfCpu | Measure-Object -Average).Average } else { $null }
$dataNote = if ($samples -eq 0) { '<p class="warn">No samples found in this window. Is FreezeWatch running?</p>' } else { '' }

[void]$sb.Append(@"
<!DOCTYPE html><html lang="en"><head><meta charset="utf-8"><title>FreezeWatch report</title>
<meta name="viewport" content="width=device-width,initial-scale=1">
<style>
:root{--bg:#fff;--fg:#1d2330;--mut:#667085;--card:#f6f7f9;--bd:#e3e6eb;--c1:#2563eb;--c2:#d97706;--c3:#0f9d58;--bad:#dc2626}
@media (prefers-color-scheme:dark){:root{--bg:#14171c;--fg:#e6e9ef;--mut:#9aa3b2;--card:#1c2027;--bd:#2c323c;--c1:#6ea0ff;--c2:#f0a63a;--c3:#4cc38a;--bad:#ff6b6b}}
body{margin:0;padding:24px;background:var(--bg);color:var(--fg);font:14px/1.5 system-ui,Segoe UI,sans-serif}
main{max-width:1150px;margin:0 auto}h1{font-size:22px;margin:0 0 4px}h2{font-size:15px;margin:22px 0 6px}
.sub{color:var(--mut);margin:0 0 16px}.unit{color:var(--mut);font-weight:400;font-size:12px}
.cards{display:flex;flex-wrap:wrap;gap:10px;margin:12px 0}.card{background:var(--card);border:1px solid var(--bd);border-radius:8px;padding:10px 14px;min-width:140px}
.card b{display:block;font-size:20px}.card span{color:var(--mut);font-size:12px}
.chart{width:100%;height:auto;background:var(--card);border:1px solid var(--bd);border-radius:8px}
.grid{stroke:var(--bd);stroke-width:1}.axis{fill:var(--mut);font-size:10px}.thr{stroke:var(--mut);stroke-dasharray:4 4}
.line{fill:none;stroke-width:1.4;stroke-linejoin:round}.c1{stroke:var(--c1)}.c2{stroke:var(--c2)}.c3{stroke:var(--c3)}
.mark{stroke:var(--bad);stroke-width:1.5;opacity:.8}
table{border-collapse:collapse;width:100%}th,td{text-align:left;padding:6px 8px;border-bottom:1px solid var(--bd);vertical-align:top}th{color:var(--mut);font-weight:500;font-size:12px}
.k-stall{color:var(--bad);font-weight:600}.k-irqstorm{color:var(--c2);font-weight:600}
details{margin:4px 0}summary{cursor:pointer;color:var(--c1)}pre{background:var(--card);border:1px solid var(--bd);border-radius:6px;padding:10px;overflow:auto;font-size:12px;max-height:420px}
.warn{background:var(--card);border-left:3px solid var(--c2);padding:8px 12px}.note{color:var(--mut);font-size:12px}ul{margin:4px 0;padding-left:18px}
</style></head><body><main>
<h1>FreezeWatch report</h1>
<p class="sub">$($from.ToString('yyyy-MM-dd HH:mm')) to $($to.ToString('yyyy-MM-dd HH:mm')) ($Hours h). Generated $($to.ToString('yyyy-MM-dd HH:mm:ss')).</p>
$dataNote
<div class="cards">
<div class="card"><b>$($incidents.Count)</b><span>incidents ($stallN stall, $stormN irq storm)</span></div>
<div class="card"><b>$('{0:N1}' -f $maxIrq)%</b><span>peak interrupt + DPC</span></div>
<div class="card"><b>$('{0:N1}' -f ($maxGap / 1000)) s</b><span>longest loop gap</span></div>
<div class="card"><b>$samples</b><span>seconds sampled</span></div>
<div class="card"><b>$(if ($null -ne $avgSelf) { '{0:N2}%' -f $avgSelf } else { 'n/a' })</b><span>watcher CPU (avg of total)$(if ($selfWs) { ", $selfWs MB" })</span></div>
</div>
$chart1
$chart2
$chart3
<p class="note">Red vertical lines mark incidents. Dashed lines mark the detection thresholds. Gaps in a line mean the watcher was not running.</p>
<h2>Incidents</h2>
"@)

if ($incidents.Count -eq 0) {
    [void]$sb.Append('<p>No incidents recorded in this window.</p>')
} else {
    [void]$sb.Append('<table><tr><th>Time</th><th>Type</th><th>What was seen</th><th>Top CPU after</th><th>Top GPU after</th></tr>')
    foreach ($i in ($incidents | Sort-Object When -Descending)) {
        $notesHtml = ($i.Notes | ForEach-Object { '<li>' + (& $enc $_) + '</li>' }) -join ''
        [void]$sb.Append(("<tr><td>{0}</td><td class=`"k-{1}`">{1}</td><td>{2}<ul>{3}</ul><details><summary>Full incident file</summary><pre>{4}</pre></details></td><td>{5}</td><td>{6}</td></tr>" -f `
            $i.When.ToString('MM-dd HH:mm:ss'), $i.Kind, (& $enc $i.Detail), $notesHtml, (& $enc $i.Text), (& $enc $i.CpuTop), (& $enc $i.GpuTop)))
    }
    [void]$sb.Append('</table>')
}
[void]$sb.Append('</main></body></html>')

[IO.File]::WriteAllText($OutFile, $sb.ToString(), (New-Object System.Text.UTF8Encoding($false)))
Write-Host "Report written: $OutFile"
if ($Open) { Start-Process $OutFile }
