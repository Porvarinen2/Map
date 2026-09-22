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
  [string]$Aob = "",       # byte pattern for -Signature, if you have one
  [switch]$Auto            # find FText_Constructor in SCUMServer.exe and write it
)

$ErrorActionPreference = "Stop"
function Say($t, $c = "Gray") { Write-Host "  $t" -ForegroundColor $c }

# --------------------------------------------------------- pattern finder --
# UE4SS gives up when its own pattern for FText::FText(FString&&) matches more
# than one address. Every candidate below is a pattern UE4SS itself ships, for
# another Unreal game, either in a custom game config or compiled into the
# loader. A candidate is only used when it matches the server executable
# EXACTLY once, and when two candidates both match they have to agree on the
# same address. Nothing is guessed: a pattern that is ambiguous here is
# discarded, the same way UE4SS discards its own.
$FTEXT_CANDIDATES = @(
  "48 8B C4 56 57 48 83 EC 68 48 89 58 18 48 8B F9",
  "48 8B C4 56 57 48 83 EC 68 48 89 58 18",
  "48 89 5C 24 ?? 48 89 6C 24 ?? 56 57 41 54 41 56 41 57 48 83 EC ?? 45 33 E4 48 8B F1 48 8B 0D",
  "48 89 5C 24 10 48 89 6C 24 18 56 57 41 54 41 56 41 57 48 83 EC 40 45 33 E4 48 8B F1 41 8B DC 4C 8B F2 89 5C 24 70 41 8D 4C 24 70 E8 ?? ?? ?? FF 48 8B F8 48 85 C0 0F 84 ?? 00 00 00 49 63 5E 08",
  "48 89 5C 24 10 48 89 6C 24 18 56 57 41 54 41 56 41 57 48 83 EC 50 45 33 E4 48 8B F9 41 8B DC 4C 8B F2 89 9C 24 80 00 00 00 41 8D 4C 24 70 E8 ?? ?? ?? ?? 48 8B F0 48 85 C0 0F 84 98 00 00 00 49 63 5E 08",
  "48 89 5C 24 10 48 89 6C 24 18 57 48 83 EC 50 33 ED 48 8D 05 ?? ?? ?? 03 48 8B F9 48 89 6C 24 38 48 8B DA 48 89 6C 24 48 48 89 44 24 30 8D 4D 60 48 89 44 24 40 E8 ?? ?? ?? FF 4C 8B C0 48 85 C0 74 65",
  "40 53 56 48 83 EC 48 33 DB 48 89 6C 24 68 48 8B F1 48 89 7C 24 70 4C 89 74 24 78 4C 8B F2 89 5C 24 60 8D 4B 70 E8 ?? ?? ?? FF 48 8B F8 48 85 C0 0F 84 9E 00 00 00 49 63 5E 08",
  "48 89 5C 24 ?? 48 89 6C 24 ?? 48 89 74 24 ?? 48 89 7C 24 ?? 41 54 41 56 41 57 48 83 EC 40 4C 8B F1 48 8B F2",
  "48 89 5C 24 ?? 48 89 6C 24 ?? 56 57 41 54 41 56 41 57 48 83 EC 40 45 33 E4 48 8B F1",
  "48 89 5C 24 ?? 48 89 74 24 ?? 57 48 83 EC ?? 48 8D 05 ?? ?? ?? ?? 33 F6 48 8B D9 48 89 44 24",
  "40 53 57 48 83 EC 38 48 89 6C 24 60 48 8B FA 48 89 74 24 68 48 8B D9 33 F6 4C 89 74 24 30 89 74 24 50 83 7A ?? 01 7F 31"
)

Add-Type -TypeDefinition @"
using System;
public static class TeslesAob {
  // Returns the offsets of every match, stopping once more than one is found:
  // the caller only ever needs to tell apart none, one and ambiguous.
  public static long[] Find(byte[] hay, short[] pat, int max) {
    var hits = new System.Collections.Generic.List<long>();
    int n = pat.Length;
    long end = hay.LongLength - n;
    for (long i = 0; i <= end; i++) {
      int j = 0;
      while (j < n && (pat[j] < 0 || hay[i + j] == (byte)pat[j])) j++;
      if (j == n) {
        hits.Add(i);
        if (hits.Count >= max) break;
      }
    }
    return hits.ToArray();
  }
}
"@ -ErrorAction SilentlyContinue

