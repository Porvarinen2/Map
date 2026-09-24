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
$ue4ssUnchanged = $false

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
  foreach ($n in @(@('ue4ss', 'Mods'), @('Mods'))) {
    $p = $w
    foreach ($seg in $n) { $p = Join-Path $p $seg }
    if (Test-Path -LiteralPath $p) { return $p }
  }
  return $null
}
function Test-Loader($w) {
  return (Test-Path (Join-Path (Join-Path $w 'ue4ss') 'UE4SS.dll')) -or
         (Test-Path (Join-Path $w 'UE4SS.dll'))
}
function Get-LoaderStamp($w) {
  foreach ($n in @(@('ue4ss', 'UE4SS.dll'), @('UE4SS.dll'))) {
    $p = $w; foreach ($seg in $n) { $p = Join-Path $p $seg }
    if (Test-Path $p) { return (Get-FileHash $p -Algorithm SHA256).Hash }
  }
  return $null
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

  $global:TeslesLoaderAlreadyCurrent = $false
  $had = Test-Loader $win64
  $beforeHash = Get-LoaderStamp $win64
  if ($had) {
    Say "UE4SS on jo asennettu - vaihdetaan paketin mukana tulleeseen." "Gray"
  } else {
    Say "UE4SS puuttuu - asennetaan." "Gray"
  }
  try {
    & $installer -Win64 $win64 -Yes -Force -Chained
  } catch {
    Say "UE4SS-asennus keskeytyi: $($_.Exception.Message)" "Red"
  }
  $afterHash = Get-LoaderStamp $win64
  if ($global:TeslesLoaderAlreadyCurrent) {
    Say "UE4SS on ajan tasalla." "Green"
  } elseif ($had -and $beforeHash -and $beforeHash -eq $afterHash) {
    # 1.0.8 said it updated the loader while the file on disk never changed.
    # Whatever the cause, the summary has to show it instead of hiding it.
    $ue4ssUnchanged = $true
    Say "VAROITUS: UE4SS.dll ei vaihtunut." "Red"
  } elseif ($afterHash) {
    Say "UE4SS-lataaja on nyt vaihdettu." "Green"
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
# Newer UE4SS builds read mods.json and fall back to mods.txt, so both have to
# say the same thing or the two disagree about what runs.
$modsJson = Join-Path $mods 'mods.json'
$backupRoot = Join-Path $server 'TeslesNPCOverhaul_Backups'
$stamp = Get-Date -Format "yyyyMMdd-HHmmss"
$backup = Join-Path $backupRoot $stamp
New-Item -ItemType Directory -Path $backup -Force | Out-Null
if (Test-Path -LiteralPath $modsTxt) {
  Copy-Item -LiteralPath $modsTxt -Destination (Join-Path $backup 'mods.txt') -Force
}
if (Test-Path -LiteralPath $modsJson) {
  Copy-Item -LiteralPath $modsJson -Destination (Join-Path $backup 'mods.json') -Force
}

function Write-ModsJson($path, $entries) {
  $json = if ($entries.Count -eq 1) { "[" + ($entries | ConvertTo-Json -Depth 4) + "]" }
          else { $entries | ConvertTo-Json -Depth 4 }
  Set-Content -LiteralPath $path -Value $json -Encoding ASCII
}
function Read-ModsJson($path) {
  if (-not (Test-Path -LiteralPath $path)) { return $null }
  try { return @(Get-Content -LiteralPath $path -Raw | ConvertFrom-Json) } catch { return $null }
}

# UE4SS hooks a dozen engine functions by default: BeginPlay, EndPlay, actor
# tick, the Blueprint VM (ProcessInternal / ProcessLocalScriptFunction /
# ProcessEvent), struct linking, the local-player console and the viewport.
# This mod calls engine functions but hooks none of them; the only hook it
# needs is the engine tick, which drives UE4SS's game-thread timers.
#
# On this server the default set crashes SCUM the moment a player joins, inside
# the Blueprint VM, while the mod has not made a single engine call (1.1.4's
# breadcrumb file stayed empty). Everything but the engine tick is switched
# off; the original file is kept as UE4SS-settings.ini.tesles-hooks-backup.
function Set-MinimalUE4SSHooks($w) {
  $ini = $null
  foreach ($c in @((Join-Path (Join-Path $w 'ue4ss') 'UE4SS-settings.ini'),
                   (Join-Path $w 'UE4SS-settings.ini'))) {
    if (Test-Path -LiteralPath $c) { $ini = $c; break }
  }
  if (-not $ini) { return $null }
  $want = [ordered]@{
    HookProcessInternal = 0; HookProcessLocalScriptFunction = 0
    HookInitGameState = 0; HookLoadMap = 0
    HookCallFunctionByNameWithArguments = 0; HookBeginPlay = 0; HookEndPlay = 0
    HookLocalPlayerExec = 0; HookAActorTick = 0; HookEngineTick = 1
    HookGameViewportClientTick = 0; HookUObjectProcessEvent = 0
    HookProcessConsoleExec = 0; HookUStructLink = 0
  }
  $lines = @(Get-Content -LiteralPath $ini)
  $changed = @()
  for ($i = 0; $i -lt $lines.Count; $i++) {
    if ($lines[$i] -match '^\s*([A-Za-z]+)\s*=\s*(\S+)') {
      $k = $Matches[1]
      if ($want.Contains($k) -and "$($Matches[2])" -ne "$($want[$k])") {
        $lines[$i] = "$k = $($want[$k])"
        $changed += $k
      }
    }
  }
  if ($changed.Count -gt 0) {
    $bak = "$ini.tesles-hooks-backup"
    if (-not (Test-Path -LiteralPath $bak)) { Copy-Item -LiteralPath $ini -Destination $bak -Force }
    Set-Content -LiteralPath $ini -Value $lines -Encoding ASCII
  }
  return $changed
}

if (-not $SkipUE4SS) {
  $hooksOff = Set-MinimalUE4SSHooks $win64
  if ($null -eq $hooksOff) {
    Say "UE4SS-settings.ini ei loytynyt - koukkuja ei muutettu." "Yellow"
  } elseif ($hooksOff.Count -gt 0) {
    Say ("UE4SS:n turhat koukut pois ({0} kpl) - vain EngineTick jaa." -f $hooksOff.Count) "Green"
  } else {
    Say "UE4SS:n koukut jo minimissa (vain EngineTick)." "Green"
  }
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

  $jsonEntries = Read-ModsJson $modsJson
  if ($jsonEntries) {
    $changed = $false
    foreach ($e in $jsonEntries) {
      if ($e.mod_name -ne $MOD -and $e.mod_enabled) {
        $e.mod_enabled = $false
        $changed = $true
        if ($off -notcontains $e.mod_name) { $off += $e.mod_name }
      }
    }
    if ($changed) {
      Write-ModsJson $modsJson $jsonEntries
      Say "mods.json paivitetty samaan tilaan kuin mods.txt." "Gray"
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
$keepOutput = $null
$keepUser = @{}
if (Test-Path -LiteralPath $target) {
  Copy-Item -LiteralPath $target -Destination (Join-Path $backup $MOD) -Recurse -Force
  Say "Vanha versio varmuuskopioitiin." "Gray"
  # Two folders have to survive an update: the saved world, and the output the
  # live map reads. Wiping output\ made the map say "live_state.json does not
  # exist yet" after every reinstall, which looked like the mod had never run.
  # The owner's own files survive every update: squad gear and own classes.
  $keepUser = @{}
  foreach ($uf in @('varusteet.lua', 'ryhmat.lua')) {
    $ufPath = Join-Path $target $uf
    if (Test-Path -LiteralPath $ufPath) {
      $tmp = Join-Path ([System.IO.Path]::GetTempPath()) "tesles_${stamp}_$uf"
      Copy-Item -LiteralPath $ufPath -Destination $tmp -Force
      $keepUser[$uf] = $tmp
    }
  }
  foreach ($keep in @('state', 'output')) {
    $src = Join-Path $target $keep
    if (Test-Path -LiteralPath $src) {
      $dst = Join-Path ([System.IO.Path]::GetTempPath()) "tesles_${keep}_$stamp"
      Copy-Item -LiteralPath $src -Destination $dst -Recurse -Force
      if ($keep -eq 'state') { $keepState = $dst } else { $keepOutput = $dst }
    }
  }
  if ($keepState) { Say "Maailman tila otettiin talteen." "Green" }
  Remove-Item -LiteralPath $target -Recurse -Force
}

$src = Join-Path $here "mod\$MOD"
if (-not (Test-Path -LiteralPath $src)) { Die "Paketista puuttuu mod\$MOD" }
Copy-Item -LiteralPath $src -Destination $target -Recurse -Force
New-Item -ItemType Directory -Path (Join-Path $target 'state') -Force | Out-Null
$outDirEarly = Join-Path $target 'output'
New-Item -ItemType Directory -Path $outDirEarly -Force | Out-Null

if ($keepState) {
  Copy-Item -Path (Join-Path $keepState '*') -Destination (Join-Path $target 'state') -Recurse -Force
  Remove-Item -LiteralPath $keepState -Recurse -Force
  Say "Maailman tila palautettiin." "Green"
}
foreach ($uf in $keepUser.Keys) {
  $tmp = $keepUser[$uf]
  if (Test-Path -LiteralPath $tmp) {
    Copy-Item -LiteralPath $tmp -Destination (Join-Path $target $uf) -Force
    Remove-Item -LiteralPath $tmp -Force
    Say "Omat asetukset sailytettiin: $uf" "Green"
  }
}
# The outfit and weapon tests of 1.7-1.8 (Christmas / ghillie pants, Asu = 0,
# M1911 / SCAR for everyone) end here: the KAIKKI test block is emptied, so the
# squad classes' own weapons (npc/weapons.lua) are used.
$gearPath0 = Join-Path $target 'varusteet.lua'
if (Test-Path -LiteralPath $gearPath0) {
  $g0 = [System.IO.File]::ReadAllText($gearPath0)
  $reK = [regex]'KAIKKI\s*=\s*\{(?:[^{}]|\{[^{}]*\})*\}'
  $m0 = $reK.Match($g0)
  if ($m0.Success -and $m0.Value -match 'Christmas_Pants_02|Ghillie_Suit_Pants_01|Asu\s*=|Weapon_M1911|Weapon_SCAR_DMR|Weapon_AS_Val') {
    $new = "KAIKKI = {`r`n    }"
    [System.IO.File]::WriteAllText($gearPath0, $g0.Substring(0, $m0.Index) + $new + $g0.Substring($m0.Index + $m0.Length))
    Say "varusteet.lua: testiaseet ja -asut poistettu (KAIKKI tyhjennetty)." "Green"
  }
}
# The example squad classes (firefighters, doctors) are removed from the
# owner's ryhmat.lua; their own classes stay.
$groupsPath = Join-Path $target 'ryhmat.lua'
if (Test-Path -LiteralPath $groupsPath) {
  $gr = [System.IO.File]::ReadAllText($groupsPath)
  $reG = [regex]'\{(?:[^{}]|\{[^{}]*\})*avain\s*=\s*"(palomiehet|laakarit)"(?:[^{}]|\{[^{}]*\})*\}\s*,?'
  if ($reG.IsMatch($gr)) {
    [System.IO.File]::WriteAllText($groupsPath, $reG.Replace($gr, ''))
    Say "ryhmat.lua: esimerkkiryhmat (palomiehet, laakarit) poistettu." "Green"
  }
}
# An older varusteet.lua has no KAIKKI section (gear for every squad). Add it
# right after "return {" with the owner's test item - their own lines stay.
$gearPath = Join-Path $target 'varusteet.lua'
if ((Test-Path -LiteralPath $gearPath)) {
  $gearText = [System.IO.File]::ReadAllText($gearPath)
  if ($gearText -notmatch 'KAIKKI' -and $gearText -match 'return\s*\{') {
    $block = "return {`r`n    -- KAIKKI: nama saa jokainen NPC jokaisessa ryhmassa (lisaksi ryhman omat).`r`n    KAIKKI = {`r`n    },"
    $gearText = ([regex]'return\s*\{').Replace($gearText, $block, 1)
    [System.IO.File]::WriteAllText($gearPath, $gearText)
    Say "varusteet.lua: lisattiin KAIKKI-kohta (tyhja)." "Green"
  }
}
if ($keepOutput) {
  Copy-Item -Path (Join-Path $keepOutput '*') -Destination $outDirEarly -Recurse -Force `
            -ErrorAction SilentlyContinue
  Remove-Item -LiteralPath $keepOutput -Recurse -Force
  Say "Live mapin tiedot sailytettiin." "Green"
}

$files = (Get-ChildItem -LiteralPath $target -Recurse -File).Count
Say "Kopioitu $files tiedostoa." "Green"

$lines = @()
if (Test-Path -LiteralPath $modsTxt) { $lines = @(Get-Content -LiteralPath $modsTxt) }
$lines = @($lines | Where-Object { $_ -notmatch "^\s*$MOD\s*:" })
$lines = $lines + @("$MOD : 1")
Set-Content -LiteralPath $modsTxt -Value $lines -Encoding ASCII
Set-Content -LiteralPath (Join-Path $target 'enabled.txt') -Value "" -Encoding ASCII

$registered = "mods.txt + enabled.txt"
$jsonEntries = Read-ModsJson $modsJson
if ($jsonEntries) {
  $jsonEntries = @($jsonEntries | Where-Object { $_.mod_name -ne $MOD })
  $jsonEntries += [pscustomobject]@{ mod_name = $MOD; mod_enabled = $true }
  Write-ModsJson $modsJson $jsonEntries
  $registered = "mods.json + mods.txt + enabled.txt"
}
Say "Rekisteroity: $registered" "Green"

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

if ($ue4ssUnchanged -and -not $global:TeslesLoaderAlreadyCurrent) {
  Say "UE4SS.dll on edelleen sama tiedosto kuin ennen asennusta." "Red"
  Say "Aja: lisatyokalut\INSTALL_UE4SS.bat -Force   ja katso mita se sanoo." "Yellow"
  Write-Host ""
} elseif ($health -and $health.verdict -in @("SCAN_ABORTED", "SCAN_LOOP")) {
  Say "HUOM: UE4SS ei edellisella kaynnistyksella paassyt modien lataukseen." "Yellow"
  Say "Lataaja vaihdettiin juuri uudempaan, joten kokeile kaynnistysta." "Yellow"
  Say "Jos sama toistuu, aja:  lisatyokalut\FIX_UE4SS_SCAN.bat -Auto" "Yellow"
  Say "Se etsii puuttuvan tavukuvion suoraan SCUMServer.exe:sta." "Yellow"
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
Say "Omat varusteet: $target\varusteet.lua" "DarkGray"
Say "Omat ryhmatyypit: $target\ryhmat.lua" "DarkGray"
Write-Host ""
if (-not $NoPause) { Read-Host "  Enter sulkee" }
