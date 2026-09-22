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
Write-Host "== clean server install =="

# A wiped SCUM server: no UE4SS at all. The installer has to put UE4SS in
# place from a release archive and then install the mod into it.
$lab = Join-Path ([System.IO.Path]::GetTempPath()) ("tesles_lab_" + [guid]::NewGuid().ToString("N"))
$win64 = Join-Path (Join-Path (Join-Path (Join-Path $lab "server") "SCUM") "Binaries") "Win64"
New-Item -ItemType Directory -Path $win64 -Force | Out-Null
Set-Content (Join-Path $win64 "SCUMServer.exe") "fake"

# Build a release archive with the layout UE4SS actually ships.
$src = Join-Path $lab "src"
$srcMods = Join-Path $src "Mods"
New-Item -ItemType Directory -Path (Join-Path $srcMods "ConsoleCommandsMod") -Force | Out-Null
Set-Content (Join-Path $src "dwmapi.dll") "proxy"
Set-Content (Join-Path $src "UE4SS.dll") "loader"
Set-Content (Join-Path $src "UE4SS-settings.ini") "[General]"
Set-Content (Join-Path $srcMods "mods.txt") @(
  "CheatManagerEnablerMod : 1", "ConsoleCommandsMod : 1", "ActorDumperMod : 0",
  "", "; Built-in keybinds, do not move up!", "Keybinds : 1")
Set-Content (Join-Path (Join-Path $srcMods "ConsoleCommandsMod") "enabled.txt") ""
$relZip = Join-Path $lab "UE4SS_v9.9.9.zip"
Compress-Archive -Path (Join-Path $src "*") -DestinationPath $relZip -Force

& (Join-Path $pkg "INSTALL_UE4SS.ps1") -Win64 $win64 -ZipFile $relZip -Yes | Out-Null

Check (Test-Path (Join-Path $win64 "UE4SS.dll")) "UE4SS.dll installed on a clean server"
Check (Test-Path (Join-Path $win64 "dwmapi.dll")) "the proxy DLL is installed"
$modsDir = Join-Path $win64 "Mods"
Check (Test-Path (Join-Path $modsDir "mods.txt")) "mods.txt is in place"
$mt = Get-Content (Join-Path $modsDir "mods.txt")
Check (($mt | Where-Object { $_ -match '^ConsoleCommandsMod\s*:\s*0' }).Count -eq 1) `
      "UE4SS's own sample mods are switched off"
Check (($mt | Where-Object { $_ -match '^Keybinds\s*:\s*1' }).Count -eq 1) `
      "the built-in Keybinds entry is left enabled"
Check (Test-Path (Join-Path (Join-Path $modsDir "ConsoleCommandsMod") "enabled.txt.disabled")) `
      "a sample mod's enabled.txt marker is parked"
Check (-not (Test-Path (Join-Path (Join-Path $modsDir "ConsoleCommandsMod") "enabled.txt"))) `
      "the live marker is gone, so UE4SS will not start it anyway"

& (Join-Path $pkg "INSTALL.ps1") -ServerRoot (Join-Path $lab "server") -Yes -NoPause | Out-Null

$modDir = Join-Path $modsDir "TeslesNPCOverhaul"
Check (Test-Path (Join-Path (Join-Path $modDir "Scripts") "main.lua")) "the mod's entry point is installed"
Check (Test-Path (Join-Path $modDir "config.lua")) "config.lua is installed"
Check (Test-Path (Join-Path $modDir "output")) "the output folder exists"
Check (Test-Path (Join-Path $modDir "enabled.txt")) "the mod's own enabled.txt is written"
$mt2 = Get-Content (Join-Path $modsDir "mods.txt")
Check (($mt2 | Where-Object { $_ -match '^TeslesNPCOverhaul\s*:\s*1' }).Count -eq 1) `
      "the mod is registered in mods.txt exactly once"
Check ((Get-ChildItem $modDir -Recurse -File).Count -ge 30) `
      "the whole mod tree is copied ($((Get-ChildItem $modDir -Recurse -File).Count) files)"
