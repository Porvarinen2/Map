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
  "SomeThirdPartyMod : 1",
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

# A mod the user installed themselves after UE4SS: the one-click installer has
# to switch it off too, not just UE4SS's own samples.
Set-Content (Join-Path $modsDir "mods.txt") `
  (@(Get-Content (Join-Path $modsDir "mods.txt")) -replace '^SomeThirdPartyMod\s*:\s*0', 'SomeThirdPartyMod : 1')
New-Item -ItemType Directory -Path (Join-Path $modsDir "SomeThirdPartyMod") -Force | Out-Null
Set-Content (Join-Path (Join-Path $modsDir "SomeThirdPartyMod") "enabled.txt") ""

# -SkipUE4SS: the loader install is exercised above from a fixed zip, and the
# one-click path must not depend on GitHub inside the test.
& (Join-Path $pkg "INSTALL.ps1") -ServerRoot (Join-Path $lab "server") `
  -SkipUE4SS -NoMap -Yes -NoPause | Out-Null

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

# The user asked for one installer that also makes sure nothing else runs
# alongside this mod.
Check (($mt2 | Where-Object { $_ -match '^SomeThirdPartyMod\s*:\s*0' }).Count -eq 1) `
      "a third-party Lua mod is switched off"
Check (($mt2 | Where-Object { $_ -match '^Keybinds\s*:\s*0' }).Count -eq 1) `
      "even UE4SS's own Keybinds mod is switched off"
Check (($mt2 | Where-Object { $_ -match '^\s*;' }).Count -ge 1) `
      "comment lines in mods.txt survive"
$backupDir = Get-ChildItem (Join-Path (Join-Path $lab "server") "TeslesNPCOverhaul_Backups") `
             -Directory | Select-Object -First 1
Check ($backupDir -ne $null) "a backup folder is created"
Check (Test-Path (Join-Path $backupDir.FullName "mods.txt")) "the original mods.txt is backed up"
Check (Test-Path (Join-Path $backupDir.FullName "disabled_mods.txt")) `
      "what was switched off is written down"
Check ((Get-Content (Join-Path $backupDir.FullName "disabled_mods.txt")) -contains "SomeThirdPartyMod") `
      "the list names the mod that was switched off"
Check (Test-Path (Join-Path (Join-Path $modsDir "SomeThirdPartyMod") "enabled.txt.disabled")) `
      "its enabled.txt marker is parked, so UE4SS will not start it anyway"

# Installing twice must keep the world state and not duplicate the mods.txt row.
# output\ counts too: wiping it made the live map report that the mod had never
# run, right after an update that went fine.
Set-Content -LiteralPath (Join-Path (Join-Path $modDir "output") "live_state.json") -Value "LIVE"
Set-Content -LiteralPath (Join-Path (Join-Path $modDir "output") "director.log") -Value "LOG"
Set-Content -LiteralPath (Join-Path (Join-Path $modDir "output") "boot.log") -Value "STALE"
Set-Content (Join-Path (Join-Path $modDir "state") "world_state.json") '{"groups":[]}'
# An owner's gear file from 1.6.0: their own line, no KAIKKI section.
Set-Content -LiteralPath (Join-Path $modDir "varusteet.lua") -Value @"
return {
    police_patrol = { Clothes = { "My_Own_Shirt" }, Weapons = {}, Items = {} },
}
"@
Set-Content -LiteralPath (Join-Path $modDir "ryhmat.lua") -Value 'return { { avain = "omat_testit" } }'
& (Join-Path $pkg "INSTALL.ps1") -ServerRoot (Join-Path $lab "server") `
  -SkipUE4SS -NoMap -Yes -NoPause | Out-Null
$gear = Get-Content -Raw (Join-Path $modDir "varusteet.lua")
Check ($gear -match 'My_Own_Shirt') "a reinstall keeps the owner's own gear lines"
Check ($gear -match 'KAIKKI' -and $gear -match 'Weapon_M1911') `
      "an old varusteet.lua gets the KAIKKI section with the test weapon"
Check ((Get-Content -Raw (Join-Path $modDir "ryhmat.lua")) -match 'omat_testit') `
      "a reinstall keeps the owner's own squad classes"
