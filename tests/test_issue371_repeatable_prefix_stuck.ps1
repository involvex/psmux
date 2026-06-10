# Issue #371: Prefix-active indicator (client_prefix) stuck on after a repeatable (-r) prefix binding
# Claim: after `bind -r H resize-pane -L 5` fires, #{client_prefix} stays 1 indefinitely
# until the next unrelated keypress, instead of clearing once repeat-time (500ms) elapses.
#
# This test injects REAL keystrokes (prefix + H) into an attached psmux window via
# WriteConsoleInput, proves the repeatable binding actually fired (pane width changes),
# then polls #{client_prefix} over several seconds WITHOUT any further key.
# A control session with a NON-repeatable binding establishes the correct baseline.

$ErrorActionPreference = "Continue"
$PSMUX = (Get-Command psmux -EA Stop).Source
$psmuxDir = "$env:USERPROFILE\.psmux"
$injectorExe = "$env:TEMP\psmux_injector.exe"
$script:TestsPassed = 0
$script:TestsFailed = 0

function Write-Pass($msg) { Write-Host "  [PASS] $msg" -ForegroundColor Green; $script:TestsPassed++ }
function Write-Fail($msg) { Write-Host "  [FAIL] $msg" -ForegroundColor Red; $script:TestsFailed++ }
function Write-Info($msg) { Write-Host "  [INFO] $msg" -ForegroundColor DarkCyan }

function Get-Prefix($sess) {
    (& $PSMUX display-message -t $sess -p '#{client_prefix}' 2>&1 | Out-String).Trim()
}
function Get-PaneWidth($sess) {
    (& $PSMUX display-message -t $sess -p '#{pane_width}' 2>&1 | Out-String).Trim()
}

function Run-Scenario {
    param(
        [string]$Session,
        [string]$BindLine,   # the bind directive to put in config
        [bool]$Repeatable
    )
    Write-Host "`n=== Scenario: $Session  ($BindLine) ===" -ForegroundColor Cyan

    # Clean
    & $PSMUX kill-session -t $Session 2>&1 | Out-Null
    Start-Sleep -Milliseconds 400
    Remove-Item "$psmuxDir\$Session.*" -Force -EA SilentlyContinue

    # Config
    $conf = "$env:TEMP\psmux_issue371_$Session.conf"
    @"
$BindLine
set -g status-left "PFX=#{?client_prefix,ON,off} "
"@ | Set-Content -Path $conf -Encoding UTF8

    $env:PSMUX_CONFIG_FILE = $conf
    $proc = Start-Process -FilePath $PSMUX -ArgumentList "new-session","-s",$Session -PassThru
    Start-Sleep -Seconds 4
    $env:PSMUX_CONFIG_FILE = $null

    & $PSMUX has-session -t $Session 2>$null
    if ($LASTEXITCODE -ne 0) { Write-Fail "$Session never started"; return }

    # Two panes side by side so resize-pane -L has a visible effect
    & $PSMUX split-window -h -t $Session 2>&1 | Out-Null
    Start-Sleep -Milliseconds 800
    & $PSMUX select-pane -t "$Session.0" 2>&1 | Out-Null
    Start-Sleep -Milliseconds 300

    $w0 = Get-PaneWidth $Session
    $p0 = Get-Prefix $Session
    Write-Info "Before injection: pane_width=$w0  client_prefix=$p0"
    if ($p0 -ne "0") { Write-Fail "$Session : client_prefix not 0 at rest (got $p0)" }
    else { Write-Pass "$Session : client_prefix is 0 at rest" }

    # Inject prefix (Ctrl+B) then H  -> fires the binding
    & $injectorExe $proc.Id "^b{SLEEP:350}H" | Out-Null
    Start-Sleep -Milliseconds 250

    # Prove the binding actually FIRED: pane width must have changed by ~5
    $w1 = Get-PaneWidth $Session
    Write-Info "Immediately after prefix+H: pane_width=$w1"
    if ($w1 -ne $w0) { Write-Pass "$Session : binding FIRED (pane_width $w0 -> $w1)" }
    else { Write-Fail "$Session : binding did NOT fire (pane_width unchanged at $w0)" }

    # Now poll client_prefix over time WITHOUT pressing any further key.
    # repeat-time is 500ms, so by ~800ms+ it should be 0 (cleared) for BOTH bindings.
    $samples = @()
    foreach ($delayMs in @(150, 800, 1500, 3000)) {
        Start-Sleep -Milliseconds $delayMs
        $p = Get-Prefix $Session
        $samples += [pscustomobject]@{ At = $delayMs; Prefix = $p }
        Write-Info "  +${delayMs}ms cumulative wait : client_prefix=$p"
    }
    # Total elapsed since H ~= 5.45s, far beyond repeat-time(500ms).

    $finalNoKey = $samples[-1].Prefix
    Write-Host "  --- After ~5.4s with NO further key: client_prefix=$finalNoKey ---" -ForegroundColor Yellow

    # Now press an unrelated key and confirm it clears (the issue says this is what clears it)
    & $injectorExe $proc.Id "x" | Out-Null
    Start-Sleep -Milliseconds 600
    $afterKey = Get-Prefix $Session
    Write-Info "After one unrelated key 'x': client_prefix=$afterKey"

    & $PSMUX kill-session -t $Session 2>&1 | Out-Null
    try { Stop-Process -Id $proc.Id -Force -EA SilentlyContinue } catch {}
    Remove-Item $conf -Force -EA SilentlyContinue

    return [pscustomobject]@{
        Session     = $Session
        Repeatable  = $Repeatable
        FiredWidth0 = $w0
        FiredWidth1 = $w1
        FinalNoKey  = $finalNoKey
        AfterKey    = $afterKey
        Samples     = $samples
    }
}

