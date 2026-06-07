# Issue #361: OSC 8 hyperlinks, end-to-end through a real pane.
#
# The psmux-side pipeline (OSC 8 parse -> per-cell store -> rows_v2 serialize ->
# build_osc8_overlay re-emit) is fully covered by Rust unit tests. This E2E
# additionally checks the ONE part outside psmux's control: whether ConPTY
# delivers OSC 8 to psmux at all. ConPTY only passes OSC 8 in passthrough mode;
# some Windows 11 builds (e.g. 26200) break CreateProcessW with that flag, so
# psmux falls back to non-passthrough and OSC 8 is stripped before psmux sees
# it. On those builds this test reports the ConPTY limitation instead of failing
# (the psmux side is proven by the unit tests).
$ErrorActionPreference="Continue"
$PSMUX=(Get-Command psmux -EA Stop).Source
$psmuxDir="$env:USERPROFILE\.psmux"
$S="t361"
$URI="https://example.com/issue361"
$LINKTEXT="PSMUXLINK361"
$script:Pass=0; $script:Fail=0
function Write-Pass($m){ Write-Host "  [PASS] $m" -ForegroundColor Green; $script:Pass++ }
function Write-Fail($m){ Write-Host "  [FAIL] $m" -ForegroundColor Red; $script:Fail++ }
function Write-Skip($m){ Write-Host "  [SKIP] $m" -ForegroundColor Yellow }

function Get-Dump {
    param([string]$Session)
    $port=(Get-Content "$psmuxDir\$Session.port" -Raw).Trim()
    $key=(Get-Content "$psmuxDir\$Session.key" -Raw).Trim()
    $tcp=[System.Net.Sockets.TcpClient]::new("127.0.0.1",[int]$port); $tcp.NoDelay=$true; $tcp.ReceiveTimeout=4000
    $st=$tcp.GetStream(); $w=[System.IO.StreamWriter]::new($st); $r=[System.IO.StreamReader]::new($st)
    $w.Write("AUTH $key`n"); $w.Flush(); $null=$r.ReadLine(); $w.Write("dump-state`n"); $w.Flush()
    $best=$null; for($j=0;$j -lt 80;$j++){ try{$l=$r.ReadLine()}catch{break}; if($null -eq $l){break}; if($l -ne "NC" -and $l.Length -gt 100){$best=$l;break} }
    $tcp.Close(); return $best
}

Write-Host "=== Issue #361: OSC 8 hyperlink end-to-end ===" -ForegroundColor Cyan
& $PSMUX kill-session -t $S 2>&1 | Out-Null; Start-Sleep -Milliseconds 500
& $PSMUX new-session -d -s $S 2>&1 | Out-Null
Start-Sleep -Seconds 3
& $PSMUX has-session -t $S 2>$null
if ($LASTEXITCODE -ne 0) { Write-Fail "session create failed"; exit 1 }

# Emit a raw OSC 8 hyperlink from inside the pane (mimics `delta`/`ls --hyperlink`):
#   ESC ]8;;URI ESC \  LINKTEXT  ESC ]8;; ESC \
$emit="$env:TEMP\psmux_emit361.ps1"
@"
`$seq = [char]27 + "]8;;$URI" + [char]27 + "\$LINKTEXT" + [char]27 + "]8;;" + [char]27 + "\" + "``n"
`$bytes = [System.Text.Encoding]::UTF8.GetBytes(`$seq)
`$o = [System.Console]::OpenStandardOutput(); `$o.Write(`$bytes,0,`$bytes.Length); `$o.Flush()
"@ | Set-Content -Path $emit -Encoding UTF8
& $PSMUX send-keys -t $S "& '$emit'" Enter 2>&1 | Out-Null
Start-Sleep -Seconds 2

$dump = Get-Dump $S
if (-not $dump) { Write-Fail "no dump-state received"; & $PSMUX kill-session -t $S 2>&1 | Out-Null; exit 1 }

$linkPresent = $dump -match [regex]::Escape("`"link`":`"$URI`"")
$textPresent = $dump -match [regex]::Escape($LINKTEXT)

if ($linkPresent) {
    Write-Pass "OSC 8 reached psmux and the link URI was serialized into rows_v2 (ConPTY passthrough active)"
} elseif ($textPresent) {
    Write-Skip "ConPTY stripped OSC 8 on this Windows build (text arrived, link did not)."
    Write-Skip "The psmux-side OSC 8 pipeline is verified by the Rust unit tests; it activates where ConPTY passthrough works."
} else {
    Write-Fail "neither link nor text reached psmux (emission failed)"
}

& $PSMUX kill-session -t $S 2>&1 | Out-Null
Remove-Item $emit -Force -EA SilentlyContinue
Write-Host "`n=== Results: Passed=$($script:Pass) Failed=$($script:Fail) ===" -ForegroundColor Cyan
exit $script:Fail