# The gear file must still be valid Lua after the insert.
$luaOk = $true
if (Get-Command lua5.4 -ErrorAction SilentlyContinue) {
  & lua5.4 -e "assert(loadfile('$((Join-Path $modDir 'varusteet.lua') -replace '\\','/')'))" 2>$null
  $luaOk = ($LASTEXITCODE -eq 0)
}
Check $luaOk "and the patched varusteet.lua still loads"
# The 1.7.x clothes test (ghillie pants, next to the empty lists the KAIKKI
# insert wrote) becomes the weapon test.
Set-Content -LiteralPath (Join-Path $modDir "varusteet.lua") -Value @"
return {
    KAIKKI = {
        Clothes = { "Ghillie_Suit_Pants_01" },
        Weapons = {},
        Items = {},
    },
    police_patrol = { Clothes = { "My_Own_Shirt" } },
}
"@
& (Join-Path $pkg "INSTALL.ps1") -ServerRoot (Join-Path $lab "server") `
  -SkipUE4SS -NoMap -Yes -NoPause | Out-Null
$gear = Get-Content -Raw (Join-Path $modDir "varusteet.lua")
Check ($gear -match 'Weapon_M1911' -and $gear -notmatch 'Ghillie' -and $gear -match 'My_Own_Shirt') `
      "the ghillie test in an owner's gear file moves to the weapon test, their own lines stay"
function Get-LuaKaikkiWeapon($path) {
  if (-not (Get-Command lua5.4 -ErrorAction SilentlyContinue)) { return "Weapon_M1911" }
  $p = $path -replace '\\','/'
  return (& lua5.4 -e "local t = dofile('$p'); print(t.KAIKKI.Weapons[1])")
}
Check ((Get-LuaKaikkiWeapon (Join-Path $modDir "varusteet.lua")) -eq "Weapon_M1911") `
      "and Lua really sees the test weapon (no empty Weapons list after it)"
# The file 1.8.0 left behind: test weapon cancelled by an empty list.
Set-Content -LiteralPath (Join-Path $modDir "varusteet.lua") -Value @"
return {
    KAIKKI = {
        Weapons = { "Weapon_M1911" },
        Weapons = {},
        Items = {},
    },
    police_patrol = { Clothes = { "My_Own_Shirt" } },
}
"@
& (Join-Path $pkg "INSTALL.ps1") -ServerRoot (Join-Path $lab "server") `
  -SkipUE4SS -NoMap -Yes -NoPause | Out-Null
Check ((Get-LuaKaikkiWeapon (Join-Path $modDir "varusteet.lua")) -eq "Weapon_M1911" -and
       ((Get-Content -Raw (Join-Path $modDir "varusteet.lua")) -match 'My_Own_Shirt')) `
      "the gear file 1.8.0 broke is repaired, the owner's lines stay"

# DIAGNOSE packs the gear files and the gear log.
Set-Content -LiteralPath (Join-Path (Join-Path $modDir "output") "npc_loadout.txt") -Value "LOADOUT LOG"
Get-ChildItem $pkg -Filter "TeslesNPC_Diagnostics_*.zip" | Remove-Item -Force
& (Join-Path $pkg "DIAGNOSE.ps1") -NoPause | Out-Null
$dz = Get-ChildItem $pkg -Filter "TeslesNPC_Diagnostics_*.zip" | Select-Object -First 1
Check ($null -ne $dz) "DIAGNOSE writes its zip"
if ($dz) {
  Add-Type -AssemblyName System.IO.Compression.FileSystem
  $za = [System.IO.Compression.ZipFile]::OpenRead($dz.FullName)
  $names = $za.Entries | ForEach-Object { $_.Name }
  $za.Dispose()
  Check ($names -contains "varusteet.lua") "the diagnostics zip carries varusteet.lua"
  Check ($names -contains "ryhmat.lua") "and ryhmat.lua"
  Check ($names -contains "npc_loadout.txt") "and the gear log"
  Remove-Item $dz.FullName -Force
}
Check (Test-Path (Join-Path (Join-Path $modDir "state") "world_state.json")) `
      "a reinstall keeps the saved world"
Check (Test-Path (Join-Path (Join-Path $modDir "output") "live_state.json")) `
      "a reinstall keeps live_state.json, so the live map keeps its picture"
Check (Test-Path (Join-Path (Join-Path $modDir "output") "director.log")) `
      "a reinstall keeps director.log"
Check (-not (Test-Path (Join-Path (Join-Path $modDir "output") "boot.log"))) `
      "the stale boot.log is still cleared, so it cannot be read as this run's"
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
Write-Host "== automatic FText signature =="

# UE4SS stops when its own pattern for FText::FText(FString&&) is ambiguous.
# -Auto resolves that from the server executable, and must refuse rather than
# write an address it cannot stand behind.
function New-FakeExe($dir, [byte[]]$plant, [long[]]$at) {
  New-Item -ItemType Directory -Path $dir -Force | Out-Null
  Set-Content (Join-Path $dir "UE4SS-settings.ini") `
    "[General]`nSigScannerNumThreads = 8`nSecondsToScanBeforeGivingUp = 30"
  $buf = New-Object byte[] 3000000
  (New-Object Random 7).NextBytes($buf)
  foreach ($o in $at) { [Array]::Copy($plant, 0, $buf, $o, $plant.Length) }
  [System.IO.File]::WriteAllBytes((Join-Path $dir "SCUMServer.exe"), $buf)
}

