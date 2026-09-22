<#
  TESLES NPC OVERHAUL - installer.

  Copies the mod into the SCUM server's UE4SS Mods folder, registers it in
  mods.txt, and points the live map at the mod's output folder.

  The installer refuses to run while the server is up, backs up anything it
  replaces, and never touches the save game, the database or other mods.
#>
$ErrorActionPreference = "Stop"
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$MOD = "TeslesNPCOverhaul"

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
$server = $candidates | Where-Object {
  Test-Path -LiteralPath (Join-Path $_ 'SCUM\Binaries\Win64\SCUMServer.exe') -PathType Leaf
} | Select-Object -First 1

if (-not $server) {
  Say "SCUM-palvelinta ei loytynyt tavallisista poluista." "Yellow"
  $server = Read-Host "  Anna SCUM Server -kansion polku"
  $server = $server.Trim('"').Trim()
}
if (-not (Test-Path -LiteralPath (Join-Path $server 'SCUM\Binaries\Win64\SCUMServer.exe'))) {
  Say "Polusta ei loydy SCUMServer.exe:ta: $server" "Red"
  Read-Host "  Enter sulkee"
  exit 1
}

$win64 = Join-Path $server 'SCUM\Binaries\Win64'
$mods = Join-Path $win64 'Mods'
if (-not (Test-Path -LiteralPath $mods)) {
  # Newer UE4SS installs keep mods under ue4ss\Mods.
  $alt = Join-Path $win64 'ue4ss\Mods'
  if (Test-Path -LiteralPath $alt) { $mods = $alt }
}
if (-not (Test-Path -LiteralPath $mods)) {
  Say "UE4SS Mods -kansiota ei loydy: $mods" "Red"
  Say "Asenna UE4SS palvelimelle ensin." "Red"
  Read-Host "  Enter sulkee"
  exit 1
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
    $keepState = Join-Path $env:TEMP "tesles_state_$stamp"
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

Write-Host ""
Write-Host "  VALMIS" -ForegroundColor Green
Write-Host ""
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
Read-Host "  Enter sulkee"
