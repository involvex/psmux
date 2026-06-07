# Issue #360: mouse wheel in a normal pane must enter copy/scroll mode when
# mouse=on and scroll-enter-copy-mode=on, even when the shell has filled the
# screen with output (cursor at the bottom).
#
# Root cause was is_fullscreen_tui() in pane_wants_mouse() misclassifying a
# filled shell as a TUI app and forwarding the wheel instead of entering copy
# mode. Fix: scroll uses the stricter pane_wants_scroll_forward() (mouse
# protocol or alternate screen only).
#
# This drives a REAL attached psmux client in classic conhost and injects REAL
# console mouse-wheel events via WriteConsoleInput, then verifies copy_mode via
# TCP dump-state.
$ErrorActionPreference="Continue"
$PSMUX=(Get-Command psmux -EA Stop).Source
$MINJ="$env:LOCALAPPDATA\Temp\psmux_mouse_injector.exe"
$psmuxDir="$env:USERPROFILE\.psmux"
$S="t360"
$script:Pass=0; $script:Fail=0
function Write-Pass($m){ Write-Host "  [PASS] $m" -ForegroundColor Green; $script:Pass++ }
function Write-Fail($m){ Write-Host "  [FAIL] $m" -ForegroundColor Red; $script:Fail++ }

# compile mouse injector if missing
if (-not (Test-Path $MINJ)) {
    $csc="C:\Windows\Microsoft.NET\Framework64\v4.0.30319\csc.exe"
    $src=Join-Path (Split-Path $PSScriptRoot -Parent) "tests\mouse_injector.cs"
    if (-not (Test-Path $src)) { $src="$PSScriptRoot\mouse_injector.cs" }
    & $csc /nologo /optimize /out:$MINJ $src 2>&1 | Out-Null
}

$sk="HKCU:\Console\%%Startup"; if(-not(Test-Path $sk)){New-Item -Path $sk -Force|Out-Null}
$oDC=(Get-ItemProperty $sk -EA SilentlyContinue).DelegationConsole; $oDT=(Get-ItemProperty $sk -EA SilentlyContinue).DelegationTerminal
$classic="{B23D10C0-E52E-411E-9D5B-C09FDF709C7D}"
Set-ItemProperty $sk -Name DelegationConsole -Value $classic; Set-ItemProperty $sk -Name DelegationTerminal -Value $classic
function Restore { if($oDC){Set-ItemProperty $sk -Name DelegationConsole -Value $oDC}else{Remove-ItemProperty $sk -Name DelegationConsole -EA SilentlyContinue}; if($oDT){Set-ItemProperty $sk -Name DelegationTerminal -Value $oDT}else{Remove-ItemProperty $sk -Name DelegationTerminal -EA SilentlyContinue} }
function Get-CopyMode { param($Session)
    $port=(Get-Content "$psmuxDir\$Session.port" -Raw).Trim(); $key=(Get-Content "$psmuxDir\$Session.key" -Raw).Trim()
    $tcp=[System.Net.Sockets.TcpClient]::new("127.0.0.1",[int]$port); $tcp.NoDelay=$true; $tcp.ReceiveTimeout=4000
    $st=$tcp.GetStream(); $w=[System.IO.StreamWriter]::new($st); $r=[System.IO.StreamReader]::new($st)
    $w.Write("AUTH $key`n"); $w.Flush(); $null=$r.ReadLine(); $w.Write("dump-state`n"); $w.Flush()
    $best=$null; for($j=0;$j -lt 60;$j++){ try{$l=$r.ReadLine()}catch{break}; if($null -eq $l){break}; if($l -ne "NC" -and $l.Length -gt 100){$best=$l;break} }
    $tcp.Close(); if($best -match '"copy_mode"\s*:\s*true'){return $true}else{return $false} }

Write-Host "=== Issue #360: mouse wheel enters copy mode on a filled shell ===" -ForegroundColor Cyan
& $PSMUX kill-session -t $S 2>&1 | Out-Null; Start-Sleep -Milliseconds 600
$conhost="$env:WINDIR\System32\conhost.exe"
$proc=Start-Process -FilePath $conhost -ArgumentList $PSMUX,"new-session","-s",$S -PassThru
Start-Sleep -Seconds 6
$child=Get-CimInstance Win32_Process -Filter "ParentProcessId=$($proc.Id)" | Where-Object {$_.Name -eq 'psmux.exe'} | Select-Object -First 1
$cpid=if($child){[int]$child.ProcessId}else{$proc.Id}

& $PSMUX set-option -g mouse on -t $S 2>&1 | Out-Null
& $PSMUX set-option -g scroll-enter-copy-mode on -t $S 2>&1 | Out-Null
& $PSMUX set-option -g history-limit 10000 -t $S 2>&1 | Out-Null

# fill the screen so the prompt sits at the bottom (the regression scenario)
& $PSMUX send-keys -t $S "1..200" Enter 2>&1 | Out-Null
Start-Sleep -Seconds 3

$before = Get-CopyMode $S
& $MINJ $cpid up 4 40 10 | Out-Null
Start-Sleep -Seconds 2
$after = Get-CopyMode $S
Write-Host "  filled-shell wheel-up: copy_mode before=$before after=$after"
if (-not $before -and $after) { Write-Pass "wheel-up entered copy mode on a filled shell (mouse scroll works)" }
else { Write-Fail "wheel-up did NOT enter copy mode (before=$before after=$after) -- #360 present" }

# and it should still scroll within copy mode (wheel again moves the view)
$d1port=(Get-Content "$psmuxDir\$S.port" -Raw).Trim()
& $MINJ $cpid up 4 40 10 | Out-Null
Start-Sleep -Milliseconds 800
$still = Get-CopyMode $S
if ($still) { Write-Pass "still in copy mode after further wheel-up (scrolling history)" }
else { Write-Fail "fell out of copy mode unexpectedly" }

& $PSMUX kill-session -t $S 2>&1 | Out-Null
try{Stop-Process -Id $proc.Id -Force -EA SilentlyContinue}catch{}
Restore
Write-Host "`n=== Results: Passed=$($script:Pass) Failed=$($script:Fail) ===" -ForegroundColor Cyan
exit $script:Fail