function ConvertTo-Pattern($aob) {
  $out = New-Object System.Collections.ArrayList
  foreach ($tok in ($aob -split '\s+' | Where-Object { $_ })) {
    if ($tok -match '^\?\??$') { [void]$out.Add([short](-1)) }
    elseif ($tok -match '^[0-9A-Fa-f]{2}$') { [void]$out.Add([short][Convert]::ToInt32($tok, 16)) }
    else { throw "Kelvoton tavu kuviossa: $tok" }
  }
  return ,([short[]]$out.ToArray())
}

function Invoke-AutoSignature($win64, $iniPath) {
  $exe = Join-Path $win64 'SCUMServer.exe'
  if (-not (Test-Path -LiteralPath $exe)) {
    Say "SCUMServer.exe ei loydy: $exe" "Red"
    return
  }
  Write-Host ""
  Say "Etsitaan FText::FText(FString&&) suoraan palvelimen exe:sta." "Cyan"
  Say "Tiedosto: $exe" "DarkGray"
  Say ("Koko    : {0:N0} tavua" -f (Get-Item $exe).Length) "DarkGray"
  Write-Host ""

  $bytes = [System.IO.File]::ReadAllBytes($exe)
  $unique = @()
  $i = 0
  foreach ($aob in $FTEXT_CANDIDATES) {
    $i++
    $pat = ConvertTo-Pattern $aob
    $hits = [TeslesAob]::Find($bytes, $pat, 2)
    $short = if ($aob.Length -gt 46) { $aob.Substring(0, 46) + "..." } else { $aob }
    if ($hits.Count -eq 1) {
      Say ("{0,2}. yksi osuma  0x{1:X}  {2}" -f $i, $hits[0], $short) "Green"
      $unique += [pscustomobject]@{ aob = $aob; offset = $hits[0] }
    } elseif ($hits.Count -eq 0) {
      Say ("{0,2}. ei osumia   {1}" -f $i, $short) "DarkGray"
    } else {
      Say ("{0,2}. monta osumaa {1}" -f $i, $short) "DarkGray"
    }
  }
  $bytes = $null
  [System.GC]::Collect()

  Write-Host ""
  if ($unique.Count -eq 0) {
    Say "Yksikaan tunnettu kuvio ei osu tahan exe:hen yksiselitteisesti." "Red"
    Say "Talle palvelimen buildille tarvitaan oma tavukuvio. Se pitaa" "Yellow"
    Say "etsia purkamalla exe (IDA/Ghidra) - arvaus kaataisi palvelimen." "Yellow"
    return
  }

  $offsets = @($unique | ForEach-Object { $_.offset } | Sort-Object -Unique)
  if ($offsets.Count -gt 1) {
    Say "Kuviot ovat eri mielta funktion osoitteesta:" "Red"
    foreach ($o in $offsets) { Say ("  0x{0:X}" -f $o) "Red" }
    Say "Yhtakaan ei kirjoiteta - vaara osoite kaataisi palvelimen." "Yellow"
    return
  }

  # Several candidates matching the same single address is the strongest signal
  # available without symbols; pick the longest, it has the fewest wildcards.
  $best = $unique | Sort-Object { $_.aob.Length } -Descending | Select-Object -First 1
  Say ("Kaikki {0} osuvaa kuviota osoittavat samaan kohtaan: 0x{1:X}" -f
       $unique.Count, $best.offset) "Green"

  $sigDir = Join-Path (Split-Path $iniPath -Parent) 'UE4SS_Signatures'
  New-Item -ItemType Directory -Path $sigDir -Force | Out-Null
  $sigFile = Join-Path $sigDir "FText_Constructor.lua"
  @(
    "-- Written by TESLES NPC OVERHAUL / FIX_UE4SS_SCAN.ps1 -Auto",
    ("-- Matched SCUMServer.exe exactly once at file offset 0x{0:X}." -f $best.offset),
    ("-- Candidates that agreed: {0}" -f $unique.Count),
    "Register = function()",
    "    return `"$($best.aob)`"",
    "end",
    "",
    "OnMatchFound = function(MatchAddress)",
    "    return MatchAddress",
    "end"
  ) | Set-Content -LiteralPath $sigFile -Encoding ASCII
  Write-Host ""
  Say "Kirjoitettu: $sigFile" "Green"
  Say "Kaynnista palvelin ja aja lisatyokalut\CHECK.bat." "Cyan"
  Say "Peruminen: lisatyokalut\FIX_UE4SS_SCAN.bat -Revert" "DarkGray"
}


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

  # ------------------------------------------------------ automatic AOB ----
  if ($Auto) {
    Invoke-AutoSignature $Win64 $ini
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
