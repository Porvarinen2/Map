<#
  TESLES NPC OVERHAUL - installer.

  Copies the mod into the SCUM server's UE4SS Mods folder, registers it in
  mods.txt, and points the live map at the mod's output folder.

  The installer refuses to run while the server is up, backs up anything it
  replaces, and never touches the save game, the database or other mods.
#>
param(
  [string]$ServerRoot = "",   # SCUM Server folder; autodetected when omitted
  [switch]$Yes,               # answer the UE4SS install prompt with yes
  [switch]$NoPause            # do not wait for Enter at the end
)

$ErrorActionPreference = "Stop"
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$MOD = "TeslesNPCOverhaul"
. (Join-Path $here 'ue4ss_health.ps1')

function Say($t, $c = "Gray") { Write-Host "  $t" -ForegroundColor $c }

Write-Host ""
Write-Host "  TESLES NPC OVERHAUL - asennus" -ForegroundColor Yellow
Write-Host "  =============================="
Write-Host ""

# ---------------------------------------------------------------- guards ---

$running = Get-Process -Name "SCUMServer" -ErrorAction SilentlyContinue
if ($running) {
  Say "SCUMServer on kaynnissa. Sammuta palvelin ensin." "Red"
  Write-Host ""
  Read-Host "  Enter sulkee"
  exit 1
}

if ($here -match "\\AppData\\Local\\Temp\\" -or $here -match "\.zip\\") {
  Say "Ala aja asennusta ZIPin sisalta. Pura paketti omaan kansioon." "Red"
  Read-Host "  Enter sulkee"
  exit 1
}

# ------------------------------------------------------------ server path --

$candidates = @(
  'F:\SteamLibrary\steamapps\common\SCUM Server',
  'D:\SteamLibrary\steamapps\common\SCUM Server',
  'E:\SteamLibrary\steamapps\common\SCUM Server',
  'C:\SteamLibrary\steamapps\common\SCUM Server',
  'C:\Program Files (x86)\Steam\steamapps\common\SCUM Server',
  'C:\Program Files\Steam\steamapps\common\SCUM Server'
)
# A candidate can name a drive that is not present; that must not be fatal.
$server = $ServerRoot
if (-not $server) {
  $server = $candidates | Where-Object {
    Test-Path -LiteralPath (Join-Path $_ 'SCUM\Binaries\Win64\SCUMServer.exe') `
      -PathType Leaf -ErrorAction SilentlyContinue
  } | Select-Object -First 1
}

if (-not $server) {
  Say "SCUM-palvelinta ei loytynyt tavallisista poluista." "Yellow"
  $server = Read-Host "  Anna SCUM Server -kansion polku"
  $server = $server.Trim('"').Trim()
}
if (-not (Test-Path -LiteralPath (Join-Path $server 'SCUM\Binaries\Win64\SCUMServer.exe') `
          -ErrorAction SilentlyContinue)) {
  Say "Polusta ei loydy SCUMServer.exe:ta: $server" "Red"
  Read-Host "  Enter sulkee"
  exit 1
}

$win64 = Join-Path $server 'SCUM\Binaries\Win64'

function Resolve-ModsDir($w) {
  foreach ($n in @(@('Mods'), @('ue4ss', 'Mods'))) {
    $p = $w
    foreach ($seg in $n) { $p = Join-Path $p $seg }
    if (Test-Path -LiteralPath $p) { return $p }
  }
  return $null
}

$mods = Resolve-ModsDir $win64

