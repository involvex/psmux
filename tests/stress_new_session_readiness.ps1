# PR #366 verification: stress + performance test for `new-session -d` readiness.
#
# WHAT THE PR CLAIMS (two client-side defects, under concurrent load):
#   1. Readiness race (rc=0): client returns BEFORE the initial window exists,
#      so `list-windows` can be EMPTY immediately after a "successful" new-session.
#   2. Orphan (rc=1): client gives up on a slow-but-healthy server (5s .port poll
#      then a single 100ms connect) and, on a connect miss, DELETES the .port file
#      -- orphaning a live server. Observed 38/6000 under load, every one orphaning.
#
# This test does NOT read code. It launches REAL concurrent new-session -d against
# whatever psmux.exe is given, and tangibly measures:
#   - RACE  : rc=0 but list-windows empty (or window_panes < 1) right after return
#   - ORPHAN: rc!=0 but a TCP-connectable server was left behind for that session
#   - perf  : per-create latency p50/p90/p99, throughput, orphaned process count
#
# Point it at a binary with -PsmuxExe, tune load with -Rounds / -Batch.
param(
    [string]$PsmuxExe = "",
    [int]$Rounds = 30,
    [int]$Batch  = 16,
    [string]$Label = "baseline"
)

$ErrorActionPreference = "Continue"
if (-not $PsmuxExe) { $PsmuxExe = (Get-Command psmux -EA Stop).Source }
if (-not (Test-Path $PsmuxExe)) { Write-Host "FATAL: psmux not found: $PsmuxExe" -ForegroundColor Red; exit 2 }

# Isolate into a throwaway HOME so we never touch the real ~/.psmux and any
# orphaned server is fully contained and countable.
$tmpHome = Join-Path $env:TEMP ("psmux_stress_" + [guid]::NewGuid().ToString("N").Substring(0,8))
New-Item -ItemType Directory -Path $tmpHome -Force | Out-Null
$psmuxDir = Join-Path $tmpHome ".psmux"
New-Item -ItemType Directory -Path $psmuxDir -Force | Out-Null
$env:USERPROFILE = $tmpHome
$env:HOME = $tmpHome

Write-Host ""
Write-Host ("=" * 70) -ForegroundColor Cyan
Write-Host "STRESS new-session -d readiness  [$Label]" -ForegroundColor Cyan
Write-Host "  exe    : $PsmuxExe" -ForegroundColor Gray
Write-Host "  home   : $tmpHome" -ForegroundColor Gray
Write-Host "  rounds : $Rounds  batch: $Batch  (total attempts: $($Rounds*$Batch))" -ForegroundColor Gray
Write-Host ("=" * 70) -ForegroundColor Cyan

$race   = 0      # rc=0 but no window yet
$orphan = 0      # rc!=0 but live server left behind
$rcFail = 0      # rc!=0 total
$ok     = 0      # rc=0 AND window present
$lat    = [System.Collections.Generic.List[double]]::new()
$raceDetails   = [System.Collections.Generic.List[string]]::new()
$orphanDetails = [System.Collections.Generic.List[string]]::new()

function Query-ListWindows([string]$portBase) {
    $portFile = Join-Path $psmuxDir "$portBase.port"
    $keyFile  = Join-Path $psmuxDir "$portBase.key"
    if (-not (Test-Path $portFile)) { return $null }
    try {
        $port = (Get-Content $portFile -Raw).Trim()
        $key  = if (Test-Path $keyFile) { (Get-Content $keyFile -Raw).Trim() } else { "" }
        $tcp = [System.Net.Sockets.TcpClient]::new()
        $iar = $tcp.BeginConnect("127.0.0.1", [int]$port, $null, $null)
        if (-not $iar.AsyncWaitHandle.WaitOne(800)) { $tcp.Close(); return $null }
        $tcp.EndConnect($iar)
        $stream = $tcp.GetStream(); $stream.ReadTimeout = 2000
        $w = [System.IO.StreamWriter]::new($stream); $w.AutoFlush = $true
        $r = [System.IO.StreamReader]::new($stream)
        $w.WriteLine("AUTH $key"); $r.ReadLine() | Out-Null
        $w.WriteLine("list-windows")
        $sb = [System.Text.StringBuilder]::new()
        try { while ($null -ne ($l = $r.ReadLine())) { [void]$sb.AppendLine($l) } } catch {}
        $tcp.Close()
        return $sb.ToString().Trim()
    } catch { return $null }
}

function Test-ServerAlive([string]$portBase) {
    $portFile = Join-Path $psmuxDir "$portBase.port"
    if (-not (Test-Path $portFile)) { return $false }
    try {
        $port = (Get-Content $portFile -Raw).Trim()
        $tcp = [System.Net.Sockets.TcpClient]::new()
        $iar = $tcp.BeginConnect("127.0.0.1", [int]$port, $null, $null)
        if (-not $iar.AsyncWaitHandle.WaitOne(800)) { $tcp.Close(); return $false }
        $tcp.EndConnect($iar); $tcp.Close(); return $true
    } catch { return $false }
}

