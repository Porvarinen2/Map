<#
  TESLES NPC OVERHAUL - diagnostics collector.

  Gathers everything needed to work out why the mod is quiet: the mod's own
  boot log, UE4SS's log, mods.txt, and the folder listings. Writes a zip next
  to this script.
#>
$ErrorActionPreference = "SilentlyContinue"
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$MOD = "TeslesNPCOverhaul"
. (Join-Path $here 'ue4ss_health.ps1')
function Say($t, $c = "Gray") { Write-Host "  $t" -ForegroundColor $c }

Write-Host ""
Write-Host "  TESLES NPC OVERHAUL - diagnostiikka" -ForegroundColor Yellow
Write-Host "  ==================================="
Write-Host ""

$stamp = Get-Date -Format "yyyyMMdd-HHmmss"
$tmp = Join-Path ([System.IO.Path]::GetTempPath()) "tesles_diag_$stamp"
New-Item -ItemType Directory -Path $tmp -Force | Out-Null

# --- locate the install ---
$pathFile = Join-Path $here 'livemap\livemap_paths.txt'
$out = $null
if (Test-Path $pathFile) { $out = (Get-Content $pathFile -First 1).Trim() }

$report = @()
$report += "TESLES NPC OVERHAUL diagnostics $stamp"
$report += "package folder : $here"
$report += "recorded output: $out"