# A clean SCUM server has no UE4SS at all. Offer to install it rather than
# stopping with a requirement the user then has to satisfy by hand.
if (-not $mods) {
  $hasLoader = (Test-Path (Join-Path $win64 'UE4SS.dll')) -or
               (Test-Path (Join-Path (Join-Path $win64 'ue4ss') 'UE4SS.dll'))
  Write-Host ""
  if ($hasLoader) {
    Say "UE4SS on asennettu mutta Mods-kansio puuttuu. Luodaan se." "Yellow"
    $mods = Join-Path $win64 'Mods'
    New-Item -ItemType Directory -Path $mods -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $mods 'mods.txt') -Value @("Keybinds : 1") -Encoding ASCII
  } else {
    Say "UE4SS puuttuu palvelimelta. Tama modi on UE4SS-Lua-modi," "Yellow"
    Say "joten se on asennettava ensin." "Yellow"
    Write-Host ""
    $ans = if ($Yes) { "k" } else { Read-Host "  Asennetaanko UE4SS nyt GitHubista? (K/e)" }
    if (-not $ans -or $ans -match '^[kKyY]') {
      $ue4ss = Join-Path $here 'INSTALL_UE4SS.ps1'
      if (Test-Path $ue4ss) {
        & $ue4ss -Win64 $win64 -Yes
        $mods = Resolve-ModsDir $win64
      } else {
        Say "INSTALL_UE4SS.ps1 puuttuu paketista." "Red"
      }
    }
    if (-not $mods) {
      Write-Host ""
      Say "UE4SS ei ole asennettuna, joten modia ei voi asentaa." "Red"
      Say "Asenna se: INSTALL_UE4SS.bat" "Yellow"
      Say "tai kasin: https://github.com/UE4SS-RE/RE-UE4SS/releases" "Yellow"
      Read-Host "  Enter sulkee"
      exit 1
    }
  }
}

Say "Palvelin : $server" "Green"
Say "Mods     : $mods" "Green"

# ---------------------------------------------------------------- backup ---

$target = Join-Path $mods $MOD
$backupRoot = Join-Path $server 'TeslesNPCOverhaul_Backups'
$stamp = Get-Date -Format "yyyyMMdd-HHmmss"
$backup = Join-Path $backupRoot $stamp
$modsTxt = Join-Path $mods 'mods.txt'

$keepState = $null
if (Test-Path -LiteralPath $target) {
  New-Item -ItemType Directory -Path $backup -Force | Out-Null
  Copy-Item -LiteralPath $target -Destination (Join-Path $backup $MOD) -Recurse -Force
  Say "Varmuuskopio: $backup"

  # The persistent world is the one thing an update must not throw away.
  $stateSrc = Join-Path $target 'state'
  if (Test-Path -LiteralPath $stateSrc) {
    $keepState = Join-Path ([System.IO.Path]::GetTempPath()) "tesles_state_$stamp"
    Copy-Item -LiteralPath $stateSrc -Destination $keepState -Recurse -Force
    Say "Maailman tila otettiin talteen paivitysta varten." "Green"
  }
  Remove-Item -LiteralPath $target -Recurse -Force
}

if (Test-Path -LiteralPath $modsTxt) {
  if (-not (Test-Path -LiteralPath $backup)) { New-Item -ItemType Directory -Path $backup -Force | Out-Null }
  Copy-Item -LiteralPath $modsTxt -Destination (Join-Path $backup 'mods.txt') -Force
}

# ------------------------------------------------------------------ copy ---

$src = Join-Path $here "mod\$MOD"
if (-not (Test-Path -LiteralPath $src)) {
  Say "Paketista puuttuu mod\$MOD" "Red"
  Read-Host "  Enter sulkee"
  exit 1
}
Copy-Item -LiteralPath $src -Destination $target -Recurse -Force
New-Item -ItemType Directory -Path (Join-Path $target 'state') -Force | Out-Null
New-Item -ItemType Directory -Path (Join-Path $target 'output') -Force | Out-Null

if ($keepState) {
  Copy-Item -Path (Join-Path $keepState '*') -Destination (Join-Path $target 'state') -Recurse -Force
  Remove-Item -LiteralPath $keepState -Recurse -Force
  Say "Maailman tila palautettiin." "Green"
}

$files = (Get-ChildItem -LiteralPath $target -Recurse -File).Count
Say "Kopioitu $files tiedostoa -> $target" "Green"

# -------------------------------------------------------------- mods.txt ---