Check (Test-Path (Join-Path (Join-Path $pkg "livemap") "livemap_paths.txt")) `
      "the live map is pointed at the mod's output folder"

# Installing twice must keep the world state and not duplicate the mods.txt row.
Set-Content (Join-Path (Join-Path $modDir "state") "world_state.json") '{"groups":[]}'
& (Join-Path $pkg "INSTALL.ps1") -ServerRoot (Join-Path $lab "server") -Yes -NoPause | Out-Null
Check (Test-Path (Join-Path (Join-Path $modDir "state") "world_state.json")) `
      "a reinstall keeps the saved world"
$mt3 = Get-Content (Join-Path $modsDir "mods.txt")
Check (($mt3 | Where-Object { $_ -match '^TeslesNPCOverhaul\s*:' }).Count -eq 1) `
      "a reinstall does not duplicate the mods.txt row"

. (Join-Path $pkg "ue4ss_health.ps1")
$h4 = Get-UE4SSHealth $win64
Check ($h4.verdict -eq "NO_LOG") "a server that has not been started yet reports NO_LOG"
Check ($h4.ue4ssDll) "the health check finds the installed loader"

Remove-Item $lab -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item (Join-Path (Join-Path $pkg "livemap") "livemap_paths.txt") -Force -ErrorAction SilentlyContinue

Write-Host ""
Write-Host "== scan workaround =="

# UE4SS aborts its own startup when the pattern scan is ambiguous. The
# workaround is a settings change, so it has to be exact and reversible.
$sl = Join-Path ([System.IO.Path]::GetTempPath()) ("tesles_scan_" + [guid]::NewGuid().ToString("N"))
$sw = Join-Path (Join-Path (Join-Path (Join-Path $sl "SCUM") "Binaries") "Win64") ""
New-Item -ItemType Directory -Path (Join-Path $sw "Mods\cache") -Force | Out-Null
Set-Content (Join-Path $sw "SCUMServer.exe") "x"
Set-Content (Join-Path $sw "Mods\cache\aob.cache") "stale"
Copy-Item (Join-Path $here "fixtures\ue4ss_settings.ini") (Join-Path $sw "UE4SS-settings.ini")

& (Join-Path $pkg "FIX_UE4SS_SCAN.ps1") -Win64 $sw -ServerTuning | Out-Null
$ini = Get-Content (Join-Path $sw "UE4SS-settings.ini")
function IniVal($lines, $key) {
  foreach ($l in $lines) {
    if ($l -match "^\s*$([regex]::Escape($key))\s*=\s*(.*)$") { return $Matches[1].Trim() }
  }
  return $null
}
Check ((IniVal $ini "SigScannerNumThreads") -eq "1") "the scanner is switched to a single thread"
Check ((IniVal $ini "SecondsToScanBeforeGivingUp") -eq "120") "the scan deadline is raised"
Check ((IniVal $ini "SigScannerMultithreadingModuleSizeThreshold") -eq "2000000000") `
      "multi-threading stays off, without sitting on the uint32 ceiling"
Check ((IniVal $ini "GuiConsoleEnabled") -eq "0") "-ServerTuning turns the debug GUI off"
Check (-not (Test-Path (Join-Path $sw "Mods\cache"))) "the stale AOB cache is moved out of the way"
Check (Test-Path (Join-Path $sw "Mods\cache.tesles-backup")) "the cache is kept, not deleted"
Check (Test-Path (Join-Path $sw "UE4SS-settings.ini.tesles-backup")) "the original settings are backed up"
Check (($ini | Where-Object { $_ -match "^;" }).Count -gt 20) "comments in the ini survive the rewrite"

