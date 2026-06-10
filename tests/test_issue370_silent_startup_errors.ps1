# Issue #370: Config errors are silently ignored?
# A bad default-shell path (e.g. POSIX-style /c/... which is not a valid Win32
# path) makes the initial pane spawn fail. Before the fix the user only saw a
# generic "failed to create session" (or, attached, psmux flashing and pwsh
# coming back) with the real cause buried in ~/.psmux/server-startup.log.
#
# This test proves the real spawn error is now passed through to the terminal.

$ErrorActionPreference = "Continue"
$PSMUX = (Get-Command psmux -EA Stop).Source
$psmuxDir = "$env:USERPROFILE\.psmux"
# Force the cold startup path so the server we spawn is the one that fails —
# removes warm-server-adoption timing noise from the assertions.
$env:PSMUX_NO_WARM = "1"
$script:TestsPassed = 0
$script:TestsFailed = 0

function Write-Pass($msg) { Write-Host "  [PASS] $msg" -ForegroundColor Green; $script:TestsPassed++ }
function Write-Fail($msg) { Write-Host "  [FAIL] $msg" -ForegroundColor Red; $script:TestsFailed++ }

function Reset-Warm {
    # Force the cold startup path so the server we spawn is the one that fails.
    & $PSMUX kill-session -t __warm__ 2>&1 | Out-Null
    Remove-Item "$psmuxDir\__warm__.*" -Force -EA SilentlyContinue
    Start-Sleep -Milliseconds 500
}

function Test-PortAlive($name) {
    $pf = "$psmuxDir\$name.port"
    if (-not (Test-Path $pf)) { return $false }
    $port = (Get-Content $pf -Raw -EA SilentlyContinue).Trim()
    if ($port -notmatch '^\d+$') { return $false }
    try { $t = [System.Net.Sockets.TcpClient]::new("127.0.0.1", [int]$port); $t.Close(); return $true }
    catch { return $false }
}

function Cleanup($name) {
    & $PSMUX kill-session -t $name 2>&1 | Out-Null
    # Poll until the prior server is truly gone — a stale, still-connectable
    # same-named server makes a fresh new-session see a bogus "ready" server.
    for ($i = 0; $i -lt 40; $i++) {
        if (-not (Test-PortAlive $name)) { break }
        Start-Sleep -Milliseconds 150
    }
    Remove-Item "$psmuxDir\$name.*" -Force -EA SilentlyContinue
    Start-Sleep -Milliseconds 150
}