$lines = @()
if (Test-Path -LiteralPath $modsTxt) {
  $lines = @(Get-Content -LiteralPath $modsTxt)
}
$lines = $lines | Where-Object { $_ -notmatch "^\s*$MOD\s*:" }

# The old World Director must not run alongside this one: both would command
# the same NPCs. It is disabled, not deleted, so it can be switched back.
$disabled = @()
$lines = $lines | ForEach-Object {
  if ($_ -match "^\s*TeslesWorldDirector\s*:\s*1") {
    $disabled += "TeslesWorldDirector"
    "TeslesWorldDirector : 0"
  } else { $_ }
}
$lines = @($lines) + @("$MOD : 1")
Set-Content -LiteralPath $modsTxt -Value $lines -Encoding ASCII
Say "mods.txt paivitetty ($MOD : 1)" "Green"
if ($disabled.Count -gt 0) {
  Say "Vanha TeslesWorldDirector otettiin pois kaytosta." "Yellow"
}

# Some UE4SS builds also read an enabled.txt marker inside the mod folder.
Set-Content -LiteralPath (Join-Path $target 'enabled.txt') -Value "" -Encoding ASCII

$oldDir = Join-Path $mods 'TeslesWorldDirector'
if (Test-Path -LiteralPath $oldDir) {
  $oldEnabled = Join-Path $oldDir 'enabled.txt'
  if (Test-Path -LiteralPath $oldEnabled) {
    Move-Item -LiteralPath $oldEnabled -Destination "$oldEnabled.disabled" -Force
    Say "TeslesWorldDirector\enabled.txt siirrettiin syrjaan." "Yellow"
  }
}

# ------------------------------------------------------------- live map ----

$outDir = Join-Path $target 'output'
$pathFile = Join-Path $here 'livemap\livemap_paths.txt'
Set-Content -LiteralPath $pathFile -Value $outDir -Encoding UTF8
Say "Live map osoittaa kansioon: $outDir" "Green"

# The live map needs its base image; without it the page is just a grid.
$baseMap = Join-Path $here 'livemap\map\scum_map.png'
if (Test-Path $baseMap) {
  Say "Karttakuva loytyy." "Green"
} else {
  Say "VAROITUS: livemap\map\scum_map.png puuttuu." "Yellow"
  Say "Live map nayttaa tyhjan ruudukon kunnes kuva on paikallaan." "Yellow"
  Say "Pura paketti uudestaan tai aja SETUP_HIRES_MAP.bat." "Yellow"
}

# A stale boot log from the previous install would be read as this one's.
$oldBoot = Join-Path $outDir 'boot.log'
if (Test-Path $oldBoot) { Remove-Item $oldBoot -Force }

# The mod is in place, but it can only run if UE4SS reaches mod loading. If a
# previous server start already proved it does not, say so here rather than
# letting the user find out after another restart.
$health = $null
try { $health = Get-UE4SSHealth $win64 } catch {}

Write-Host ""
Write-Host "  VALMIS" -ForegroundColor Green
Write-Host ""

if ($health -and $health.verdict -in @("SCAN_ABORTED", "SCAN_LOOP", "NO_MODS_STARTED")) {
  Say "MUTTA: UE4SS ei edellisella kaynnistyksella ladannut yhtaan Lua-modia." "Red"
  Write-UE4SSHealth $health
  Say "Tee yllaoleva korjaus ennen kuin kaynnistat palvelimen." "Yellow"
  Write-Host ""
}
Say "1. Kaynnista SCUM-palvelin normaalisti."
Say "2. Odota noin minuutti. Mod kirjoittaa heti tiedoston"
Say "   $outDir\boot.log"
Say "   ja kaynnistyy 25 s viiveella."
Say "3. Aja START_LIVEMAP.bat ja avaa http://127.0.0.1:8777/"
Say "4. Tarkista tilanne: CHECK.bat"
Say "5. Jos jokin on pielessa: DIAGNOSE.bat"
Write-Host ""
Say "Asetukset: $target\config.lua"
Write-Host ""
if (-not $NoPause) { Read-Host "  Enter sulkee" }