if ($out) {
  $modRoot = Split-Path $out -Parent
  $modsDir = Split-Path $modRoot -Parent
  $report += "mod folder     : $modRoot"
  $report += "Mods folder    : $modsDir"

  $report += ""
  $report += "--- mod folder listing ---"
  if (Test-Path $modRoot) {
    Get-ChildItem $modRoot -Recurse -File | ForEach-Object {
      $report += ("{0,10}  {1}" -f $_.Length, $_.FullName.Substring($modRoot.Length + 1))
    }
  } else {
    $report += "MOD FOLDER MISSING"
  }

  $report += ""
  $report += "--- mods.txt ---"
  $modsTxt = Join-Path $modsDir 'mods.txt'
  if (Test-Path $modsTxt) {
    $report += (Get-Content $modsTxt)
    Copy-Item $modsTxt (Join-Path $tmp "mods.txt") -Force
  } else {
    $report += "mods.txt MISSING at $modsTxt"
  }

  foreach ($f in @("boot.log", "director.log", "events.tsv", "movement_debug.tsv", "last_engine_calls.txt", "live_state.json")) {
    $p = Join-Path $out $f
    if (Test-Path $p) {
      Copy-Item $p (Join-Path $tmp $f) -Force
      $report += ""
      $report += "--- $f (last 60 lines) ---"
      $report += (Get-Content $p -Tail 60)
    } else {
      $report += ""
      $report += "--- $f : MISSING ---"
    }
  }

  $world = Join-Path (Split-Path $out -Parent) 'state\world_state.json'
  if (Test-Path $world) {
    $report += ""
    $report += "world_state.json: $([math]::Round((Get-Item $world).Length/1KB,1)) KB, $((Get-Item $world).LastWriteTime)"
  } else {
    $report += ""
    $report += "world_state.json: not saved yet"
  }

  # --- UE4SS health: the mod cannot run if UE4SS never starts Lua mods ---
  $win64 = Split-Path $modsDir -Parent
  if ((Split-Path $win64 -Leaf) -eq 'ue4ss') { $win64 = Split-Path $win64 -Parent }
  $health = Get-UE4SSHealth $win64
  $report += ""
  $report += "=== UE4SS HEALTH: $($health.verdict) ==="
  $report += "win64            : $($health.win64)"
  $report += "version          : $($health.version)"
  $report += "UE4SS.dll        : $($health.ue4ssDll)"
  $report += "settings         : $($health.settings)"
  $report += "proxy dlls       : $($health.proxyDlls -join ', ')"
  $report += "log              : $($health.logPath)"
  $report += "log written      : $($health.logTime)  ($($health.logAgeMinutes) min ago)"
  $report += "server started   : $($health.serverStart)"
  $report += "log is this run  : $($health.logIsFromThisRun)"
  $report += "mods dir in log  : $($health.modsDirectoryInLog)"
  $report += "AOB scan attempts: $($health.scanAttempts)"
  $report += "last scan failure: $($health.scanFailure)"
  $report += "started lua mods : $($health.startedLuaMods -join ', ')"
  foreach ($m in $health.modsDirs) {
    $report += ("mods folder      : {0}  ({1} mods, mods.txt {2})" -f
                $m.path, $m.folders, $m.modsTxtTime)
  }
  if ($health.allLogs) {
    $report += "all logs found   :"
    foreach ($l in $health.allLogs) { $report += "  $l" }
  }
  $report += ""
  $report += "--- what to do ---"
  foreach ($a in $health.action) { $report += "  $a" }

  # Win64 listing: shows at a glance whether the loader is present at all.
  $report += ""
  $report += "--- Win64 root files ---"
  Get-ChildItem $win64 -File -ErrorAction SilentlyContinue |
    Sort-Object Name | ForEach-Object {
      $report += ("{0,12}  {1}  {2}" -f $_.Length, $_.LastWriteTime.ToString("yyyy-MM-dd"), $_.Name)
    }

  if ($health.settings -and (Test-Path $health.settings)) {
    Copy-Item $health.settings (Join-Path $tmp "UE4SS-settings.ini") -Force
  }

  # The server's own log is where a crash or a hung game thread is recorded.
  # Without it a freeze is just "it stopped".
  $serverRoot = Split-Path (Split-Path (Split-Path $win64 -Parent) -Parent) -Parent
  $scumLog = Get-ChildItem (Join-Path (Join-Path $serverRoot 'SCUM') 'Saved\Logs') `
                           -Filter '*.log' -File -ErrorAction SilentlyContinue |
             Sort-Object LastWriteTime -Descending | Select-Object -First 1
  if ($scumLog) {
    @(Get-Content $scumLog.FullName -Tail 1200) |
      Set-Content (Join-Path $tmp "SCUM_server.log") -Encoding UTF8
    $report += ""
    $report += "--- SCUM server log: crash / hang lines ---"
    $hits = @(Get-Content $scumLog.FullName |
              Where-Object { $_ -match 'Fatal error|Critical error|Hang detected|EXCEPTION_|Unhandled Exception|UE4SS\.dll' })
    if ($hits.Count -gt 0) {
      $report += ("{0}: {1} osumaa" -f $scumLog.Name, $hits.Count)
      $report += ($hits | Select-Object -First 40)
    } else {
      $report += ("{0}: ei kaatumisia lokissa" -f $scumLog.Name)
    }
  } else {
    $report += ""
    $report += "--- SCUM server log: ei loytynyt (SCUM\Saved\Logs) ---"
  }
  if ($health.logPath -and (Test-Path $health.logPath)) {
    # Copy a bounded slice; the scan loop makes these files enormous.
    $slice = @(Get-Content $health.logPath -TotalCount 200) +
             @("...") +
             @(Get-Content $health.logPath -Tail 200)
    $slice | Set-Content (Join-Path $tmp "UE4SS.log") -Encoding UTF8
    $report += ""
    $report += "--- UE4SS.log : lines mentioning Tesles ---"
    $hits = Select-String -Path $health.logPath -Pattern "Tesles" -SimpleMatch |
            Select-Object -Last 20 | ForEach-Object { $_.Line }
    if ($hits) { $report += $hits } else { $report += "  (none)" }
    $report += ""
    $report += "--- UE4SS.log first 30 lines ---"
    $report += (Get-Content $health.logPath -TotalCount 30)
    $report += ""
    $report += "--- UE4SS.log last 30 lines ---"
    $report += (Get-Content $health.logPath -Tail 30)
  }
} else {
  $report += "INSTALL.bat has not been run, or livemap_paths.txt was deleted."
}

$report += ""
$report += "--- livemap\map listing ---"
$mapDir = Join-Path $here 'livemap\map'
if (Test-Path $mapDir) {
  Get-ChildItem $mapDir -Recurse -File | Select-Object -First 40 | ForEach-Object {
    $report += ("{0,12}  {1}" -f $_.Length, $_.Name)
  }
} else {
  $report += "map folder MISSING"
}

$report += ""
$report += "--- environment ---"
$report += "PowerShell : $($PSVersionTable.PSVersion)"
$report += "OS         : $([System.Environment]::OSVersion.VersionString)"
$proc = Get-Process -Name "SCUMServer" -ErrorAction SilentlyContinue
$report += "SCUMServer : " + $(if ($proc) { "running (PID $($proc.Id))" } else { "not running" })

$reportPath = Join-Path $tmp "report.txt"
$report | Set-Content -Path $reportPath -Encoding UTF8

$zip = Join-Path $here "TeslesNPC_Diagnostics_$stamp.zip"
Compress-Archive -Path (Join-Path $tmp '*') -DestinationPath $zip -Force
Remove-Item $tmp -Recurse -Force

Say "Raportti: $zip" "Green"
if ($health) { Write-UE4SSHealth $health }
Say "Modin oma tila:" "Cyan"
$report | Where-Object { $_ -match "^--- (boot|director)\.log" } |
  ForEach-Object { Write-Host "    $_" }
Write-Host ""
Read-Host "  Enter sulkee"