# The health check must notice the workaround is in place and stop recommending it.
. (Join-Path $pkg "ue4ss_health.ps1")
Copy-Item (Join-Path $here "fixtures\ue4ss_scan_loop.log") (Join-Path $sw "UE4SS.log")
Set-Content (Join-Path $sw "dwmapi.dll") "x"
$hs = Get-UE4SSHealth $sw
Check ($hs.scanThreads -eq 1) "the health check reads the scanner thread count"
Check ($hs.scanFixApplied) "the health check sees that the workaround was applied"
Check ((($hs.action -join " ") -notmatch "1\. FIX_UE4SS_SCAN")) `
      "it no longer offers a workaround that was already tried"

& (Join-Path $pkg "FIX_UE4SS_SCAN.ps1") -Win64 $sw -Revert | Out-Null
$ini2 = Get-Content (Join-Path $sw "UE4SS-settings.ini")
Check ((IniVal $ini2 "SigScannerNumThreads") -eq "8") "revert restores the original thread count"
Check ((IniVal $ini2 "SecondsToScanBeforeGivingUp") -eq "30") "revert restores the original deadline"
Check (-not (Test-Path (Join-Path $sw "UE4SS-settings.ini.tesles-backup"))) `
      "revert removes its own backup"
Check (Test-Path (Join-Path $sw "Mods\\cache")) "revert puts the AOB cache back"
Check (-not (Test-Path (Join-Path $sw "Mods\\cache.tesles-backup"))) "revert cleans up its cache copy"

# A signature override must be written in the shape UE4SS loads.
& (Join-Path $pkg "FIX_UE4SS_SCAN.ps1") -Win64 $sw -Signature "FText_Constructor" -Aob "48 89 5C 24 ??" | Out-Null
$sigFile = Join-Path (Join-Path $sw "UE4SS_Signatures") "FText_Constructor.lua"
Check (Test-Path $sigFile) "a signature override is written where UE4SS looks for it"
if (Test-Path $sigFile) {
  $sig = Get-Content $sigFile -Raw
  Check ($sig -match "Register\s*=\s*function") "it defines Register"
  Check ($sig -match "OnMatchFound\s*=\s*function") "it defines OnMatchFound"
  Check ($sig -match "48 89 5C 24 \?\?") "it carries the given byte pattern"
}

# Revert must also withdraw a signature override this tool wrote.
& (Join-Path $pkg "FIX_UE4SS_SCAN.ps1") -Win64 $sw -Revert | Out-Null
Check (-not (Test-Path $sigFile)) "revert withdraws the signature override too"

Write-Host ""
Write-Host "== health: scan in progress =="

# A scan that has not finished is not a failure. With one thread and a raised
# deadline it legitimately takes minutes, and CHECK must not call that broken.
$sp = Join-Path ([System.IO.Path]::GetTempPath()) ("tesles_scanning_" + [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path (Join-Path $sp "Mods") -Force | Out-Null
Set-Content (Join-Path $sp "dwmapi.dll") "x"
Set-Content (Join-Path $sp "UE4SS.dll") "x"
$now = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
$scanLines = @(
  "[$now] Console created",
  "[$now] UE4SS - v3.0.1 Beta #0 - Git SHA #d935b5b",
  "[$now] mods directory: C:\Game\Win64\Mods")
for ($i = 1; $i -le 40; $i++) {
  $scanLines += "[$now] PS Scan attempt $i"
  $scanLines += "[$now] [PS] Starting scan"
  $scanLines += "[$now] [PS] Failed to find FText::FText(FString&&): iter returned multiple unique values"
  $scanLines += "[$now] [PS] Scan failed"
}
$scanLines | Set-Content (Join-Path $sp "UE4SS.log")
$hs2 = Get-UE4SSHealth $sp
Check ($hs2.verdict -eq "SCANNING") "an unfinished scan reports SCANNING, not a failure (got $($hs2.verdict))"
Check ((($hs2.action -join " ") -match "Odota")) "the advice says to wait, not to change anything"
Check ($hs2.logLastEntry -ne $null) "the last timestamp is read from inside the log"

# The same log with the fatal line appended is a failure again.
Add-Content (Join-Path $sp "UE4SS.log") "[$now] Fatal Error: PS scan timed out"
$hs3 = Get-UE4SSHealth $sp
Check ($hs3.verdict -eq "SCAN_ABORTED") "once UE4SS aborts, the verdict changes (got $($hs3.verdict))"

Remove-Item $sp -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item $sl -Recurse -Force -ErrorAction SilentlyContinue

Write-Host ""
if ($fails -eq 0) { Write-Host "powershell tests passed" } else { Write-Host "$fails failures" -ForegroundColor Red }
exit $fails
