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
if ($fails -eq 0) { Write-Host "powershell tests passed" } else { Write-Host "$fails failures" -ForegroundColor Red }
exit $fails