# Run a detached new-session with a given config and capture exact stdout/stderr/exit.
function Invoke-NewSession {
    param([string]$ConfigContent, [string]$Name)
    $conf = "$env:TEMP\$Name.conf"
    $ConfigContent | Set-Content -Path $conf -Encoding UTF8
    Cleanup $Name
    Reset-Warm
    Remove-Item "$psmuxDir\server-startup.log" -Force -EA SilentlyContinue

    $outFile = "$env:TEMP\$Name.out"
    $errFile = "$env:TEMP\$Name.err"
    $env:PSMUX_CONFIG_FILE = $conf
    $p = Start-Process -FilePath $PSMUX -ArgumentList "new-session","-d","-s",$Name `
        -PassThru -WindowStyle Hidden -RedirectStandardOutput $outFile -RedirectStandardError $errFile
    $p.WaitForExit(30000) | Out-Null
    $env:PSMUX_CONFIG_FILE = $null
    return @{
        Exit   = $p.ExitCode
        Stdout = (Get-Content $outFile -Raw -EA SilentlyContinue)
        Stderr = (Get-Content $errFile -Raw -EA SilentlyContinue)
    }
}

# Initial settle: clear any leftover servers from a prior run so the FIRST
# new-session does not race a still-dying same-named server / stale port file.
& $PSMUX kill-server 2>&1 | Out-Null
foreach ($n in @("iss370bad","iss370miss","iss370good","iss370stale","iss370_tui","__warm__")) {
    & $PSMUX kill-session -t $n 2>&1 | Out-Null
    Remove-Item "$psmuxDir\$n.*" -Force -EA SilentlyContinue
}
Start-Sleep -Seconds 2

Write-Host "`n=== Issue #370: silent startup errors ===" -ForegroundColor Cyan

# --- TEST 1: invalid Win32 path (the reporter's exact case) ---
Write-Host "`n[Test 1] POSIX-style /c/ default-shell path (reporter's case)" -ForegroundColor Yellow
$r1 = Invoke-NewSession 'set-option -g default-shell "/c/Program Files/git/bin/bash.exe"' "iss370bad"
Write-Host "  exit=$($r1.Exit)"
Write-Host "  stderr: $("$($r1.Stderr)".Trim())"
if ($r1.Exit -ne 0) { Write-Pass "Non-zero exit on bad shell" } else { Write-Fail "Expected non-zero exit, got $($r1.Exit)" }
if ($r1.Stderr -match "failed to create session") { Write-Pass "Generic failure line present" } else { Write-Fail "Missing 'failed to create session'" }
if ($r1.Stderr -match "spawn shell error" -or $r1.Stderr -match "cannot find the path") {
    Write-Pass "Real spawn error passed through to terminal (no longer silent)"
} else {
    Write-Fail "Real spawn reason NOT surfaced to terminal (bug still present)"
}
if ($r1.Stderr -match "server-startup\.log") { Write-Pass "Points user at full diagnostics log" } else { Write-Fail "No pointer to diagnostics log" }
if ($r1.Stderr -match "bash\.exe") { Write-Pass "Surfaced the offending path so user can spot the typo" } else { Write-Fail "Offending path not shown" }
Cleanup "iss370bad"

# --- TEST 2: valid-form but non-existent path ---
Write-Host "`n[Test 2] Valid-form but missing path" -ForegroundColor Yellow
$r2 = Invoke-NewSession 'set-option -g default-shell "C:/totally/nonexistent/nope.exe"' "iss370miss"
Write-Host "  exit=$($r2.Exit)"
Write-Host "  stderr: $("$($r2.Stderr)".Trim())"
if ($r2.Exit -ne 0) { Write-Pass "Non-zero exit on missing shell" } else { Write-Fail "Expected non-zero exit" }
if ($r2.Stderr -match "spawn shell error" -or $r2.Stderr -match "cannot find the") {
    Write-Pass "Real spawn error surfaced for missing path"
} else { Write-Fail "Real spawn reason not surfaced" }
if ($r2.Stderr -match "nope\.exe") { Write-Pass "Offending path shown" } else { Write-Fail "Offending path not shown" }
Cleanup "iss370miss"

# --- TEST 3: GOOD path still works (no regression / no false error) ---
Write-Host "`n[Test 3] Valid default-shell still launches cleanly (no false error)" -ForegroundColor Yellow
$goodShell = "C:/Program Files/Git/bin/bash.exe"
if (-not (Test-Path $goodShell)) {
    # Fall back to pwsh if git-bash isn't installed on this machine.
    $goodShell = (Get-Command pwsh -EA SilentlyContinue).Source
    if (-not $goodShell) { $goodShell = (Get-Command powershell).Source }
    $goodShell = $goodShell -replace '\\','/'
}
$r3 = Invoke-NewSession "set-option -g default-shell `"$goodShell`"" "iss370good"
Write-Host "  exit=$($r3.Exit)"
Write-Host "  stderr: $("$($r3.Stderr)".Trim())"
if ($r3.Exit -eq 0) { Write-Pass "Valid shell -> exit 0" } else { Write-Fail "Valid shell unexpectedly failed (exit $($r3.Exit))" }
if (-not ($r3.Stderr -match "failed to create session")) { Write-Pass "No spurious failure message for valid shell" } else { Write-Fail "False failure on valid shell" }
& $PSMUX has-session -t "iss370good" 2>$null
if ($LASTEXITCODE -eq 0) { Write-Pass "Valid-shell session is alive" } else { Write-Fail "Valid-shell session not alive" }
Cleanup "iss370good"

# --- TEST 4: stale log is NOT mistaken for a current failure ---
Write-Host "`n[Test 4] Stale server-startup.log not echoed on a later success" -ForegroundColor Yellow
# Write an old log (epoch far in the past), then start a good session.
@"
psmux server startup error
==========================
psmux version : 3.3.5
when (epoch s): 100000000
os.family     : windows

error:
  STALE_SHOULD_NOT_APPEAR spawn shell error from an old run

spawn context:
  CWD : nope
"@ | Set-Content -Path "$psmuxDir\server-startup.log" -Encoding UTF8

$conf = "$env:TEMP\iss370stale.conf"
"set-option -g default-shell `"$goodShell`"" | Set-Content -Path $conf -Encoding UTF8
Cleanup "iss370stale"; Reset-Warm
$outFile = "$env:TEMP\iss370stale.out"; $errFile = "$env:TEMP\iss370stale.err"
$env:PSMUX_CONFIG_FILE = $conf
$p = Start-Process -FilePath $PSMUX -ArgumentList "new-session","-d","-s","iss370stale" `
    -PassThru -WindowStyle Hidden -RedirectStandardOutput $outFile -RedirectStandardError $errFile
$p.WaitForExit(30000) | Out-Null
$env:PSMUX_CONFIG_FILE = $null
$staleErr = Get-Content $errFile -Raw -EA SilentlyContinue
if (-not ($staleErr -match "STALE_SHOULD_NOT_APPEAR")) { Write-Pass "Stale log content not surfaced" } else { Write-Fail "Stale log was wrongly echoed" }
Cleanup "iss370stale"

# === Win32 TUI VISUAL VERIFICATION (Strategy A) ===
Write-Host ("`n" + ("=" * 60)) -ForegroundColor Cyan
Write-Host "Win32 TUI VISUAL VERIFICATION" -ForegroundColor Cyan
Write-Host ("=" * 60) -ForegroundColor Cyan
$SESSION_TUI = "iss370_tui"
Cleanup $SESSION_TUI; Reset-Warm
$confGood = "$env:TEMP\iss370_tui.conf"
"set-option -g default-shell `"$goodShell`"" | Set-Content -Path $confGood -Encoding UTF8
$env:PSMUX_CONFIG_FILE = $confGood
$proc = Start-Process -FilePath $PSMUX -ArgumentList "new-session","-s",$SESSION_TUI -PassThru
$env:PSMUX_CONFIG_FILE = $null
# Poll for the attached session to register rather than betting on a fixed wait.
$tuiLive = $false
for ($i = 0; $i -lt 40; $i++) {
    Start-Sleep -Milliseconds 300
    & $PSMUX has-session -t $SESSION_TUI 2>$null
    if ($LASTEXITCODE -eq 0) { $tuiLive = $true; break }
}
if ($tuiLive) { Write-Pass "TUI: attached session with valid shell is live" } else { Write-Fail "TUI: session not live" }
& $PSMUX split-window -v -t $SESSION_TUI 2>&1 | Out-Null
Start-Sleep -Milliseconds 600
$panes = (& $PSMUX display-message -t $SESSION_TUI -p '#{window_panes}' 2>&1).Trim()
if ($panes -eq "2") { Write-Pass "TUI: split-window created 2 panes" } else { Write-Fail "TUI: expected 2 panes, got $panes" }
Cleanup $SESSION_TUI
try { Stop-Process -Id $proc.Id -Force -EA SilentlyContinue } catch {}

Write-Host "`n=== Results ===" -ForegroundColor Cyan
Write-Host "  Passed: $($script:TestsPassed)" -ForegroundColor Green
Write-Host "  Failed: $($script:TestsFailed)" -ForegroundColor $(if ($script:TestsFailed -gt 0) { "Red" } else { "Green" })
exit $script:TestsFailed