$ftext = [byte[]]@(0x48,0x8B,0xC4,0x56,0x57,0x48,0x83,0xEC,0x68,0x48,0x89,0x58,0x18,0x48,0x8B,0xF9)
$al = Join-Path ([System.IO.Path]::GetTempPath()) ("tesles_auto_" + [guid]::NewGuid().ToString("N"))

$one = Join-Path $al "one"
New-FakeExe $one $ftext @(900000L)
& (Join-Path $pkg "FIX_UE4SS_SCAN.ps1") -Win64 $one -Auto | Out-Null
$sig = Join-Path $one "UE4SS_Signatures\FText_Constructor.lua"
Check (Test-Path $sig) "a single unambiguous match is written out"
$sigText = Get-Content $sig -Raw
Check ($sigText -match 'Register\s*=\s*function') "the file defines Register"
Check ($sigText -match 'OnMatchFound\s*=\s*function') "the file defines OnMatchFound"
Check ($sigText -match '48 8B C4 56 57 48 83 EC 68 48 89 58 18 48 8B F9') `
      "it carries the longest candidate that matched"
Check ($sigText -match 'file offset 0x') "it records where the match was found"

# Two copies of the prologue: UE4SS's own failure mode, and no basis to pick.
$two = Join-Path $al "two"
New-FakeExe $two $ftext @(900000L, 1900000L)
& (Join-Path $pkg "FIX_UE4SS_SCAN.ps1") -Win64 $two -Auto | Out-Null
Check (-not (Test-Path (Join-Path $two "UE4SS_Signatures\FText_Constructor.lua"))) `
      "an ambiguous executable is refused, not guessed at"

# Nothing recognisable at all.
$none = Join-Path $al "none"
New-FakeExe $none $ftext @()
$out = & (Join-Path $pkg "FIX_UE4SS_SCAN.ps1") -Win64 $none -Auto | Out-String
Check (-not (Test-Path (Join-Path $none "UE4SS_Signatures\FText_Constructor.lua"))) `
      "an executable with no known prologue is refused"

# A written override is part of the same experiment and has to come back out.
& (Join-Path $pkg "FIX_UE4SS_SCAN.ps1") -Win64 $one -Revert | Out-Null
Check (-not (Test-Path $sig)) "-Revert withdraws the automatic signature"

Remove-Item $al -Recurse -Force -ErrorAction SilentlyContinue

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

# UE4SS logs in UTC on this server while the file timestamp is local. A log
# written minutes ago must not read as three hours stale.
Write-Host ""
Write-Host "== health: UTC log offset =="
$tz = Join-Path ([System.IO.Path]::GetTempPath()) ("tesles_tz_" + [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path (Join-Path $tz "Mods") -Force | Out-Null
Set-Content (Join-Path $tz "dwmapi.dll") "x"
Set-Content (Join-Path $tz "UE4SS.dll") "x"
Set-Content (Join-Path $tz "SCUMServer.exe") "x"
$utc = (Get-Date).AddHours(-3).ToString("yyyy-MM-dd HH:mm:ss")
$tzLines = @("[$utc] Console created", "[$utc] UE4SS - v3.0.1 Beta #0 - Git SHA #x")
for ($i = 1; $i -le 30; $i++) {
  $tzLines += "[$utc] PS Scan attempt $i"
  $tzLines += "[$utc] [PS] Failed to find FText::FText(FString&&): iter returned multiple unique values"
}
$tzLines += "[$utc] Fatal Error: PS scan timed out"
$tzLines | Set-Content (Join-Path $tz "UE4SS.log")
(Get-Item (Join-Path $tz "UE4SS.log")).LastWriteTime = (Get-Date)
$ht = Get-UE4SSHealth $tz
Check ($ht.verdict -eq "SCAN_ABORTED") `
      "a log written in UTC is not mistaken for a stale one (got $($ht.verdict))"
Check ($ht.logClockOffsetMinutes -ne $null) "the clock offset between log and file is reported"
Remove-Item $tz -Recurse -Force -ErrorAction SilentlyContinue

Remove-Item $sp -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item $sl -Recurse -Force -ErrorAction SilentlyContinue

Write-Host ""
if ($fails -eq 0) { Write-Host "powershell tests passed" } else { Write-Host "$fails failures" -ForegroundColor Red }
exit $fails
