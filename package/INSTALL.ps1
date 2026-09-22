<#
  TESLES NPC OVERHAUL - yhden klikkauksen asennus.

  Tekee kaiken: etsii palvelimen, asentaa tai paivittaa UE4SS:n, ottaa muut
  modit pois kaytosta, asentaa modin, pilkkoo tarkan kartan ja kaynnistaa
  live mapin.

  Palvelimen tallennusta, tietokantaa tai asetuksia ei kosketa. Kaikki mita
  korvataan, varmuuskopioidaan kansioon <SCUM Server>\TeslesNPCOverhaul_Backups.
#>
param(
  [string]$ServerRoot = "",   # SCUM Server -kansio; etsitaan automaattisesti
  [switch]$SkipUE4SS,         # ala kosketa UE4SS-asennukseen
  [switch]$KeepOtherMods,     # jata muut Lua-modit paalle
  [switch]$NoMap,             # ala pilko karttaa ala kaynnista live mapia
  [switch]$Yes,               # ala kysy mitaan
  [switch]$NoPause            # ala odota Enteria lopussa
)

$ErrorActionPreference = "Stop"
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$MOD = "TeslesNPCOverhaul"
. (Join-Path $here 'ue4ss_health.ps1')

function Say($t, $c = "Gray") { Write-Host "  $t" -ForegroundColor $c }
function Step($n, $t) {
  Write-Host ""
  Write-Host "  [$n/6] $t" -ForegroundColor Cyan
  Write-Host "  ------------------------------------------------" -ForegroundColor DarkGray
}
function Die($t) {
  Write-Host ""
  Say $t "Red"
  Write-Host ""
  if (-not $NoPause) { Read-Host "  Enter sulkee" }
  exit 1
}

$warnings = @()

Write-Host ""
Write-Host "  TESLES NPC OVERHAUL - asennus" -ForegroundColor Yellow
Write-Host "  =============================="
Say "Tama asentaa kaiken tarvittavan. Sinun ei tarvitse tehda muuta." "DarkGray"

# ---------------------------------------------------------------- guards ---

if (Get-Process -Name "SCUMServer" -ErrorAction SilentlyContinue) {
  Die "SCUMServer on kaynnissa. Sammuta palvelin ja aja INSTALL.bat uudestaan."
}
if ($here -match "\\AppData\\Local\\Temp\\" -or $here -match "\.zip\\") {
  Die "Ala aja asennusta ZIPin sisalta. Pura paketti omaan kansioon ensin."
}

# =========================================================== 1. palvelin ===
Step 1 "Etsitaan SCUM-palvelin"

