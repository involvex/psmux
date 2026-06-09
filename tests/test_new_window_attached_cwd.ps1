#!/usr/bin/env pwsh
# Test: a new window created by an ATTACHED client opens in the session start
# directory, NOT the directory the session was launched from.
#
# This is the cwd bug this PR fixes: the server used to restore its cwd to the
# launch dir after creating the initial window (before replenishing the warm
# pane), so a later new-window spawned in the launch dir instead of the session
# start dir. tmux opens an attached client's new-window in the session start
# dir (the attached one of its three cwd cases — the issuing client IS attached).
#
# We exercise the attached path headlessly via CONTROL MODE (`psmux -CC attach`):
# a control client is attached to the session, so a new-window it issues is an
# attached-client command. We pipe "new-window" on its stdin and let stdin EOF
# make the control client process the command and exit. The control client is run
# FROM the launch dir, so if the new window wrongly used the attached client's
# cwd (the old bug) it would land there — the test requires the session dir.
#
# Runs with warm panes BOTH on and off: a warm pane is pre-spawned in the server
# (session) cwd, so the attached new-window must land in the session dir either
# way — the optimisation must not change where the window opens.
#
# Well-behaved on a shared server: unique session name, cleans up with
# kill-session (never kill-server).

$ErrorActionPreference = "Continue"
$results = @()

function Add-Result($name, $pass, $detail = "") {
    $script:results += [PSCustomObject]@{
        Test = $name; Result = if ($pass) { "PASS" } else { "FAIL" }; Detail = $detail
    }
}

# Binary discovery: $env:PSMUX_EXE first (CI convention), then local build outputs.
$PSMUX = $env:PSMUX_EXE
if (-not $PSMUX -or -not (Test-Path $PSMUX)) { $PSMUX = Join-Path $PSScriptRoot "..\target\debug\psmux.exe" }
if (-not (Test-Path $PSMUX)) { $PSMUX = Join-Path $PSScriptRoot "..\target\release\psmux.exe" }
if (-not (Test-Path $PSMUX)) {
    Write-Host "psmux binary not found; build the project first." -ForegroundColor Red
    exit 1
}

# Launch every pane as `pwsh -NoProfile` so the pane shell never changes its own
# cwd, making #{pane_current_path} the spawn dir (see test_new_window_detached_cwd.ps1).
$cfgFile = Join-Path ([System.IO.Path]::GetTempPath()) ("psmux_attcwd_" + [guid]::NewGuid().ToString("N") + ".conf")
Set-Content -LiteralPath $cfgFile -Value 'set -g default-command "pwsh -NoProfile"'
$env:PSMUX_CONFIG_FILE = $cfgFile

function Normalize-Path($p) {
    if ([string]::IsNullOrWhiteSpace($p)) { return "" }
    try { $p = (Get-Item -LiteralPath $p -ErrorAction Stop).FullName } catch { }
    ($p -replace '/', '\').TrimEnd('\').ToLower()
}
function Get-PanePath($target) {
    (& $PSMUX display-message -p -t $target '#{pane_current_path}' 2>&1 | Out-String).Trim()
}
function Wait-ForSession($name, $timeoutSec = 10) {
    for ($i = 0; $i -lt ($timeoutSec * 5); $i++) {
        & $PSMUX has-session -t $name 2>$null
        if ($LASTEXITCODE -eq 0) { return $true }
        Start-Sleep -Milliseconds 200
    }
    return $false
}
# Poll #{pane_current_path} until it converges to $expectNorm, then return the raw
# value. Panes run -NoProfile so they never change cwd; we only wait out the
# latency between spawning the pane process and it reporting its cwd. A wrong cwd
# never converges -> fails by timeout with the last value seen, so this can't
# mask a regression.
function Wait-PanePath($target, $expectNorm, $timeoutSec = 10) {
    $last = ""
    for ($i = 0; $i -lt ($timeoutSec * 5); $i++) {
        $last = Get-PanePath $target
        if ((Normalize-Path $last) -eq $expectNorm) { return $last }
        Start-Sleep -Milliseconds 200
    }
    return $last
}

# Poll until $winTarget reports >= $count panes (each with a resolved cwd) and
# return their raw cwds; on timeout return whatever was last seen.
function Wait-AllPanePaths($winTarget, $count, $timeoutSec = 10) {
    $paths = @()
    for ($i = 0; $i -lt ($timeoutSec * 5); $i++) {
        $paths = & $PSMUX list-panes -t $winTarget -F '#{pane_current_path}' 2>&1 |
            ForEach-Object { $_.ToString().Trim() } | Where-Object { $_ }
        if ($paths.Count -ge $count) { return $paths }
        Start-Sleep -Milliseconds 200
    }
    return $paths
}

$testRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot "..\target\cwd_attached_test"))

