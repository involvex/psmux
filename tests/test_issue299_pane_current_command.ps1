# Issue #299: pane_current_command diverges from tmux
# Tests that idle shells report the shell binary name (e.g. "pwsh") instead of
# the literal "shell", and that running processes report the immediate child
# (not a deep transient descendant).

$ErrorActionPreference = "Continue"
$PSMUX = (Get-Command psmux -EA Stop).Source
$SESSION = "test_issue299"
$psmuxDir = "$env:USERPROFILE\.psmux"
$script:TestsPassed = 0
$script:TestsFailed = 0

function Write-Pass($msg) { Write-Host "  [PASS] $msg" -ForegroundColor Green; $script:TestsPassed++ }
function Write-Fail($msg) { Write-Host "  [FAIL] $msg" -ForegroundColor Red; $script:TestsFailed++ }

function Cleanup {
    & $PSMUX kill-session -t $SESSION 2>&1 | Out-Null
    Start-Sleep -Milliseconds 500
    Remove-Item "$psmuxDir\$SESSION.*" -Force -EA SilentlyContinue
}

function Send-TcpCommand {
    param([string]$Session, [string]$Command)
    $port = (Get-Content "$psmuxDir\$Session.port" -Raw).Trim()
    $key = (Get-Content "$psmuxDir\$Session.key" -Raw).Trim()
    $tcp = [System.Net.Sockets.TcpClient]::new("127.0.0.1", [int]$port)
    $tcp.NoDelay = $true
    $stream = $tcp.GetStream()
    $writer = [System.IO.StreamWriter]::new($stream)
    $reader = [System.IO.StreamReader]::new($stream)
    $writer.Write("AUTH $key`n"); $writer.Flush()
    $authResp = $reader.ReadLine()
    if ($authResp -ne "OK") { $tcp.Close(); return "AUTH_FAILED" }
    $writer.Write("$Command`n"); $writer.Flush()
    $stream.ReadTimeout = 10000
    try { $resp = $reader.ReadLine() } catch { $resp = "TIMEOUT" }
    $tcp.Close()
    return $resp
}

# === SETUP ===
Cleanup
& $PSMUX new-session -d -s $SESSION
Start-Sleep -Seconds 4

& $PSMUX has-session -t $SESSION 2>$null
if ($LASTEXITCODE -ne 0) {
    Write-Fail "Session creation failed"
    exit 1
}

Write-Host "`n=== Issue #299 Tests ===" -ForegroundColor Cyan

# ====================================================================
# Part A: CLI path — Divergence #1 (idle shell)
# ====================================================================

Write-Host "`n[Test 1] Idle shell reports shell binary name via list-panes" -ForegroundColor Yellow
$idle = (& $PSMUX list-panes -t $SESSION -F '#{pane_current_command}' 2>&1 | Out-String).Trim()
if ($idle -match "^(pwsh|powershell)$") { Write-Pass "Idle shell = '$idle' (not 'shell')" }
else { Write-Fail "Expected 'pwsh' or 'powershell', got '$idle'" }

Write-Host "`n[Test 2] Idle shell reports shell binary name via display-message" -ForegroundColor Yellow
$dm = (& $PSMUX display-message -t $SESSION -p '#{pane_current_command}' 2>&1 | Out-String).Trim()
if ($dm -match "^(pwsh|powershell)$") { Write-Pass "display-message = '$dm' (not 'shell')" }
else { Write-Fail "Expected 'pwsh' or 'powershell', got '$dm'" }

# ====================================================================
# Part A: CLI path — Divergence #1 regression guard
# ====================================================================

Write-Host "`n[Test 3] pane_current_command is NOT the literal 'shell'" -ForegroundColor Yellow
if ($idle -ne "shell") { Write-Pass "Not literal 'shell' — regression guard passed" }
else { Write-Fail "BUG STILL PRESENT: returns literal 'shell' for idle pane" }

# ====================================================================
# Part A: CLI path — Running process detection
# ====================================================================

Write-Host "`n[Test 4] Running process detected as foreground command" -ForegroundColor Yellow
& $PSMUX send-keys -t $SESSION 'ping -n 20 127.0.0.1' Enter
Start-Sleep -Seconds 3
$running = (& $PSMUX list-panes -t $SESSION -F '#{pane_current_command}' 2>&1 | Out-String).Trim()
if ($running -match "^ping$" -or $running -match "^PING$") { Write-Pass "Running process = '$running'" }
else { Write-Fail "Expected 'ping' or 'PING', got '$running'" }

& $PSMUX send-keys -t $SESSION C-c
Start-Sleep -Seconds 2

Write-Host "`n[Test 5] Returns to shell name after process exits" -ForegroundColor Yellow
$afterStop = (& $PSMUX list-panes -t $SESSION -F '#{pane_current_command}' 2>&1 | Out-String).Trim()
if ($afterStop -match "^(pwsh|powershell)$") { Write-Pass "Back to '$afterStop' after stop" }
else { Write-Fail "Expected 'pwsh' after process exit, got '$afterStop'" }

# ====================================================================
# Part B: TCP server path
# ====================================================================