$candidates = @(
  'F:\SteamLibrary\steamapps\common\SCUM Server',
  'D:\SteamLibrary\steamapps\common\SCUM Server',
  'E:\SteamLibrary\steamapps\common\SCUM Server',
  'G:\SteamLibrary\steamapps\common\SCUM Server',
  'C:\SteamLibrary\steamapps\common\SCUM Server',
  'C:\Program Files (x86)\Steam\steamapps\common\SCUM Server',
  'C:\Program Files\Steam\steamapps\common\SCUM Server'
)
function Test-ServerRoot($p) {
  if (-not $p) { return $false }
  try {
    return Test-Path -LiteralPath (Join-Path $p 'SCUM\Binaries\Win64\SCUMServer.exe') `
                     -PathType Leaf -ErrorAction SilentlyContinue
  } catch { return $false }
}

$server = $ServerRoot.Trim('"').Trim()
if (-not (Test-ServerRoot $server)) {
  $server = $candidates | Where-Object { Test-ServerRoot $_ } | Select-Object -First 1
}
# Ei tavallisista poluista: katsotaan Steamin kirjastoluettelo ja jokaisen levyn
# steamapps\common-kansiot. Koko levyn lapikaynti kestaisi minuutteja.
if (-not $server) {
  Say "Ei tavallisissa poluissa. Etsitaan Steam-kirjastoista..." "Yellow"
  $roots = New-Object System.Collections.ArrayList

  foreach ($vdf in @(
      'C:\Program Files (x86)\Steam\steamapps\libraryfolders.vdf',
      'C:\Program Files\Steam\steamapps\libraryfolders.vdf')) {
    if (Test-Path -LiteralPath $vdf -ErrorAction SilentlyContinue) {
      foreach ($m in ([regex]::Matches((Get-Content -LiteralPath $vdf -Raw), '"path"\s*"([^"]+)"'))) {
        [void]$roots.Add(($m.Groups[1].Value -replace '\\\\', '\'))
      }
    }
  }
  foreach ($d in (Get-PSDrive -PSProvider FileSystem -ErrorAction SilentlyContinue)) {
    if ($d.Root -match '^[A-Za-z]:\\$') {
      [void]$roots.Add(($d.Root + 'SteamLibrary'))
      [void]$roots.Add(($d.Root + 'Steam'))
      [void]$roots.Add($d.Root.TrimEnd('\'))
      [void]$roots.Add(($d.Root + 'Games'))
      [void]$roots.Add(($d.Root + 'SCUM'))
    }
  }
  foreach ($r in $roots) {
    foreach ($sub in @('steamapps\common\SCUM Server', 'SCUM Server', 'common\SCUM Server')) {
      $p = $r
      foreach ($seg in $sub.Split('\')) { $p = Join-Path $p $seg }
      if (Test-ServerRoot $p) { $server = $p; break }
    }
    if ($server) { break }
  }
}
if (-not $server) {
  Write-Host ""
  Say "SCUM-palvelinta ei loytynyt automaattisesti." "Yellow"
  $server = (Read-Host "  Anna SCUM Server -kansion polku").Trim('"').Trim()
}
if (-not (Test-ServerRoot $server)) {
  Die "Polusta ei loydy SCUMServer.exe:ta: $server"
}

$win64 = Join-Path $server 'SCUM\Binaries\Win64'
Say "Palvelin: $server" "Green"

function Resolve-ModsDir($w) {
  foreach ($n in @(@('Mods'), @('ue4ss', 'Mods'))) {
    $p = $w
    foreach ($seg in $n) { $p = Join-Path $p $seg }
    if (Test-Path -LiteralPath $p) { return $p }
  }
  return $null
}
function Test-Loader($w) {
  return (Test-Path (Join-Path $w 'UE4SS.dll')) -or
         (Test-Path (Join-Path (Join-Path $w 'ue4ss') 'UE4SS.dll'))
}

# ============================================================== 2. UE4SS ===
Step 2 "UE4SS (Lua-modien lataaja)"

if ($SkipUE4SS) {
  Say "Ohitettu (-SkipUE4SS)." "Yellow"
} else {
  # Aiempi skannauskorjaus on kumottu hypoteesi: se ei auttanut ja hidastaa
  # kaynnistysta kahdella minuutilla. Perutaan se ennen paivitysta.
  $fix = Join-Path $here 'FIX_UE4SS_SCAN.ps1'
  if (Test-Path $fix) {
    $ini = Join-Path $win64 'UE4SS-settings.ini'
    if (Test-Path "$ini.tesles-backup") {
      Say "Perutaan aiempi skannauskorjaus (ei auttanut)..." "Yellow"
      try { & $fix -Win64 $win64 -Revert | Out-Null } catch {}
    }
  }

  $installer = Join-Path $here 'INSTALL_UE4SS.ps1'
  if (-not (Test-Path $installer)) {
    Die "Paketista puuttuu INSTALL_UE4SS.ps1."
  }

  $had = Test-Loader $win64
  if ($had) {
    Say "UE4SS on jo asennettu - paivitetaan uusimpaan." "Gray"
  } else {
    Say "UE4SS puuttuu - asennetaan GitHubista." "Gray"
  }
  try {
    & $installer -Win64 $win64 -Yes -Force -Experimental -Chained
  } catch {
    Say "UE4SS-asennus keskeytyi: $($_.Exception.Message)" "Red"
  }

  if (-not (Test-Loader $win64)) {
    Write-Host ""
    Say "UE4SS ei ole asennettuna, joten modi ei voi toimia." "Red"
    Say "Lataus ei onnistunut (verkko, palomuuri tai GitHubin tuntiraja)." "Yellow"
    Write-Host ""
    Say "Tee nain:" "Cyan"
    Say "  1. Avaa https://github.com/UE4SS-RE/RE-UE4SS/releases" "Cyan"
    Say "  2. Lataa uusin UE4SS_vX.Y.Z.zip" "Cyan"
    Say "  3. lisatyokalut\INSTALL_UE4SS.bat -Force -ZipFile C:\polku\UE4SS.zip" "Cyan"
    Say "  4. Aja INSTALL.bat uudestaan." "Cyan"
    Die "Asennus keskeytyi."
  }
  if (-not $had) { Say "UE4SS asennettu." "Green" }
}

$mods = Resolve-ModsDir $win64
if (-not $mods) {
  $mods = Join-Path $win64 'Mods'
  New-Item -ItemType Directory -Path $mods -Force | Out-Null
  Set-Content -LiteralPath (Join-Path $mods 'mods.txt') -Value @("Keybinds : 1") -Encoding ASCII
  Say "Mods-kansio luotiin." "Yellow"
}
Say "Mods: $mods" "Green"

$modsTxt = Join-Path $mods 'mods.txt'
$backupRoot = Join-Path $server 'TeslesNPCOverhaul_Backups'
$stamp = Get-Date -Format "yyyyMMdd-HHmmss"
$backup = Join-Path $backupRoot $stamp
New-Item -ItemType Directory -Path $backup -Force | Out-Null
if (Test-Path -LiteralPath $modsTxt) {
  Copy-Item -LiteralPath $modsTxt -Destination (Join-Path $backup 'mods.txt') -Force
}

# ======================================================== 3. muut modit ====
Step 3 "Muut modit pois paalta"

if ($KeepOtherMods) {
  Say "Ohitettu (-KeepOtherMods)." "Yellow"
} else {
  # Kaksi modia jotka komentavat samoja NPC:ita riitelevat keskenaan, ja jokainen
  # ylimaarainen Lua-modi on yksi asia lisaa joka voi kaatua ennen tata. Mitaan
  # ei poisteta, vain otetaan pois kaytosta.
  $off = @()
  $lines = @()
  if (Test-Path -LiteralPath $modsTxt) { $lines = @(Get-Content -LiteralPath $modsTxt) }
  $out = foreach ($l in $lines) {
    if ($l -match '^\s*([A-Za-z0-9_\-\.]+)\s*:\s*1\s*$') {
      $name = $Matches[1]
      if ($name -eq $MOD) { $l }
      else { $off += $name; "$name : 0" }
    } else { $l }
  }
  if ($lines.Count -gt 0) { Set-Content -LiteralPath $modsTxt -Value $out -Encoding ASCII }

  # UE4SS kaynnistaa myos minka tahansa kansion jossa on enabled.txt, riippumatta
  # siita mita mods.txt sanoo, joten ne merkit on siirrettava syrjaan.
  $parked = 0
  foreach ($d in (Get-ChildItem -LiteralPath $mods -Directory -ErrorAction SilentlyContinue)) {
    if ($d.Name -eq $MOD) { continue }
    $marker = Join-Path $d.FullName 'enabled.txt'
    if (Test-Path -LiteralPath $marker) {
      Move-Item -LiteralPath $marker -Destination "$marker.disabled" -Force
      $parked++
      if ($off -notcontains $d.Name) { $off += $d.Name }
    }
  }

  if ($off.Count -gt 0) {
    Say ("Pois kaytosta ({0}): {1}" -f $off.Count, ($off -join ', ')) "Yellow"
    Set-Content -LiteralPath (Join-Path $backup 'disabled_mods.txt') `
                -Value $off -Encoding ASCII
    Say "Lista talletettiin: $backup\disabled_mods.txt" "DarkGray"
  } else {
    Say "Muita modeja ei ollut paalla." "Green"
  }
}

