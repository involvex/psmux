# Repro for PR #357: a Windows paste that STARTS with a newline prematurely
# submits the current CLI input. Type an invalid partial command (no Enter), then
# paste clipboard content that begins with "`n". If the partial command executes
# (pwsh shows a "not recognized" error), the leading pasted newline submitted it.
#   BUG  : pane shows CommandNotFoundException for the partial token
#   FIXED: leading newline buffered with the paste, partial command NOT submitted
$ErrorActionPreference = "Continue"
$PSMUX = (Get-Command psmux -EA Stop).Source
$inj = "$env:TEMP\psmux_injector.exe"
$psmuxDir = "$env:USERPROFILE\.psmux"
$s = "pr357"
function Cap { (& $PSMUX capture-pane -t $s -p 2>&1 | Out-String) }

& $PSMUX kill-session -t $s 2>&1 | Out-Null; Start-Sleep -Milliseconds 400
$p = Start-Process -FilePath $PSMUX -ArgumentList @("new-session","-s",$s,"pwsh -NoLogo -NoProfile") -PassThru
Start-Sleep -Seconds 5
$pid2 = $p.Id
for ($i=0;$i -lt 20;$i++){ Start-Sleep -Milliseconds 400; if ((Cap) -match 'PS\s'){break} }

# Clipboard content that STARTS with a newline
Set-Clipboard -Value "`nTAIL357TEXT"
Start-Sleep -Milliseconds 300

$token = "zzqpartialcmd357"
# Type the invalid partial command WITHOUT pressing Enter
& $inj $pid2 $token
Start-Sleep -Milliseconds 500
$before = Cap
Write-Host "--- before paste (should show '$token' on input line, NOT executed) ---"
Write-Host ($before -split "`n" | Where-Object {$_.Trim()} | Select-Object -Last 3 | Out-String)

# Paste via Ctrl+V (triggers Windows console paste of the clipboard)
& $inj $pid2 "^v"
Start-Sleep -Seconds 2
$after = Cap
Write-Host "--- after paste ---"
Write-Host $after
Write-Host "--- end ---"

# Detect premature submit: pwsh raised CommandNotFound for the partial token
$prematureSubmit = ($after -match [regex]::Escape($token)) -and ($after -match "not recognized|CommandNotFound|is not recognized")
if ($prematureSubmit) {
    Write-Host "`n[BUG REPRODUCED] leading pasted newline submitted '$token' -> CommandNotFound" -ForegroundColor Red
} else {
    Write-Host "`n[NO PREMATURE SUBMIT] partial command not executed by the leading paste newline" -ForegroundColor Green
}

& $PSMUX kill-session -t $s 2>&1 | Out-Null
try { Stop-Process -Id $pid2 -Force -EA SilentlyContinue } catch {}
Write-Host "VERDICT prematureSubmit=$prematureSubmit"