$swAll = [System.Diagnostics.Stopwatch]::StartNew()
for ($round = 0; $round -lt $Rounds; $round++) {
    $procs = @()
    for ($b = 0; $b -lt $Batch; $b++) {
        $sname = "s_{0}_{1}" -f $round, $b
        # Use -L namespace == session name so discovery files are deterministic.
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        $p = Start-Process -FilePath $PsmuxExe `
                -ArgumentList @("-L", $sname, "new-session", "-d", "-s", $sname) `
                -PassThru -WindowStyle Hidden
        # With `-L ns -s session` the discovery files are named ns__session.*
        $procs += [pscustomobject]@{ Name=$sname; Proc=$p; Sw=$sw; PortBase="${sname}__${sname}" }
    }

    foreach ($e in $procs) {
        if (-not $e.Proc.WaitForExit(30000)) {
            try { $e.Proc.Kill() } catch {}
            $rcFail++; $orphanDetails.Add("$($e.Name): client HUNG >30s") | Out-Null
            continue
        }
        $e.Sw.Stop()
        [void]$lat.Add($e.Sw.Elapsed.TotalMilliseconds)
        $rc = $e.Proc.ExitCode
        if ($rc -eq 0) {
            # rc=0 contract: a window MUST already exist. Check immediately.
            $lw = Query-ListWindows $e.PortBase
            if ([string]::IsNullOrWhiteSpace($lw)) {
                $race++
                $raceDetails.Add("$($e.Name): rc=0 but list-windows empty/'$lw'") | Out-Null
            } else {
                $ok++
            }
        } else {
            $rcFail++
            # Orphan check: rc!=0 should mean NO live server. If one answers, orphan.
            if (Test-ServerAlive $e.PortBase) {
                $orphan++
                $orphanDetails.Add("$($e.Name): rc=$rc but server ALIVE (orphan)") | Out-Null
            }
        }
    }

    # Teardown this round's sessions to keep the machine sane. Each -L namespace
    # has its own server, so kill the whole server per namespace.
    foreach ($e in $procs) {
        & $PsmuxExe -L $e.Name kill-server 2>&1 | Out-Null
    }
    Write-Host ("  round {0,2}/{1}: ok={2} race={3} rcFail={4} orphan={5}" -f ($round+1), $Rounds, $ok, $race, $rcFail, $orphan) -ForegroundColor DarkGray
}
$swAll.Stop()

# Final sweep: any psmux server processes still alive under our isolated home?
Start-Sleep -Milliseconds 500
& $PsmuxExe kill-server 2>&1 | Out-Null
$leftoverPorts = @(Get-ChildItem -Path $psmuxDir -Filter "*.port" -EA SilentlyContinue)
$leftoverAlive = 0
foreach ($pf in $leftoverPorts) {
    $base = $pf.BaseName
    if (Test-ServerAlive $base) { $leftoverAlive++ }
}

function Pct($arr, $p) {
    if ($arr.Count -eq 0) { return 0 }
    $s = [double[]]($arr | Sort-Object)
    $idx = [Math]::Floor(($p/100.0) * ($s.Count - 1))
    return [Math]::Round($s[$idx], 1)
}

$total = $Rounds * $Batch
Write-Host ""
Write-Host ("=" * 70) -ForegroundColor Cyan
Write-Host "RESULTS [$Label]" -ForegroundColor Cyan
Write-Host ("  total attempts      : {0}" -f $total)
Write-Host ("  rc=0 + window ok    : {0}" -f $ok) -ForegroundColor Green
Write-Host ("  READINESS RACE      : {0}  (rc=0 but empty list-windows)" -f $race) -ForegroundColor $(if ($race -gt 0) {"Red"} else {"Green"})
Write-Host ("  rc!=0 failures      : {0}" -f $rcFail) -ForegroundColor $(if ($rcFail -gt 0) {"Yellow"} else {"Green"})
Write-Host ("  ORPHANED SERVERS    : {0}  (rc!=0 but server alive)" -f $orphan) -ForegroundColor $(if ($orphan -gt 0) {"Red"} else {"Green"})
Write-Host ("  leftover live srv   : {0}" -f $leftoverAlive) -ForegroundColor $(if ($leftoverAlive -gt 0) {"Red"} else {"Green"})
Write-Host ""
Write-Host "  PERFORMANCE (per new-session -d, ms):" -ForegroundColor Cyan
Write-Host ("    p50={0} p90={1} p99={2} max={3}" -f (Pct $lat 50), (Pct $lat 90), (Pct $lat 99), (Pct $lat 100))
Write-Host ("    wall={0:N1}s  throughput={1:N1} sessions/s" -f $swAll.Elapsed.TotalSeconds, ($total / $swAll.Elapsed.TotalSeconds))
Write-Host ("=" * 70) -ForegroundColor Cyan

if ($raceDetails.Count -gt 0) {
    Write-Host "`nRACE samples (first 10):" -ForegroundColor Red
    $raceDetails | Select-Object -First 10 | ForEach-Object { Write-Host "    $_" -ForegroundColor Red }
}
if ($orphanDetails.Count -gt 0) {
    Write-Host "`nORPHAN samples (first 10):" -ForegroundColor Red
    $orphanDetails | Select-Object -First 10 | ForEach-Object { Write-Host "    $_" -ForegroundColor Red }
}

# Cleanup isolated home.
& $PsmuxExe kill-server 2>&1 | Out-Null
Get-Process psmux -EA SilentlyContinue | Where-Object { $_.Path -eq $PsmuxExe } | Stop-Process -Force -EA SilentlyContinue
Start-Sleep -Milliseconds 300
Remove-Item -Recurse -Force $tmpHome -EA SilentlyContinue

$defects = $race + $orphan + $leftoverAlive
Write-Host "`nDEFECTS DETECTED: $defects  (race=$race orphan=$orphan leftover=$leftoverAlive)" -ForegroundColor $(if ($defects -gt 0) {"Red"} else {"Green"})
exit $defects