# ============================================================== 4. modi ====
Step 4 "Asennetaan TESLES NPC OVERHAUL"

$target = Join-Path $mods $MOD
$keepState = $null
if (Test-Path -LiteralPath $target) {
  Copy-Item -LiteralPath $target -Destination (Join-Path $backup $MOD) -Recurse -Force
  Say "Vanha versio varmuuskopioitiin." "Gray"
  # Pysyva maailma on se ainoa asia jota paivitys ei saa heittaa pois.
  $stateSrc = Join-Path $target 'state'
  if (Test-Path -LiteralPath $stateSrc) {
    $keepState = Join-Path ([System.IO.Path]::GetTempPath()) "tesles_state_$stamp"
    Copy-Item -LiteralPath $stateSrc -Destination $keepState -Recurse -Force
    Say "Maailman tila otettiin talteen." "Green"
  }
  Remove-Item -LiteralPath $target -Recurse -Force
}

$src = Join-Path $here "mod\$MOD"
if (-not (Test-Path -LiteralPath $src)) { Die "Paketista puuttuu mod\$MOD" }
Copy-Item -LiteralPath $src -Destination $target -Recurse -Force
New-Item -ItemType Directory -Path (Join-Path $target 'state') -Force | Out-Null
New-Item -ItemType Directory -Path (Join-Path $target 'output') -Force | Out-Null

