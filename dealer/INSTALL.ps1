<#
  TESLES DEALER - one-click install.

  Finds the SCUM dedicated server and installs the mod into UE4SS's Mods
  folder. UE4SS must already be installed (TESLES NPC OVERHAUL's installer
  does it, or any UE4SS release). An older TeslesDealer is backed up to
  <SCUM Server>\TeslesDealer_Backups and your config.lua is kept.
#>
param(
  [string]$ServerRoot = "",   # SCUM Server folder; found automatically
  [switch]$Yes,               # ask nothing
  [switch]$NoPause            # do not wait for Enter at the end
)

$ErrorActionPreference = "Stop"
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$MOD = "TeslesDealer"

function Say($t, $c = "Gray") { Write-Host "  $t" -ForegroundColor $c }
function Step($n, $t) {
  Write-Host ""
  Write-Host "  [$n/3] $t" -ForegroundColor Cyan
  Write-Host "  ------------------------------------------------" -ForegroundColor DarkGray
}
function Done($code) {
  Write-Host ""
  if (-not $NoPause) { Read-Host "  Press Enter to close" }
  exit $code
}
function Die($t) {
  Write-Host ""
  Say $t "Red"
  Done 1
}

Write-Host ""
Write-Host "  TESLES DEALER - install" -ForegroundColor Yellow
Write-Host "  ======================="
Say "Doctors buy cannabis buds, joints and psychedelic mushrooms" "DarkGray"
Say "dropped on their counter, and pay in SCUM cash." "DarkGray"
if (-not $Yes) {
  Write-Host ""
  $ans = Read-Host "  Continue? [Y/n]"
  if ($ans -match '^\s*[nN]') { exit 0 }
}

if (Get-Process -Name "SCUMServer" -ErrorAction SilentlyContinue) {
  Die "SCUMServer is running. Stop the server and run INSTALL.bat again."
}
if ($here -match "\\AppData\\Local\\Temp\\" -or $here -match "\.zip\\") {
  Die "Do not run the installer from inside the ZIP. Extract it to a folder first."
}
$src = Join-Path $here $MOD
if (-not (Test-Path -LiteralPath (Join-Path $src 'Scripts\main.lua'))) {
  Die "The $MOD folder is missing next to INSTALL.bat."
}

# ============================================================= 1. server ===
Step 1 "Finding the SCUM server"

function Test-ServerRoot($p) {
  if (-not $p) { return $false }
  try {
    return Test-Path -LiteralPath (Join-Path $p 'SCUM\Binaries\Win64\SCUMServer.exe') `
                     -PathType Leaf -ErrorAction SilentlyContinue
  } catch { return $false }
}

$server = $ServerRoot.Trim('"').Trim()
if (-not (Test-ServerRoot $server)) {
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
      foreach ($sub in @('SteamLibrary', 'Steam', '', 'Games', 'SCUM')) {
        [void]$roots.Add((Join-Path $d.Root $sub).TrimEnd('\'))
      }
    }
  }
  [void]$roots.Add('C:\Program Files (x86)\Steam')
  $server = $null
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
  Say "The SCUM server was not found automatically." "Yellow"
  $server = (Read-Host "  Path of the SCUM Server folder").Trim('"').Trim()
}
if (-not (Test-ServerRoot $server)) { Die "SCUMServer.exe not found under: $server" }
Say "Server: $server" "Green"

$win64 = Join-Path (Join-Path (Join-Path $server 'SCUM') 'Binaries') 'Win64'
$mods = $null
foreach ($cand in @((Join-Path (Join-Path $win64 'ue4ss') 'Mods'), (Join-Path $win64 'Mods'))) {
  if (Test-Path -LiteralPath $cand) { $mods = $cand; break }
}
if (-not $mods) {
  Say "UE4SS (the Lua mod loader) is not installed on this server." "Red"
  Say "Install TESLES NPC OVERHAUL (its INSTALL.bat installs UE4SS), or UE4SS" "Yellow"
  Say "from https://github.com/UE4SS-RE/RE-UE4SS/releases, then run this again." "Yellow"
  Done 1
}
Say "Mods: $mods" "Green"

# ============================================================== 2. copy ===
Step 2 "Installing $MOD"

$target = Join-Path $mods $MOD
$keptConfig = $null
if (Test-Path -LiteralPath $target) {
  $backupRoot = Join-Path $server 'TeslesDealer_Backups'
  $backup = Join-Path $backupRoot (Get-Date -Format "yyyyMMdd-HHmmss")
  New-Item -ItemType Directory -Path $backup -Force | Out-Null
  Copy-Item -LiteralPath $target -Destination $backup -Recurse -Force
  Say "Old version backed up: $backup" "DarkGray"
  $oldCfg = Join-Path $target 'config.lua'
  if (Test-Path -LiteralPath $oldCfg) { $keptConfig = Get-Content -LiteralPath $oldCfg -Raw }
  $oldLog = Join-Path $target 'dealer.log'
  $keptLog = $null
  if (Test-Path -LiteralPath $oldLog) { $keptLog = Get-Content -LiteralPath $oldLog -Raw }
  Remove-Item -LiteralPath $target -Recurse -Force
}
Copy-Item -LiteralPath $src -Destination $target -Recurse -Force
if ($keptConfig) {
  Set-Content -LiteralPath (Join-Path $target 'config.lua') -Value $keptConfig -NoNewline -Encoding UTF8
  Say "Your config.lua (prices and settings) kept." "Green"
}
if ($keptLog) {
  Set-Content -LiteralPath (Join-Path $target 'dealer.log') -Value $keptLog -NoNewline -Encoding UTF8
}
Say ("Copied {0} files." -f (Get-ChildItem -LiteralPath $target -Recurse -File).Count) "Green"

# ========================================================== 3. register ===
Step 3 "Switching the mod on"

$modsTxt = Join-Path $mods 'mods.txt'
$lines = @()
if (Test-Path -LiteralPath $modsTxt) { $lines = @(Get-Content -LiteralPath $modsTxt) }
$lines = @($lines | Where-Object { $_ -notmatch "^\s*$MOD\s*:" })
$lines = $lines + @("$MOD : 1")
Set-Content -LiteralPath $modsTxt -Value $lines -Encoding ASCII
Set-Content -LiteralPath (Join-Path $target 'enabled.txt') -Value "" -Encoding ASCII
$registered = "mods.txt + enabled.txt"

# Newer UE4SS builds read mods.json first: it has to say the same.
$modsJson = Join-Path $mods 'mods.json'
if (Test-Path -LiteralPath $modsJson) {
  try {
    $entries = @(Get-Content -LiteralPath $modsJson -Raw | ConvertFrom-Json)
    $entries = @($entries | Where-Object { $_.mod_name -ne $MOD })
    $entries += [pscustomobject]@{ mod_name = $MOD; mod_enabled = $true }
    $json = if ($entries.Count -eq 1) { "[" + ($entries | ConvertTo-Json -Depth 4) + "]" }
            else { $entries | ConvertTo-Json -Depth 4 }
    Set-Content -LiteralPath $modsJson -Value $json -Encoding ASCII
    $registered = "mods.json + mods.txt + enabled.txt"
  } catch {
    Say "mods.json could not be read; mods.txt and enabled.txt are set." "Yellow"
  }
}
Say "Registered: $registered" "Green"

Write-Host ""
Say "Done. Start the server." "Green"
Say "Prices: $target\config.lua" "Gray"
Say "Log:    $target\dealer.log (lists the traders it found and every sale)" "Gray"
Done 0
