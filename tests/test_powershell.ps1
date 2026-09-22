# Parses every shipped PowerShell script and exercises the UE4SS health check
# against a captured log from a server where UE4SS never reached mod loading.
$ErrorActionPreference = "Stop"
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$pkg = Join-Path (Split-Path $here -Parent) "package"
$fails = 0

function Check($cond, $msg) {
  if ($cond) { Write-Host "  ok  $msg" }
  else { Write-Host "FAIL: $msg" -ForegroundColor Red; $script:fails++ }
}

Write-Host "== powershell parse =="
$scripts = Get-ChildItem $pkg -Recurse -Filter *.ps1
foreach ($f in $scripts) {
  $errors = $null; $tokens = $null
  [System.Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$tokens, [ref]$errors) | Out-Null
  Check (-not $errors -or $errors.Count -eq 0) "$($f.Name) parses"
  if ($errors) { $errors | ForEach-Object { Write-Host "      line $($_.Extent.StartLineNumber): $($_.Message)" } }
}
Check ($scripts.Count -ge 7) "$($scripts.Count) scripts found"

Write-Host ""
Write-Host "== ue4ss health =="
. (Join-Path $pkg "ue4ss_health.ps1")

# A server stuck in the AOB scan loop: the log never reaches mod loading.
$fake = Join-Path ([System.IO.Path]::GetTempPath()) ("tesles_ue4ss_" + [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path (Join-Path $fake "Mods\TeslesNPCOverhaul\Scripts") -Force | Out-Null
Copy-Item (Join-Path $here "fixtures\ue4ss_scan_loop.log") (Join-Path $fake "UE4SS.log")
"TeslesNPCOverhaul : 1" | Set-Content (Join-Path $fake "Mods\mods.txt")
New-Item -ItemType File -Path (Join-Path $fake "dwmapi.dll") -Force | Out-Null
New-Item -ItemType File -Path (Join-Path $fake "UE4SS.dll") -Force | Out-Null

$h = Get-UE4SSHealth $fake
Check ($h.verdict -eq "SCAN_LOOP") "a stuck pattern scan is reported as SCAN_LOOP (got $($h.verdict))"
Check ($h.scanAttempts -ge 100) "the scan attempt count is read back ($($h.scanAttempts))"
Check ($h.version -eq "v3.0.1") "the UE4SS version is read from the log ($($h.version))"
Check ($h.scanFailure -like "*FText*") "the failing signature is named"
Check ($h.action.Count -ge 3) "the verdict comes with what to do"
Check ($h.proxyDlls.Count -ge 1) "the proxy DLL is detected"
Check ($h.modsDirs.Count -eq 1) "the Mods folder is found"

# No log at all.
$empty = Join-Path ([System.IO.Path]::GetTempPath()) ("tesles_ue4ss_" + [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $empty -Force | Out-Null
$h2 = Get-UE4SSHealth $empty
Check ($h2.verdict -eq "NO_LOG") "a missing log is reported as NO_LOG (got $($h2.verdict))"
Check (($h2.action -join " ") -like "*proxy-DLL*") "a missing loader is named as the likely cause"

# A healthy server that started the mod.
$good = Join-Path ([System.IO.Path]::GetTempPath()) ("tesles_ue4ss_" + [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path (Join-Path $good "Mods") -Force | Out-Null
@(
  "[2026-09-22 10:00:00] UE4SS - v3.1.0 - Git SHA #abc",
  "[2026-09-22 10:00:00] mods directory: C:\Game\Win64\Mods",
  "[2026-09-22 10:00:01] Starting Lua mod 'TeslesNPCOverhaul'",
  "[2026-09-22 10:00:01] Starting Lua mod 'ConsoleCommandsMod'"
) | Set-Content (Join-Path $good "UE4SS.log")
New-Item -ItemType File -Path (Join-Path $good "dwmapi.dll") -Force | Out-Null
$h3 = Get-UE4SSHealth $good
Check ($h3.verdict -eq "MOD_STARTED") "a working server is reported as MOD_STARTED (got $($h3.verdict))"
Check ($h3.startedLuaMods -contains "TeslesNPCOverhaul") "the started mod is listed"
Check ($h3.version -eq "v3.1.0") "the version is read ($($h3.version))"

Remove-Item $fake, $empty, $good -Recurse -Force -ErrorAction SilentlyContinue

Write-Host ""
if ($fails -eq 0) { Write-Host "powershell tests passed" } else { Write-Host "$fails failures" -ForegroundColor Red }
exit $fails
