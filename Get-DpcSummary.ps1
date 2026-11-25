<#
Get-DpcSummary.ps1 - reads a kernel .etl trace and reports DPC and interrupt (ISR) time per driver.
Writes <trace>-dpc.txt next to the trace. No admin and no Windows Performance Toolkit needed.

Event layouts follow the documented PerfInfo DPC / ISR and Image_Load event classes.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Path,
    [int]$Top = 15
)
$ErrorActionPreference = 'Stop'
if ([IntPtr]::Size -ne 8) { throw 'Run this from 64-bit PowerShell.' }
$Path = (Resolve-Path -LiteralPath $Path).ProviderPath

if (-not ('FreezeWatch.DpcReader' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;

namespace FreezeWatch {
    public class RoutineStat {
        public ulong Routine; public bool IsIsr; public long Count; public long Ticks; public long MaxTicks;
        public Dictionary<long, long> PerSecond = new Dictionary<long, long>();
        public Dictionary<int, long> PerCpu = new Dictionary<int, long>();
    }
    public class ImageInfo { public ulong Base; public ulong Size; public string Name; }

    public class DpcReader {
        [DllImport("advapi32.dll", SetLastError = true)] static extern ulong OpenTraceW(IntPtr logfile);
        [DllImport("advapi32.dll")] static extern uint ProcessTrace(ulong[] handles, uint count, IntPtr start, IntPtr end);
        [DllImport("advapi32.dll")] static extern uint CloseTrace(ulong handle);
        [UnmanagedFunctionPointer(CallingConvention.Winapi)] delegate void RecordCallback(IntPtr record);

        static readonly Guid PerfInfo = new Guid("ce1dbfb4-137e-4da6-87b0-3f59aa102cbc");
        static readonly Guid ImageGuid = new Guid("2cb15d1d-5fc1-11d2-abe1-00a0c911f518");

        public Dictionary<string, RoutineStat> Routines = new Dictionary<string, RoutineStat>();
        public Dictionary<ulong, ImageInfo> Images = new Dictionary<ulong, ImageInfo>();
        public long Events, DpcEvents, IsrEvents, Errors, FirstTime, LastTime;
        public double TicksPerSecond;
        public int Processors;
        public uint ProcessResult;
        byte[] guidBytes = new byte[16];

        public void Read(string path) {
            // EVENT_TRACE_LOGFILEW, 64-bit layout (448 bytes)
            IntPtr log = Marshal.AllocHGlobal(448);
            IntPtr name = Marshal.StringToHGlobalUni(path);
            RecordCallback callback = new RecordCallback(OnEvent);
            try {
                for (int i = 0; i < 448; i += 8) Marshal.WriteInt64(log, i, 0);
                Marshal.WriteIntPtr(log, 0, name);
                Marshal.WriteInt32(log, 28, 0x10000000 | 0x00001000);   // EVENT_RECORD callback, raw timestamps
                Marshal.WriteIntPtr(log, 424, Marshal.GetFunctionPointerForDelegate(callback));
                ulong handle = OpenTraceW(log);
                if (handle == ulong.MaxValue) throw new Exception("OpenTrace failed, error " + Marshal.GetLastWin32Error());
                // TRACE_LOGFILE_HEADER starts at offset 120
                Processors = Marshal.ReadInt32(log, 132);
                int clock = Marshal.ReadInt32(log, 392);                 // 1 QPC, 2 system time, 3 CPU cycles
                if (clock == 2) TicksPerSecond = 1e7;
                else if (clock == 3) TicksPerSecond = Marshal.ReadInt32(log, 172) * 1e6;
                else TicksPerSecond = Marshal.ReadInt64(log, 376);
                if (TicksPerSecond <= 0) throw new Exception("trace header has no clock frequency");
                try { ProcessResult = ProcessTrace(new ulong[] { handle }, 1, IntPtr.Zero, IntPtr.Zero); }
                finally { CloseTrace(handle); }
            } finally {
                GC.KeepAlive(callback);
                Marshal.FreeHGlobal(log);
                Marshal.FreeHGlobal(name);
            }
        }

        void OnEvent(IntPtr rec) {
            try {
                Events++;
                Marshal.Copy(IntPtr.Add(rec, 24), guidBytes, 0, 16);
                Guid provider = new Guid(guidBytes);
                bool perf = provider == PerfInfo, image = provider == ImageGuid;
                if (!perf && !image) return;
                int flags = (ushort)Marshal.ReadInt16(rec, 4);
                int ptr = (flags & 0x40) != 0 ? 8 : 4;
                int opcode = Marshal.ReadByte(rec, 45);
                int length = (ushort)Marshal.ReadInt16(rec, 86);
                IntPtr data = Marshal.ReadIntPtr(rec, 96);

                if (image) {
                    if (opcode != 10 && opcode != 3 && opcode != 4) return;   // Load, DCStart, DCEnd
                    int nameOffset = 3 * ptr + 32;
                    if (length <= nameOffset) return;
                    ulong b = ReadPointer(data, 0, ptr);
                    if (b < (ptr == 8 ? 0xFFFF000000000000UL : 0x80000000UL)) return;   // kernel images only
                    ImageInfo info = new ImageInfo();
                    info.Base = b; info.Size = ReadPointer(data, ptr, ptr);
                    info.Name = Marshal.PtrToStringUni(IntPtr.Add(data, nameOffset), (length - nameOffset) / 2).TrimEnd('\0');
                    Images[b] = info;
                    return;
                }

                bool isr = opcode == 67;
                if (!isr && opcode != 66 && opcode != 68 && opcode != 69) return;
                if (length < 8 + ptr) return;
                long end = Marshal.ReadInt64(rec, 16);
                long start = Marshal.ReadInt64(data, 0);
                ulong routine = ReadPointer(data, 8, ptr);
                long ticks = end - start;
                if (ticks < 0) { Errors++; return; }
                if (FirstTime == 0) FirstTime = start;
                if (end > LastTime) LastTime = end;
                if (isr) IsrEvents++; else DpcEvents++;
                int cpu = (flags & 0x200) != 0 ? (ushort)Marshal.ReadInt16(rec, 80) : Marshal.ReadByte(rec, 80);

                string key = (isr ? "I" : "D") + routine.ToString("X");
                RoutineStat s;
                if (!Routines.TryGetValue(key, out s)) { s = new RoutineStat(); s.Routine = routine; s.IsIsr = isr; Routines[key] = s; }
                s.Count++; s.Ticks += ticks; if (ticks > s.MaxTicks) s.MaxTicks = ticks;
                long second = (long)((end - FirstTime) / TicksPerSecond), v;
                s.PerSecond.TryGetValue(second, out v); s.PerSecond[second] = v + ticks;
                s.PerCpu.TryGetValue(cpu, out v); s.PerCpu[cpu] = v + ticks;
            } catch { Errors++; }
        }

        // file name of the loaded image that contains the address (done here: PowerShell loses precision on 64-bit addresses)
        public string ModuleFor(ulong address) {
            foreach (ImageInfo i in Images.Values)
                if (address >= i.Base && address - i.Base < i.Size) return System.IO.Path.GetFileName(i.Name);
            return "(unresolved)";
        }

        static ulong ReadPointer(IntPtr data, int offset, int size) {
            return size == 8 ? (ulong)Marshal.ReadInt64(data, offset) : (uint)Marshal.ReadInt32(data, offset);
        }
    }
}
'@
}

$r = New-Object FreezeWatch.DpcReader
$r.Read($Path)

# group routine statistics by the driver image that contains each routine
$groups = @{}
foreach ($s in $r.Routines.Values) {
    $module = $r.ModuleFor($s.Routine)
    $kind = if ($s.IsIsr) { 'ISR' } else { 'DPC' }
    $key = "$module|$kind"
    if (-not $groups.ContainsKey($key)) { $groups[$key] = @{ Module = $module; Kind = $kind; Calls = 0L; Ticks = 0L; Max = 0L; Sec = @{}; Cpu = @{} } }
    $g = $groups[$key]
    $g.Calls += $s.Count; $g.Ticks += $s.Ticks
    if ($s.MaxTicks -gt $g.Max) { $g.Max = $s.MaxTicks }
    foreach ($p in $s.PerSecond.GetEnumerator()) { $g.Sec[$p.Key] += $p.Value }
    foreach ($p in $s.PerCpu.GetEnumerator()) { $g.Cpu[$p.Key] += $p.Value }
}

$span = if ($r.LastTime -gt $r.FirstTime) { ($r.LastTime - $r.FirstTime) / $r.TicksPerSecond } else { 0 }
$rows = foreach ($g in $groups.Values) {
    $worst = ($g.Sec.Values | Measure-Object -Maximum).Maximum
    $cpu = $g.Cpu.GetEnumerator() | Sort-Object Value -Descending | Select-Object -First 1
    [pscustomobject]@{
        Driver         = $g.Module
        Kind           = $g.Kind
        Count          = $g.Calls
        'Total ms'     = [Math]::Round(1000 * $g.Ticks / $r.TicksPerSecond, 1)
        'Worst 1s %'   = [Math]::Round(100 * $worst / $r.TicksPerSecond, 1)
        'Longest ms'   = [Math]::Round(1000 * $g.Max / $r.TicksPerSecond, 3)
        'Main CPU'     = $cpu.Key
    }
}

$head = @(
    "DPC / ISR summary: $Path",
    ('Span: {0:N1} s   CPUs: {1}   DPC events: {2:N0}   ISR events: {3:N0}   drivers listed: {4}   decode errors: {5}' -f $span, $r.Processors, $r.DpcEvents, $r.IsrEvents, $r.Images.Count, $r.Errors),
    "'Worst 1s %' is the share of one CPU that driver used in its busiest second (100 = one core fully busy)."
)
if ($r.DpcEvents + $r.IsrEvents -eq 0) { $head += "No DPC or ISR events found ($($r.Events) events read, result code $($r.ProcessResult))." }
$table = $rows | Sort-Object 'Worst 1s %', 'Total ms' -Descending | Select-Object -First $Top | Format-Table -AutoSize | Out-String -Width 160
$text = ($head -join "`r`n") + "`r`n" + $table
$out = $Path -replace '\.etl$', ''
$out = "$out-dpc.txt"
[IO.File]::WriteAllText($out, $text)
$text
"Saved: $out"