Write-Host "`n[Test 6] TCP path: pane_current_command via list-panes" -ForegroundColor Yellow
$tcpResp = Send-TcpCommand -Session $SESSION -Command "list-panes -F '#{pane_current_command}'"
if ($tcpResp -match "(pwsh|powershell)") { Write-Pass "TCP list-panes = '$tcpResp'" }
else { Write-Fail "TCP list-panes expected pwsh, got '$tcpResp'" }

Write-Host "`n[Test 7] TCP path: display-message pane_current_command" -ForegroundColor Yellow
$tcpDm = Send-TcpCommand -Session $SESSION -Command "display-message -p '#{pane_current_command}'"
if ($tcpDm -match "(pwsh|powershell)") { Write-Pass "TCP display-message = '$tcpDm'" }
else { Write-Fail "TCP display-message expected pwsh, got '$tcpDm'" }

# ====================================================================
# Part C: Edge cases
# ====================================================================

Write-Host "`n[Test 8] After split-window, new pane also reports shell name" -ForegroundColor Yellow
& $PSMUX split-window -v -t $SESSION 2>&1 | Out-Null
Start-Sleep -Seconds 3
$splitCmd = (& $PSMUX display-message -t $SESSION -p '#{pane_current_command}' 2>&1 | Out-String).Trim()
if ($splitCmd -match "^(pwsh|powershell)$") { Write-Pass "Split pane = '$splitCmd'" }
else { Write-Fail "Split pane expected pwsh, got '$splitCmd'" }

Write-Host "`n[Test 9] Multiple panes all report correct command" -ForegroundColor Yellow
$allPanes = (& $PSMUX list-panes -t $SESSION -F '#{pane_current_command}' 2>&1 | Out-String).Trim()
$paneLines = $allPanes -split "`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ }
$allCorrect = $true
foreach ($line in $paneLines) {
    if ($line -notmatch "^(pwsh|powershell)$") { $allCorrect = $false }
}
if ($allCorrect -and $paneLines.Count -ge 2) { Write-Pass "All $($paneLines.Count) panes report shell name" }
else { Write-Fail "Not all panes correct: $allPanes" }

# ====================================================================
# Part D: Win32 TUI Visual Verification
# ====================================================================

Write-Host "`n" + ("=" * 60) -ForegroundColor Cyan
Write-Host "Win32 TUI VISUAL VERIFICATION" -ForegroundColor Cyan
Write-Host ("=" * 60) -ForegroundColor Cyan

$SESSION_TUI = "issue299_tui_proof"
& $PSMUX kill-session -t $SESSION_TUI 2>&1 | Out-Null
Start-Sleep -Milliseconds 500
Remove-Item "$psmuxDir\$SESSION_TUI.*" -Force -EA SilentlyContinue

$proc = Start-Process -FilePath $PSMUX -ArgumentList "new-session","-s",$SESSION_TUI -PassThru
Start-Sleep -Seconds 4

Write-Host "`n[Test 10] TUI: Attached session pane_current_command" -ForegroundColor Yellow
$tuiCmd = (& $PSMUX display-message -t $SESSION_TUI -p '#{pane_current_command}' 2>&1 | Out-String).Trim()
if ($tuiCmd -match "^(pwsh|powershell)$") { Write-Pass "TUI pane_current_command = '$tuiCmd'" }
else { Write-Fail "TUI expected pwsh, got '$tuiCmd'" }

Write-Host "`n[Test 11] TUI: split-window + verify both panes" -ForegroundColor Yellow
& $PSMUX split-window -v -t $SESSION_TUI 2>&1 | Out-Null
Start-Sleep -Seconds 3
$tuiPanes = (& $PSMUX list-panes -t $SESSION_TUI -F '#{pane_current_command}' 2>&1 | Out-String).Trim()
$tuiLines = $tuiPanes -split "`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ }
$allOk = ($tuiLines | Where-Object { $_ -match "^(pwsh|powershell)$" }).Count -eq $tuiLines.Count
if ($allOk -and $tuiLines.Count -ge 2) { Write-Pass "TUI: All $($tuiLines.Count) panes report shell name" }
else { Write-Fail "TUI panes: $tuiPanes" }

Write-Host "`n[Test 12] TUI: run command and verify foreground detection" -ForegroundColor Yellow
& $PSMUX send-keys -t $SESSION_TUI 'ping -n 10 127.0.0.1' Enter
Start-Sleep -Seconds 3
$tuiRunning = (& $PSMUX display-message -t $SESSION_TUI -p '#{pane_current_command}' 2>&1 | Out-String).Trim()
if ($tuiRunning -match "^(ping|PING)$") { Write-Pass "TUI running process = '$tuiRunning'" }
else { Write-Fail "TUI running expected ping, got '$tuiRunning'" }

& $PSMUX send-keys -t $SESSION_TUI C-c
Start-Sleep -Seconds 1

# Cleanup
& $PSMUX kill-session -t $SESSION_TUI 2>&1 | Out-Null
try { Stop-Process -Id $proc.Id -Force -EA SilentlyContinue } catch {}

# === TEARDOWN ===
Cleanup

Write-Host "`n=== Results ===" -ForegroundColor Cyan
Write-Host "  Passed: $($script:TestsPassed)" -ForegroundColor Green
Write-Host "  Failed: $($script:TestsFailed)" -ForegroundColor $(if ($script:TestsFailed -gt 0) { "Red" } else { "Green" })
exit $script:TestsFailed
