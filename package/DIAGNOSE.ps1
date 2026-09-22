<#
  TESLES NPC OVERHAUL - diagnostics collector.

  Gathers everything needed to work out why the mod is quiet: the mod's own
  boot log, UE4SS's log, mods.txt, and the folder listings. Writes a zip next
  to this script.
#>
$ErrorActionPreference = "SilentlyContinue"
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$MOD = "TeslesNPCOverhaul"
function Say($t, $c = "Gray") { Write-Host "  $t" -ForegroundColor $c }

Write-Host ""
Write-Host "  TESLES NPC OVERHAUL - diagnostiikka" -ForegroundColor Yellow
Write-Host "  ==================================="
Write-Host ""

$stamp = Get-Date -Format "yyyyMMdd-HHmmss"
$tmp = Join-Path $env:TEMP "tesles_diag_$stamp"
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

  foreach ($f in @("boot.log", "director.log", "events.tsv", "movement_debug.tsv")) {
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

  # UE4SS's own log sits beside the Mods folder or one level up.
  $ue4ssCandidates = @(
    (Join-Path $modsDir '..\UE4SS.log'),
    (Join-Path $modsDir 'UE4SS.log'),
    (Join-Path $modsDir '..\ue4ss\UE4SS.log')
  )
  foreach ($c in $ue4ssCandidates) {
    if (Test-Path $c) {
      $full = (Resolve-Path $c).Path
      Copy-Item $full (Join-Path $tmp "UE4SS.log") -Force
      $report += ""
      $report += "--- UE4SS.log ($full) : lines mentioning Tesles ---"
      $report += (Select-String -Path $full -Pattern "Tesles" -SimpleMatch |
                  Select-Object -Last 40 | ForEach-Object { $_.Line })
      $report += ""
      $report += "--- UE4SS.log last 40 lines ---"
      $report += (Get-Content $full -Tail 40)
      break
    }
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
Write-Host ""
Say "Tarkeimmat kohdat:" "Cyan"
$report | Where-Object { $_ -match "MISSING|boot.log|mods.txt|Tesles" } |
  Select-Object -First 25 | ForEach-Object { Write-Host "    $_" }
Write-Host ""
Read-Host "  Enter sulkee"
