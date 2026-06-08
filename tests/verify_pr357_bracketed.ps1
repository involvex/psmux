# Definitive PR #357 proof using a bracketed-paste-enabled reader (the real target:
# Copilot CLI / Claude Code). Type partial text, then paste clipboard that STARTS
# with a newline. With the fix, the child must receive the paste wrapped as
# ESC[200~ ... 0A ... ESC[201~ (the leading newline INSIDE the bracket) and NO
# premature standalone 0x0D/0x0A before the ESC[200~ opener.
$ErrorActionPreference = "Continue"
$PSMUX = (Get-Command psmux -EA Stop).Source
$inj = "$env:TEMP\psmux_injector.exe"
$psmuxDir = "$env:USERPROFILE\.psmux"
$childExe = "$env:TEMP\psmux_brackpaste.exe"
$logFile = "$env:TEMP\psmux_brackpaste.txt"
$s = "pr357b"
$pass=0;$fail=0
function Ok($m){$script:pass++;Write-Host "  [PASS] $m" -ForegroundColor Green}
function Bad($m){$script:fail++;Write-Host "  [FAIL] $m" -ForegroundColor Red}

$csc = "C:\Windows\Microsoft.NET\Framework64\v4.0.30319\csc.exe"
& $csc /nologo /out:$childExe "C:\Users\godwin\Documents\workspace\psmux\tests\brackpaste_child.cs" 2>&1 | Out-Null
if (-not (Test-Path $childExe)) { Write-Host "[FATAL] child build failed" -ForegroundColor Red; exit 2 }

& $PSMUX kill-server 2>&1 | Out-Null
Get-Process psmux,nvim,psmux_brackpaste -EA SilentlyContinue | Stop-Process -Force -EA SilentlyContinue
Start-Sleep -Seconds 2
Remove-Item $logFile -Force -EA SilentlyContinue

$p = Start-Process -FilePath $PSMUX -ArgumentList @("new-session","-s",$s,$childExe) -PassThru
Start-Sleep -Seconds 5
$pid2 = $p.Id

Set-Clipboard -Value "`nTAIL357TEXT"
Start-Sleep -Milliseconds 400
# type partial text (plain letters) so child has 'pending input'
& $inj $pid2 "zzqpartial"
Start-Sleep -Milliseconds 500
# paste
& $inj $pid2 "^v"
Start-Sleep -Seconds 2
# end the child
& $inj $pid2 "^z"
Start-Sleep -Milliseconds 500

$log = Get-Content $logFile -Raw -EA SilentlyContinue
Write-Host "--- brackpaste child received ---"
Write-Host $log
Write-Host "--- end ---"

# Normalize to a single hex stream
$hex = (($log -split "`n" | Where-Object { $_ -match "^0x" }) -join " ")
# bracket opener ESC[200~ = 1B 5B 32 30 30 7E ; closer ESC[201~ = 1B 5B 32 30 31 7E
$hasOpen  = $hex -match "0x1B 0x5B 0x32 0x30 0x30 0x7E"
$hasClose = $hex -match "0x1B 0x5B 0x32 0x30 0x31 0x7E"
$hasNL    = $hex -match "0x0D|0x0A"
# leading newline (CR 0x0D or LF 0x0A) immediately INSIDE the bracket opener
$nlInside = $hex -match "0x1B 0x5B 0x32 0x30 0x30 0x7E( 0x[0-9A-F]{2})* 0x0[DA]"
# premature: a standalone CR/LF appearing BEFORE the opener
$beforeOpener = if ($hasOpen) { ($hex -split "0x1B 0x5B 0x32 0x30 0x30 0x7E")[0] } else { $hex }
$prematureEnter = ($beforeOpener -match "0x0D|0x0A")

if ($hasOpen -and $hasClose) { Ok "paste delivered as bracketed paste (ESC[200~ ... ESC[201~)" } else { Bad "no bracketed paste wrapper (open=$hasOpen close=$hasClose)" }
if ($nlInside) { Ok "leading newline (0x0A) delivered INSIDE the bracket" } elseif ($hasNL) { Bad "newline present but not clearly inside bracket" } else { Bad "no newline byte seen" }
if (-not $prematureEnter) { Ok "NO premature standalone Enter before the paste opener" } else { Bad "premature Enter/CR before paste opener (bug)" }

& $PSMUX kill-session -t $s 2>&1 | Out-Null
try { Stop-Process -Id $pid2 -Force -EA SilentlyContinue } catch {}
Get-Process psmux_brackpaste -EA SilentlyContinue | Stop-Process -Force -EA SilentlyContinue
Write-Host "`n=== RESULT: $pass passed, $fail failed ===" -ForegroundColor $(if($fail){"Red"}else{"Green"})
exit $fail