function Test-Mode {
    param([string]$Mode, [bool]$WarmOff)

    if ($WarmOff) { $env:PSMUX_NO_WARM = "1" } else { Remove-Item Env:\PSMUX_NO_WARM -ErrorAction SilentlyContinue }

    $sess     = "attcwd_${Mode}_"        + [guid]::NewGuid().ToString("N").Substring(0, 8)
    $startDir = Join-Path $testRoot ("start_${Mode}_"  + [guid]::NewGuid().ToString("N").Substring(0, 8))
    $launchDir = Join-Path $testRoot ("launch_${Mode}_" + [guid]::NewGuid().ToString("N").Substring(0, 8))
    New-Item -ItemType Directory -Path $startDir, $launchDir -Force | Out-Null

    try {
        # Create the session FROM $launchDir but with -c $startDir.
        Push-Location $launchDir
        & $PSMUX new-session -d -s $sess -c $startDir
        Pop-Location
        if (-not (Wait-ForSession $sess)) {
            Add-Result "[$Mode] session ready" $false "new-session never became ready"
            return
        }

        # Attached new-window via control mode, issued from $launchDir. The control
        # client is attached, so tmux semantics put the window in the session dir.
        # Piping the command then closing stdin makes -CC attach run it and exit.
        Push-Location $launchDir
        "new-window`n" | & $PSMUX -CC attach -t $sess *> $null
        Pop-Location

        $expectStart = Normalize-Path $startDir
        $raw = Wait-PanePath "${sess}:1" $expectStart
        Add-Result "[$Mode] attached new-window opens in session dir (not launch dir)" `
            ((Normalize-Path $raw) -eq $expectStart) "got '$raw' expected '$startDir' (launch was '$launchDir')"

        # Attached split-window via control mode, issued from $launchDir. The new
        # pane must also open in the session dir. Split the initial window (window
        # 0, whose pane is already in the session dir) and require BOTH its panes
        # to be in the session dir -- pre-fix the split pane spawned in the launch
        # dir (the server's restored cwd).
        Push-Location $launchDir
        "split-window -t ${sess}:0`n" | & $PSMUX -CC attach -t $sess *> $null
        Pop-Location

        $paths = Wait-AllPanePaths "${sess}:0" 2
        $allInStart = ($paths.Count -ge 2) -and (@($paths | Where-Object { (Normalize-Path $_) -ne $expectStart }).Count -eq 0)
        Add-Result "[$Mode] attached split-window opens in session dir (not launch dir)" `
            $allInStart "panes: $($paths -join ' | ') expected all '$startDir' (launch was '$launchDir')"

    } finally {
        & $PSMUX kill-session -t $sess 2>$null
        Remove-Item $startDir, $launchDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Test-Mode -Mode "warm-off" -WarmOff $true
Test-Mode -Mode "warm-on"  -WarmOff $false

Remove-Item -LiteralPath $cfgFile -Force -ErrorAction SilentlyContinue

Write-Host "`n=== attached (control-mode) new-window opens in session start dir (warm on + off) ===" -ForegroundColor Cyan
$results | Format-Table -AutoSize
$failed = ($results | Where-Object { $_.Result -eq "FAIL" }).Count
$total = $results.Count
$passed = $total - $failed
Write-Host "Total: $total | Passed: $passed | Failed: $failed" -ForegroundColor $(if ($failed -gt 0) { "Red" } else { "Green" })
if ($failed -gt 0) { exit 1 }
