# FreezeWatch

Lightweight background watcher for Windows that catches whole-system freezes and "System Interrupts" CPU spikes, and records what was happening around them. Single PowerShell 5.1 script, no dependencies, no admin needed in the default mode. Measured overhead: about 0.2% of total CPU and about 100 MB of memory.

## Files

- `FreezeWatch.ps1`: the watcher (tray icon, logging, incident detection).
- `New-FreezeWatchReport.ps1`: builds a self-contained HTML report (charts and an incident table) on demand.
- `Install-FreezeWatch.ps1`: copies the scripts to `%USERPROFILE%\FreezeWatch\app`, registers a per-user Task Scheduler task that starts the watcher at logon, and starts it. `-Uninstall` removes the task and the scripts (logs are kept).
- `Capture-DriverTrace.ps1`, `DriverLatency.wprp`, `Get-DpcSummary.ps1`: on-demand admin capture that names the driver behind a freeze (see below). Run from this folder; the installer does not copy them.

## Install and run

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\Install-FreezeWatch.ps1
```

Look for a green dot in the system tray (it may be under the `^` overflow arrow). Right-click it for: open report (last 24 h), open latest incident, open log folder, mark all seen, exit. Double-click opens the report. When an incident is detected the dot turns red and a notification appears.

To try it without installing: `powershell -NoProfile -ExecutionPolicy Bypass -File .\FreezeWatch.ps1` (add `-NoTray` for a console-only run).

All output goes to `%USERPROFILE%\FreezeWatch\`:
- `samples-YYYYMMDD.log`: one line per second (interrupt %, DPC %, interrupts/s, DPC/s, GPU 3D / VideoDecode / Copy), plus a snapshot every 5 s (top CPU processes, GPU engine use and which process owns it).
- `incidents\incident-*.txt`: written when something is detected. Contains the ~2 minutes before, 20 s after, and matching System/Application event-log entries.
- `report.html`: the last generated report.

## What counts as an incident

- stall: its own 1 s loop took longer than 2.5 s (`-StallSec`). The whole machine was frozen, or at least this process was. There is no upper limit: a gap is ignored (logged as `RESUME-GAP`) only when the system was asleep or hibernating for part of it.
- irqstorm: interrupt % + DPC % at or above 15 (`-IrqPct`) for 3 s (`-IrqSustainSec`).

## Overhead

Reads Windows performance counters in bulk (a snapshot takes about 20 ms) and is driven by a single 1 s timer. Log files are about 8 MB per day and are pruned after 7 days (`-KeepDays`). The report generator runs only on demand, at BelowNormal priority.

## Naming the driver (admin)

From an elevated PowerShell (Run as administrator), first check that capture works (about 10 s of recording):

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File F:\Workspace\FreezeWatch\Capture-DriverTrace.ps1 -SelfTest
```

Then run it without `-SelfTest` and leave the window open until the next freeze. It records DPC, interrupt and driver-load events into a 512 MB circular memory buffer. When interrupt + DPC time reaches 15% for 3 s, or its own loop stalls for more than 2.5 s, it waits 5 s, saves the buffer to `%USERPROFILE%\FreezeWatch\traces\trace-*.etl` and writes a `-dpc.txt` summary beside it. It takes up to 3 captures, one per episode (re-arms after 30 quiet seconds), and runs alongside the watcher. Stop it with Ctrl+C; if the window is closed instead, run `wpr -cancel` from an elevated prompt.

In the summary, the driver to look at is the one with a high `Worst 1s %` (100 means one CPU core fully busy). To summarize an existing trace again: `.\Get-DpcSummary.ps1 -Path <file.etl>` (no admin needed).

Limits: `-SelfTest` has passed on a real kernel trace. The storm and freeze triggers have only been tested with a stand-in for `wpr`. Traces contain process and driver names; do not share them without review.

## Older option: watcher `-Trace` (admin, heavy, untested)

Prefer the capture script above. From the code, saving a trace from inside the watcher's loop could itself register as a stall.

```powershell
# from an elevated PowerShell
.\FreezeWatch.ps1 -Trace
```

Keeps a circular Windows Performance Recorder "Video" trace in memory (it includes DPC, interrupt and driver-load events) and saves `trace-*.etl` next to each incident. Open it in Windows Performance Analyzer and look at DPC/ISR by module to see which driver was busy. Uses a large memory buffer and extra CPU. Only the 3 newest traces are kept. This path has not been run yet.

## How to read an incident

1. Look at the `int=` and `dpc=` columns in the rows before the freeze: a climb means a driver was already misbehaving.
2. Check `# SNAP gpu-top`: if a browser process holds `VideoDecode`, the video decode path is involved.
3. Check the event-log section for display driver, WHEA or Kernel-Power entries at the same time.
4. Counters in the `STALL` row are averaged over the whole gap.

## Limits

- A hard freeze stops this process too, so it sees the freeze afterwards, not during. The pre-freeze rows and post-freeze snapshot are the evidence.
- If the machine never recovers and has to be reset, no incident file is written. The last rows of that day's sample log are the only record.
- Without `-Trace` it cannot name the driver. It narrows the cause (interrupt vs DPC, GPU engine, process); the trace names the module.
- Per-process GPU attribution has only been exercised with an idle GPU.

## Gotcha: packaged apps and AppData

If you run the installer from a packaged app's shell (for example the Claude desktop app), writes under `AppData` are silently redirected into that app's private folder, and other programs (a browser, Explorer) cannot see them. That is why data lives under the profile root and not `%LOCALAPPDATA%`.

## Privacy

Logs and incident files contain process names, paths and event-log text from the machine they ran on. They are gitignored and should not be committed or shared without review.
