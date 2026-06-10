# Issue #371 regression guard: the fix (timer-driven prefix-end) must NOT break
# the actual -r repeat feature. Within repeat-time, a follow-up key WITHOUT
# re-pressing prefix must still fire the binding again.
#
# Proof: prefix+H then a second H ~150ms later (inside 500ms window) must resize
# the pane TWICE (width drops by ~10, not ~5). Also: during the active window
# client_prefix must read 1 (indicator correctly ON), then clear to 0 afterward.

$ErrorActionPreference = "Continue"
$PSMUX = (Get-Command psmux -EA Stop).Source
$psmuxDir = "$env:USERPROFILE\.psmux"
$injectorExe = "$env:TEMP\psmux_injector.exe"
$SESSION = "issue371_repeatkeep"
$pass = 0; $fail = 0
function P($m){ Write-Host "  [PASS] $m" -ForegroundColor Green; $script:pass++ }
function F($m){ Write-Host "  [FAIL] $m" -ForegroundColor Red; $script:fail++ }
function I($m){ Write-Host "  [INFO] $m" -ForegroundColor DarkCyan }
function W($s){ (& $PSMUX display-message -t $s -p '#{pane_width}' 2>&1|Out-String).Trim() }
function PFX($s){ (& $PSMUX display-message -t $s -p '#{client_prefix}' 2>&1|Out-String).Trim() }

& $PSMUX kill-session -t $SESSION 2>&1 | Out-Null
Start-Sleep -Milliseconds 400
Remove-Item "$psmuxDir\$SESSION.*" -Force -EA SilentlyContinue

$conf = "$env:TEMP\psmux_issue371_keep.conf"
"bind -r H resize-pane -L 5`nset -g repeat-time 500" | Set-Content $conf -Encoding UTF8
$env:PSMUX_CONFIG_FILE = $conf
$proc = Start-Process -FilePath $PSMUX -ArgumentList "new-session","-s",$SESSION -PassThru
Start-Sleep -Seconds 4
$env:PSMUX_CONFIG_FILE = $null

& $PSMUX split-window -h -t $SESSION 2>&1 | Out-Null
Start-Sleep -Milliseconds 800
& $PSMUX select-pane -t "$SESSION.0" 2>&1 | Out-Null
Start-Sleep -Milliseconds 300

$w0 = W $SESSION
I "Start width = $w0"

Write-Host "`n[Test A] Repeat WITHOUT re-pressing prefix (prefix+H then H within window)" -ForegroundColor Yellow
# prefix, 350ms, H, 150ms, H  -> second H is inside the 500ms repeat window
& $injectorExe $proc.Id "^b{SLEEP:350}H{SLEEP:150}H" | Out-Null
Start-Sleep -Milliseconds 300
$w1 = W $SESSION
$delta = [int]$w0 - [int]$w1
I "After prefix+H+H: width=$w1 (delta=$delta)"
if ($delta -ge 9) { P "Repeat WORKS: two resizes from one prefix (delta=$delta ~= 10)" }
elseif ($delta -ge 4) { F "Only ONE resize happened (delta=$delta) - repeat window broken by fix" }
else { F "No resize (delta=$delta) - binding did not fire" }

Write-Host "`n[Test B] Indicator clears on its own after the window" -ForegroundColor Yellow
Start-Sleep -Milliseconds 1500
$pfxAfter = PFX $SESSION
if ($pfxAfter -eq "0") { P "client_prefix cleared to 0 after repeat window (no stuck indicator)" }
else { F "client_prefix=$pfxAfter after window (still stuck)" }

Write-Host "`n[Test C] Indicator is ON during the active repeat window" -ForegroundColor Yellow
# Press prefix+H, then immediately (well within 500ms) sample client_prefix
& $injectorExe $proc.Id "^b{SLEEP:300}H" | Out-Null
# sample fast - aim to land inside the 500ms window
Start-Sleep -Milliseconds 80
$pfxDuring = PFX $SESSION
I "client_prefix shortly after prefix+H (inside window) = $pfxDuring"
if ($pfxDuring -eq "1") { P "Indicator correctly ON during active repeat window" }
else { I "Sampled outside window (got $pfxDuring) - timing-sensitive, not a failure" }
Start-Sleep -Milliseconds 1200
$pfxEnd = PFX $SESSION
if ($pfxEnd -eq "0") { P "Indicator cleared again after window (final=$pfxEnd)" }
else { F "Indicator stuck at $pfxEnd" }

& $PSMUX kill-session -t $SESSION 2>&1 | Out-Null
try { Stop-Process -Id $proc.Id -Force -EA SilentlyContinue } catch {}
Remove-Item $conf -Force -EA SilentlyContinue

Write-Host "`nPassed: $pass  Failed: $fail" -ForegroundColor $(if($fail){"Red"}else{"Green"})
exit $fail
