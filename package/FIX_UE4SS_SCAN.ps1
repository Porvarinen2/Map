<#
  TESLES NPC OVERHAUL - UE4SS pattern-scan workaround.

  When UE4SS aborts with

    [PS] Failed to find FText::FText(FString&&): iter returned multiple unique values
    Fatal Error: PS scan timed out

  it never loads a single Lua mod. UE4SS scans the game binary with several
  threads by default; each thread scans its own block, and a pattern sitting
  on a block boundary can be reported more than once at slightly different
  offsets. That is one way the scanner ends up with "multiple unique values"
  and refuses to choose.

  This switches the scanner to a single thread and gives it more time, both of
  which are plain settings changes. It is a hypothesis worth one server start,
  not a guaranteed fix: if the pattern genuinely matches several places in
  SCUMServer.exe, only a newer UE4SS or an explicit signature will help.

  Everything is backed up and -Revert puts it back.
#>
param(
  [string]$Win64 = "",
  [switch]$Revert,
  [switch]$ServerTuning,   # also turn off the debug GUI console (headless server)
  [int]$ScanSeconds = 120,
  [string]$Signature = "", # e.g. FText_Constructor
  [string]$Aob = ""        # byte pattern for -Signature, if you have one
)

$ErrorActionPreference = "Stop"
function Say($t, $c = "Gray") { Write-Host "  $t" -ForegroundColor $c }

function Find-ServerWin64 {
  foreach ($c in @(
    'F:\SteamLibrary\steamapps\common\SCUM Server',
    'D:\SteamLibrary\steamapps\common\SCUM Server',
    'E:\SteamLibrary\steamapps\common\SCUM Server',
    'C:\SteamLibrary\steamapps\common\SCUM Server',
    'C:\Program Files (x86)\Steam\steamapps\common\SCUM Server',
    'C:\Program Files\Steam\steamapps\common\SCUM Server')) {
    $p = Join-Path $c 'SCUM\Binaries\Win64'
    if (Test-Path (Join-Path $p 'SCUMServer.exe') -ErrorAction SilentlyContinue) { return $p }
  }
  return $null
}

# Rewrites "Key = value" in place, keeping comments and order intact.
function Set-IniValue {
  param([string[]]$Lines, [string]$Key, [string]$Value)
  $done = $false
  $out = foreach ($l in $Lines) {
    if (-not $done -and $l -match "^\s*$([regex]::Escape($Key))\s*=") {
      $done = $true
      "$Key = $Value"
    } else { $l }
  }
  return @{ lines = @($out); changed = $done }
}

function Get-IniValue {
  param([string[]]$Lines, [string]$Key)
  foreach ($l in $Lines) {
    if ($l -match "^\s*$([regex]::Escape($Key))\s*=\s*(.*)$") { return $Matches[1].Trim() }
  }
  return $null
}