if ($keepState) {
  Copy-Item -Path (Join-Path $keepState '*') -Destination (Join-Path $target 'state') -Recurse -Force
  Remove-Item -LiteralPath $keepState -Recurse -Force
  Say "Maailman tila palautettiin." "Green"
}

$files = (Get-ChildItem -LiteralPath $target -Recurse -File).Count
Say "Kopioitu $files tiedostoa." "Green"

$lines = @()
if (Test-Path -LiteralPath $modsTxt) { $lines = @(Get-Content -LiteralPath $modsTxt) }
$lines = @($lines | Where-Object { $_ -notmatch "^\s*$MOD\s*:" })
$lines = $lines + @("$MOD : 1")
Set-Content -LiteralPath $modsTxt -Value $lines -Encoding ASCII
Set-Content -LiteralPath (Join-Path $target 'enabled.txt') -Value "" -Encoding ASCII
Say "Rekisteroity: mods.txt + enabled.txt" "Green"

$outDir = Join-Path $target 'output'
Set-Content -LiteralPath (Join-Path $here 'livemap\livemap_paths.txt') `
            -Value $outDir -Encoding UTF8

# Vanha kaynnistysloki luettaisiin taman kaynnistyksen lokina.
$oldBoot = Join-Path $outDir 'boot.log'
if (Test-Path $oldBoot) { Remove-Item $oldBoot -Force }

# ============================================================= 5. kartta ===
Step 5 "Kartta"

$mapDir = Join-Path $here 'livemap\map'
$tileIdx = Join-Path $mapDir 'tiles\tiles.json'
if ($NoMap) {
  Say "Ohitettu (-NoMap)." "Yellow"
} elseif (Test-Path $tileIdx) {
  Say "Tarkka kartta on jo pilkottu." "Green"
} else {
  $hires = $null
  if (Test-Path $mapDir) {
    $hires = Get-ChildItem -LiteralPath $mapDir -File -ErrorAction SilentlyContinue |
             Where-Object { $_.Name -ne 'scum_map.png' -and $_.Length -gt 5MB } |
             Sort-Object Length -Descending | Select-Object -First 1
  }
  if ($hires) {
    Say "Pilkotaan $($hires.Name) - tama kestaa muutaman minuutin..." "Yellow"
    try {
      & (Join-Path $here 'livemap\tile_map.ps1') -Source $hires.FullName
    } catch {
      Say "Pilkkominen epaonnistui: $($_.Exception.Message)" "Red"
      $warnings += "Tarkan kartan pilkkominen epaonnistui; live map kayttaa peruskarttaa."
    }
  } else {
    Say "Tarkkaa karttaa ei ole - kaytetaan paketin peruskarttaa." "Gray"
    Say "Halutessasi: tallenna 14k-kartta nimella scum_map_hires.png" "DarkGray"
    Say "kansioon livemap\map\ ja aja INSTALL.bat uudestaan." "DarkGray"
  }
}
if (-not (Test-Path (Join-Path $mapDir 'scum_map.png'))) {
  $warnings += "livemap\map\scum_map.png puuttuu - pura paketti uudestaan."
}

# =========================================================== 6. live map ===
Step 6 "Live map"

$mapStarted = $false
if ($NoMap) {
  Say "Ohitettu (-NoMap)." "Yellow"
} else {
  $busy = $null
  try {
    $busy = Get-NetTCPConnection -LocalPort 8777 -State Listen -ErrorAction SilentlyContinue
  } catch {}
  if ($busy) {
    Say "Live map on jo kaynnissa portissa 8777." "Green"
    $mapStarted = $true
  } else {
    try {
      Start-Process -FilePath "powershell.exe" -WorkingDirectory $here -ArgumentList @(
        "-NoLogo", "-NoProfile", "-ExecutionPolicy", "Bypass",
        "-File", (Join-Path $here 'livemap\server.ps1'), "-Port", "8777"
      ) | Out-Null
      Start-Sleep -Seconds 2
      Start-Process "http://127.0.0.1:8777/" | Out-Null
      Say "Live map kaynnistettiin omaan ikkunaansa." "Green"
      Say "Osoite: http://127.0.0.1:8777/" "Green"
      Say "Ala sulje sita ikkunaa niin kauan kuin haluat kartan nakyvan." "DarkGray"
      $mapStarted = $true
    } catch {
      Say "Live mapia ei saatu kaynnistettya: $($_.Exception.Message)" "Yellow"
      Say "Kaynnista se kasin: START_LIVEMAP.bat" "Yellow"
    }
  }
}

# ============================================================== yhteenveto =

# Modi on paikallaan, mutta se voi toimia vain jos UE4SS paasee modien
# lataamiseen asti. Jos edellinen kaynnistys todisti ettei paase, se on
# parempi sanoa nyt kuin antaa kayttajan huomata se uuden uudelleenkaynnistyksen
# jalkeen.
$health = $null
try { $health = Get-UE4SSHealth $win64 } catch {}

Write-Host ""
Write-Host "  ================================================" -ForegroundColor Green
Write-Host "   VALMIS - kaikki asennettu" -ForegroundColor Green
Write-Host "  ================================================" -ForegroundColor Green
Write-Host ""

if ($health -and $health.verdict -in @("SCAN_ABORTED", "SCAN_LOOP")) {
  Say "HUOM: UE4SS ei edellisella kaynnistyksella paassyt modien lataukseen." "Yellow"
  Say "UE4SS paivitettiin juuri, joten kokeile kaynnistysta - jos sama" "Yellow"
  Say "toistuu, aja DIAGNOSE.bat." "Yellow"
  Write-Host ""
}
foreach ($w in $warnings) { Say "VAROITUS: $w" "Yellow" }
if ($warnings.Count -gt 0) { Write-Host "" }

Say "Sinulle jaa vain yksi asia:" "Cyan"
Say "  ->  Kaynnista SCUM-palvelin normaalisti." "Cyan"
Write-Host ""
Say "Modi kirjoittaa heti kaynnistyessaan tiedoston"
Say "  $outDir\boot.log"
Say "ja alkaa toimia 25 sekunnin kuluttua."
if ($mapStarted) {
  Say "Live map paivittyy itsestaan: http://127.0.0.1:8777/"
} else {
  Say "Live map: START_LIVEMAP.bat  ->  http://127.0.0.1:8777/"
}
Write-Host ""
Say "Jos jokin ei toimi, aja DIAGNOSE.bat." "DarkGray"
Say "Asetukset: $target\config.lua" "DarkGray"
Write-Host ""
if (-not $NoPause) { Read-Host "  Enter sulkee" }