Write-Host "============================================================" -ForegroundColor Magenta
Write-Host " ISSUE #371 REPRODUCTION: repeatable -r prefix stuck client_prefix" -ForegroundColor Magenta
Write-Host "============================================================" -ForegroundColor Magenta

if (-not (Test-Path $injectorExe)) { Write-Fail "injector not compiled at $injectorExe"; exit 1 }

# CONTROL: non-repeatable binding -> indicator must clear on its own
$control = Run-Scenario -Session "issue371_norepeat" -BindLine "bind H resize-pane -L 5" -Repeatable $false

# SUBJECT: repeatable -r binding -> the alleged bug
$subject = Run-Scenario -Session "issue371_repeat" -BindLine "bind -r H resize-pane -L 5" -Repeatable $true

Write-Host "`n============================================================" -ForegroundColor Magenta
Write-Host " VERDICT" -ForegroundColor Magenta
Write-Host "============================================================" -ForegroundColor Magenta

# Both bindings should clear client_prefix to 0 after repeat-time elapses with no key.
# Bug = repeatable stays "1" at the 5.4s no-key sample while control is "0".
if ($control) {
    if ($control.FinalNoKey -eq "0") {
        Write-Pass "CONTROL (non-repeatable): client_prefix cleared to 0 on its own (correct)"
    } else {
        Write-Fail "CONTROL (non-repeatable): client_prefix=$($control.FinalNoKey) after 5.4s (unexpected)"
    }
}

if ($subject) {
    if ($subject.FinalNoKey -eq "1") {
        Write-Host "  >>> BUG REPRODUCED: repeatable -r binding left client_prefix STUCK at 1 after 5.4s with no key" -ForegroundColor Red
        if ($subject.AfterKey -eq "0") {
            Write-Host "  >>> CONFIRMED MECHANISM: pressing an unrelated key cleared it to 0" -ForegroundColor Red
        }
        $script:TestsFailed++  # count the reproduced bug as a failing (broken) assertion
    } elseif ($subject.FinalNoKey -eq "0") {
        Write-Pass "SUBJECT (repeatable): client_prefix cleared to 0 on its own -> NO bug / already fixed"
    } else {
        Write-Info "SUBJECT (repeatable): unexpected client_prefix='$($subject.FinalNoKey)'"
    }
}

Write-Host "`n--- Sample tables ---" -ForegroundColor DarkGray
if ($control) { Write-Host "CONTROL (non-repeatable):"; $control.Samples | Format-Table -AutoSize | Out-String | Write-Host }
if ($subject) { Write-Host "SUBJECT (repeatable -r):"; $subject.Samples | Format-Table -AutoSize | Out-String | Write-Host }

Write-Host "Passed: $($script:TestsPassed)  Failed/BugsReproduced: $($script:TestsFailed)"