try {
  Write-Host ""
  Write-Host "  UE4SS - skannauskorjaus" -ForegroundColor Yellow
  Write-Host "  -----------------------"

  if (Get-Process -Name "SCUMServer" -ErrorAction SilentlyContinue) {
    Say "SCUMServer on kaynnissa. Sammuta palvelin ensin." "Red"
    return
  }

  if (-not $Win64) { $Win64 = Find-ServerWin64 }
  if (-not $Win64 -or -not (Test-Path $Win64)) {
    Say "Palvelimen Win64-kansiota ei loytynyt. Anna se -Win64 parametrilla." "Red"
    return
  }

  $ini = $null
  foreach ($n in @(@('UE4SS-settings.ini'), @('ue4ss', 'UE4SS-settings.ini'))) {
    $p = $Win64; foreach ($seg in $n) { $p = Join-Path $p $seg }
    if (Test-Path $p) { $ini = $p; break }
  }
  if (-not $ini) {
    Say "UE4SS-settings.ini ei loydy kansiosta $Win64" "Red"
    return
  }
  Say "Asetustiedosto: $ini"
  $backup = "$ini.tesles-backup"

  # ------------------------------------------------------------- revert ----
  if ($Revert) {
    $did = $false
    if (Test-Path $backup) {
      Copy-Item $backup $ini -Force
      Remove-Item $backup -Force
      Say "Alkuperaiset asetukset palautettiin." "Green"
      $did = $true
    }
    foreach ($c in @('Mods\cache', 'cache', 'ue4ss\cache')) {
      $p = $Win64
      foreach ($seg in $c.Split('\')) { $p = Join-Path $p $seg }
      if (Test-Path "$p.tesles-backup") {
        if (Test-Path $p) { Remove-Item $p -Recurse -Force -ErrorAction SilentlyContinue }
        Move-Item "$p.tesles-backup" $p -Force -ErrorAction SilentlyContinue
        Say "AOB-valimuisti palautettiin: $p" "Green"
        $did = $true
      }
    }
    # Any signature override this tool wrote is part of the same experiment.
    $sigDir = Join-Path (Split-Path $ini -Parent) 'UE4SS_Signatures'
    if (Test-Path $sigDir) {
      $mine = Get-ChildItem $sigDir -Filter *.lua -ErrorAction SilentlyContinue |
              Where-Object { (Get-Content $_.FullName -TotalCount 1) -match 'TESLES' }
      foreach ($f in $mine) {
        Remove-Item $f.FullName -Force
        Say "Poistettu signature-ohitus: $($f.Name)" "Green"
        $did = $true
      }
    }
    if (-not $did) { Say "Mitaan palautettavaa ei loytynyt." "Yellow" }
    return
  }

  # --------------------------------------------------- signature override --
  if ($Signature) {
    if (-not $Aob) {
      Say "-Signature vaatii myos -Aob tavukuvion." "Red"
      Say 'Esim: -Signature FText_Constructor -Aob "48 89 5C 24 ?? 57 48 83 EC 20"' "Yellow"
      return
    }
    $sigDir = Join-Path (Split-Path $ini -Parent) 'UE4SS_Signatures'
    New-Item -ItemType Directory -Path $sigDir -Force | Out-Null
    $sigFile = Join-Path $sigDir "$Signature.lua"
    @(
      "-- Written by TESLES NPC OVERHAUL / FIX_UE4SS_SCAN.ps1",
      "-- Overrides UE4SS's built-in pattern for $Signature.",
      "Register = function()",
      "    return `"$Aob`"",
      "end",
      "",
      "OnMatchFound = function(MatchAddress)",
      "    return MatchAddress",
      "end"
    ) | Set-Content -LiteralPath $sigFile -Encoding ASCII
    Say "Kirjoitettu: $sigFile" "Green"
    Say "Kaynnista palvelin ja katso UE4SS.log."
    return
  }

  # ------------------------------------------------------------- apply -----
  if (-not (Test-Path $backup)) {
    Copy-Item $ini $backup -Force
    Say "Varmuuskopio: $backup"
  } else {
    Say "Varmuuskopio oli jo olemassa - sailytetaan alkuperainen." "DarkGray"
  }

  $lines = @(Get-Content -LiteralPath $ini)
  $threadsBefore = Get-IniValue $lines 'SigScannerNumThreads'
  $secsBefore = Get-IniValue $lines 'SecondsToScanBeforeGivingUp'
  Say "Ennen: SigScannerNumThreads = $threadsBefore, SecondsToScanBeforeGivingUp = $secsBefore"

  $r = Set-IniValue $lines 'SigScannerNumThreads' '1'
  $lines = $r.lines
  $applied = @()
  if ($r.changed) { $applied += "SigScannerNumThreads = 1" }

  $r = Set-IniValue $lines 'SecondsToScanBeforeGivingUp' "$ScanSeconds"
  $lines = $r.lines
  if ($r.changed) { $applied += "SecondsToScanBeforeGivingUp = $ScanSeconds" }

  # A huge threshold keeps multi-threading off even if the thread count is
  # reapplied by a future UE4SS update.
  # Well clear of SCUMServer.exe (about 129 MB) but nowhere near the uint32
  # ceiling: a value at the exact maximum is a needless risk in a parser we
  # cannot inspect.
  $r = Set-IniValue $lines 'SigScannerMultithreadingModuleSizeThreshold' '2000000000'
  $lines = $r.lines
  if ($r.changed) { $applied += "SigScannerMultithreadingModuleSizeThreshold = 2000000000" }

  if ($ServerTuning) {
    $r = Set-IniValue $lines 'GuiConsoleEnabled' '0'
    $lines = $r.lines
    if ($r.changed) { $applied += "GuiConsoleEnabled = 0  (headless-palvelin)" }
  }

  Set-Content -LiteralPath $ini -Value $lines -Encoding UTF8

  # A stale AOB cache would be reused instead of rescanning. Rename rather
  # than delete, so -Revert can put it back.
  $cleared = 0
  foreach ($c in @('Mods\cache', 'cache', 'ue4ss\cache')) {
    $p = $Win64
    foreach ($seg in $c.Split('\')) { $p = Join-Path $p $seg }
    if ((Test-Path $p) -and -not (Test-Path "$p.tesles-backup")) {
      Move-Item $p "$p.tesles-backup" -Force -ErrorAction SilentlyContinue
      if (-not (Test-Path $p)) { $cleared++ }
    }
  }

  Write-Host ""
  if ($applied.Count -eq 0) {
    Say "Mitaan ei muutettu - avaimia ei loytynyt tiedostosta." "Yellow"
  } else {
    Say "Muutettu:" "Green"
    foreach ($a in $applied) { Say "  $a" "Green" }
    if ($cleared -gt 0) { Say "  AOB-valimuisti tyhjennettiin ($cleared kansiota)" "Green" }
  }

  Write-Host ""
  Say "Kaynnista palvelin ja ODOTA $ScanSeconds sekuntia ennen lisatyokalut\CHECK.bat:ia." "Cyan"
  Say "Yksi saie skannaa hitaammin, joten lopputulos nakyy vasta aikarajan"
  Say "jalkeen. Sita ennen CHECK nayttaa tilan SCANNING, mika on normaalia."
  Write-Host ""
  Say "Jos UE4SS yha kaatuu samaan riviin, skannaus ei ollut saikeiden vika:"
  Say "  lisatyokalut\INSTALL_UE4SS.bat -Force -Experimental" "Cyan"
  Write-Host ""
  Say "Peruminen: lisatyokalut\FIX_UE4SS_SCAN.bat -Revert" "DarkGray"
  Write-Host ""
}
catch {
  Write-Host ""
  Say "VIRHE: $($_.Exception.Message)" "Red"
  if ($_.InvocationInfo) {
    Say "Rivi $($_.InvocationInfo.ScriptLineNumber): $($_.InvocationInfo.Line.Trim())" "DarkGray"
  }
  Write-Host ""
}
