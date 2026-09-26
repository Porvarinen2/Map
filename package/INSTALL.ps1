<#
  TESLES NPC OVERHAUL - one-click install.

  Finds the SCUM dedicated server, installs or updates UE4SS, installs the
  mod, prepares the map and starts the live map.

  The server's save game, database and settings are never touched.
  Everything that is replaced is backed up to
  <SCUM Server>\TeslesNPCOverhaul_Backups. UNINSTALL.bat removes it all.
#>
param(
  [string]$ServerRoot = "",   # SCUM Server folder; found automatically
  [switch]$SkipUE4SS,         # leave the UE4SS installation alone
  [switch]$DisableOtherMods,  # switch other UE4SS Lua mods off
  [switch]$KeepOtherMods,     # (default) leave other Lua mods on
  [switch]$NoMap,             # no map tiles, no live map
  [switch]$Yes,               # ask nothing
  [switch]$NoPause            # do not wait for Enter at the end
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
  if (-not $NoPause) { Read-Host "  Press Enter to close" }
  exit 1
}

$warnings = @()
$ue4ssUnchanged = $false

Write-Host ""
Write-Host "  TESLES NPC OVERHAUL - install" -ForegroundColor Yellow
Write-Host "  ============================="
Say "This installs everything the mod needs:" "DarkGray"
Say "  - UE4SS (the Lua mod loader) into your SCUM server" "DarkGray"
Say "  - the mod itself, and the live map" "DarkGray"
Say "Everything replaced is backed up; UNINSTALL.bat undoes it all." "DarkGray"
if (-not $Yes) {
  Write-Host ""
  $ans = Read-Host "  Continue? [Y/n]"
  if ($ans -match '^\s*[nN]') { exit 0 }
}

# ---------------------------------------------------------------- guards ---

if (Get-Process -Name "SCUMServer" -ErrorAction SilentlyContinue) {
  Die "SCUMServer is running. Stop the server and run INSTALL.bat again."
}
if ($here -match "\\AppData\\Local\\Temp\\" -or $here -match "\.zip\\") {
  Die "Do not run the installer from inside the ZIP. Extract the package to a folder first."
}

# ============================================================= 1. server ===
Step 1 "Finding the SCUM server"

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
# Not in the usual places: Steam's library list and every drive's
# steamapps\common folders (a whole-disk search would take minutes).
if (-not $server) {
  Say "Not in the usual places. Searching the Steam libraries..." "Yellow"
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
  Say "The SCUM server was not found automatically." "Yellow"
  $server = (Read-Host "  Path of the SCUM Server folder").Trim('"').Trim()
}
if (-not (Test-ServerRoot $server)) {
  Die "SCUMServer.exe not found under: $server"
}

$win64 = Join-Path $server 'SCUM\Binaries\Win64'
Say "Server: $server" "Green"

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
Step 2 "UE4SS (Lua mod loader)"

if ($SkipUE4SS) {
  Say "Skipped (-SkipUE4SS)." "Yellow"
} else {
  # An earlier scan fix from this package did not help and slowed the start
  # by two minutes; it is reverted before the update.
  $fix = Join-Path $here 'FIX_UE4SS_SCAN.ps1'
  if (Test-Path $fix) {
    $ini = Join-Path $win64 'UE4SS-settings.ini'
    if (Test-Path "$ini.tesles-backup") {
      Say "Reverting an earlier scan fix..." "Yellow"
      try { & $fix -Win64 $win64 -Revert | Out-Null } catch {}
    }
  }

  $installer = Join-Path $here 'INSTALL_UE4SS.ps1'
  if (-not (Test-Path $installer)) {
    Die "INSTALL_UE4SS.ps1 is missing from the package."
  }

  $global:TeslesLoaderAlreadyCurrent = $false
  $had = Test-Loader $win64
  $beforeHash = Get-LoaderStamp $win64
  if ($had) {
    Say "UE4SS is installed - replacing it with the version in this package." "Gray"
  } else {
    Say "UE4SS is missing - installing it." "Gray"
  }
  try {
    & $installer -Win64 $win64 -Yes -Force -Chained
  } catch {
    Say "UE4SS install stopped: $($_.Exception.Message)" "Red"
  }
  $afterHash = Get-LoaderStamp $win64
  if ($global:TeslesLoaderAlreadyCurrent) {
    Say "UE4SS is up to date." "Green"
  } elseif ($had -and $beforeHash -and $beforeHash -eq $afterHash) {
    # 1.0.8 said it updated the loader while the file on disk never changed.
    # Whatever the cause, the summary has to show it instead of hiding it.
    $ue4ssUnchanged = $true
    Say "WARNING: UE4SS.dll did not change." "Red"
  } elseif ($afterHash) {
    Say "The UE4SS loader has been replaced." "Green"
  }

  if (-not (Test-Loader $win64)) {
    Write-Host ""
    Say "UE4SS is not installed, so the mod cannot run." "Red"
    Say "The download failed (network, firewall or GitHub's rate limit)." "Yellow"
    Write-Host ""
    Say "Do this:" "Cyan"
    Say "  1. Open https://github.com/UE4SS-RE/RE-UE4SS/releases" "Cyan"
    Say "  2. Download the latest UE4SS_vX.Y.Z.zip" "Cyan"
    Say "  3. tools\INSTALL_UE4SS.bat -Force -ZipFile C:\path\UE4SS.zip" "Cyan"
    Say "  4. Run INSTALL.bat again." "Cyan"
    Die "Install stopped."
  }
  if (-not $had) { Say "UE4SS installed." "Green" }
}

$mods = Resolve-ModsDir $win64
if (-not $mods) {
  $mods = Join-Path $win64 'Mods'
  New-Item -ItemType Directory -Path $mods -Force | Out-Null
  Set-Content -LiteralPath (Join-Path $mods 'mods.txt') -Value @("Keybinds : 1") -Encoding ASCII
  Say "Created the Mods folder." "Yellow"
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
    Say "UE4SS-settings.ini not found - hooks unchanged." "Yellow"
  } elseif ($hooksOff.Count -gt 0) {
    Say ("UE4SS hooks the mod does not need switched off ({0}) - EngineTick stays." -f $hooksOff.Count) "Green"
  } else {
    Say "UE4SS hooks already minimal (EngineTick only)." "Green"
  }
}

# ========================================================= 3. other mods ===
Step 3 "Other Lua mods"

if (-not $DisableOtherMods) {
  Say "Other UE4SS Lua mods are left as they are (-DisableOtherMods switches them off)." "Gray"
} else {
  # Two mods commanding the same NPCs fight each other. Nothing is deleted,
  # only switched off (the list is saved with the backup).
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

  # UE4SS also starts any folder with an enabled.txt, whatever mods.txt says,
  # so those markers are parked.
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
      Say "mods.json updated to match mods.txt." "Gray"
    }
  }

  if ($off.Count -gt 0) {
    Say ("Switched off ({0}): {1}" -f $off.Count, ($off -join ', ')) "Yellow"
    Set-Content -LiteralPath (Join-Path $backup 'disabled_mods.txt') `
                -Value $off -Encoding ASCII
    Say "List saved: $backup\disabled_mods.txt" "DarkGray"
  } else {
    Say "No other mods were on." "Green"
  }
}

# ================================================================ 4. mod ===
Step 4 "Installing TESLES NPC OVERHAUL"

$target = Join-Path $mods $MOD
$keepState = $null
$keepOutput = $null
$keepUser = @{}
$keepCfg = @{}
if (Test-Path -LiteralPath $target) {
  Copy-Item -LiteralPath $target -Destination (Join-Path $backup $MOD) -Recurse -Force
  Say "The previous version was backed up." "Gray"
  # Two folders have to survive an update: the saved world, and the output the
  # live map reads. Wiping output\ made the map say "live_state.json does not
  # exist yet" after every reinstall, which looked like the mod had never run.
  # The owner's own files survive every update: squad gear and own classes.
  $keepUser = @{}
  foreach ($uf in @('loadouts.lua', 'squads.lua', 'varusteet.lua', 'ryhmat.lua')) {
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
  if ($keepState) { Say "Saved world kept." "Green" }
  # The owner's ghost weapon chance survives an update (1.9.21 had 0.5 as
  # its default; from 1.9.22 on the default is 1.0, so that one is not kept).
  $oldCfg = Join-Path $target 'config.lua'
  if (Test-Path -LiteralPath $oldCfg) {
    $oc = Get-Content -LiteralPath $oldCfg -Raw
    $mv = [regex]::Match($oc, 'Version\s*=\s*"([^"]+)"')
    foreach ($key in @('Language', 'TargetNPCs', 'EnableReplenish', 'GhostWeaponChance', 'TopWeaponChance', 'NPCDetectRangeM', 'NPCFireRangeM', 'NPCScopedFireRangeM', 'NPCViewAngleDeg', 'NPCCloseSenseM')) {
      $mg = [regex]::Match($oc, "$key\s*=\s*(`"[a-z]+`"|true|false|[0-9.]+)")
      if (-not $mg.Success) { continue }
      # Up to 1.9.31 GhostWeaponChance held an old default (0.5 / 1.0); from
      # 1.9.32 on the default is 0 (vanilla weapons), so older values are not kept.
      if ($key -eq 'GhostWeaponChance') {
        $ov = $null
        if ($mv.Success) { try { $ov = [version]$mv.Groups[1].Value } catch { $ov = $null } }
        if (-not $ov -or $ov -lt [version]'1.9.32') { continue }
      }
      # 1.9.27 had the first sight defaults (200 m / 60 deg...); 1.9.28 brings new ones.
      if ($key -like 'NPC*' -and $mv.Success -and $mv.Groups[1].Value -eq '1.9.27') { continue }
      $keepCfg[$key] = $mg.Groups[1].Value
    }
  }
  Remove-Item -LiteralPath $target -Recurse -Force
}

$src = Join-Path $here "mod\$MOD"
if (-not (Test-Path -LiteralPath $src)) { Die "mod\$MOD is missing from the package" }
Copy-Item -LiteralPath $src -Destination $target -Recurse -Force
New-Item -ItemType Directory -Path (Join-Path $target 'state') -Force | Out-Null
$outDirEarly = Join-Path $target 'output'
New-Item -ItemType Directory -Path $outDirEarly -Force | Out-Null

if ($keepState) {
  Copy-Item -Path (Join-Path $keepState '*') -Destination (Join-Path $target 'state') -Recurse -Force
  Remove-Item -LiteralPath $keepState -Recurse -Force
  Say "Saved world restored." "Green"
}
if ($keepCfg.Count -gt 0) {
  $newCfg = Join-Path $target 'config.lua'
  $nc = Get-Content -LiteralPath $newCfg -Raw
  foreach ($key in $keepCfg.Keys) {
    $nc = [regex]::Replace($nc, "$key\s*=\s*(`"[a-z]+`"|true|false|[0-9.]+)", "$key = $($keepCfg[$key])")
    Say "Your setting kept: $key = $($keepCfg[$key])" "Green"
  }
  [System.IO.File]::WriteAllText($newCfg, $nc, (New-Object System.Text.UTF8Encoding($false)))
}
foreach ($uf in $keepUser.Keys) {
  $tmp = $keepUser[$uf]
  if (Test-Path -LiteralPath $tmp) {
    Copy-Item -LiteralPath $tmp -Destination (Join-Path $target $uf) -Force
    Remove-Item -LiteralPath $tmp -Force
    Say "Your file kept: $uf" "Green"
  }
}
# Older installs kept their files under Finnish names (varusteet.lua,
# ryhmat.lua): they become loadouts.lua and squads.lua.
foreach ($pair in @(@('varusteet.lua', 'loadouts.lua'), @('ryhmat.lua', 'squads.lua'))) {
  $old = Join-Path $target $pair[0]
  $new = Join-Path $target $pair[1]
  # The old file is still there only until it has been moved once, so it
  # holds the owner's lines and wins over the new name.
  if (Test-Path -LiteralPath $old) {
    Move-Item -LiteralPath $old -Destination $new -Force
    Say ("{0} is now {1}" -f $pair[0], $pair[1]) "Green"
  }
}
if ($keepOutput) {
  Copy-Item -Path (Join-Path $keepOutput '*') -Destination $outDirEarly -Recurse -Force `
            -ErrorAction SilentlyContinue
  Remove-Item -LiteralPath $keepOutput -Recurse -Force
  Say "Live map data kept." "Green"
}

$files = (Get-ChildItem -LiteralPath $target -Recurse -File).Count
Say "Copied $files files." "Green"

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
Say "Registered: $registered" "Green"

$outDir = Join-Path $target 'output'
Set-Content -LiteralPath (Join-Path $here 'livemap\livemap_paths.txt') `
            -Value $outDir -Encoding UTF8

# An old boot log would be read as this start's log.
$oldBoot = Join-Path $outDir 'boot.log'
if (Test-Path $oldBoot) { Remove-Item $oldBoot -Force }

# ================================================================ 5. map ===
Step 5 "Map"

$mapDir = Join-Path $here 'livemap\map'
$tileIdx = Join-Path $mapDir 'tiles\meta.json'
if ($NoMap) {
  Say "Skipped (-NoMap)." "Yellow"
} elseif (Test-Path $tileIdx) {
  Say "The high resolution map is ready." "Green"
} else {
  $hires = $null
  if (Test-Path $mapDir) {
    $hires = Get-ChildItem -LiteralPath $mapDir -File -ErrorAction SilentlyContinue |
             Where-Object { $_.Name -ne 'scum_map.png' -and $_.Length -gt 5MB } |
             Sort-Object Length -Descending | Select-Object -First 1
  }
  if ($hires) {
    Say "Cutting $($hires.Name) into tiles - this takes a few minutes..." "Yellow"
    try {
      & (Join-Path $here 'livemap\tile_map.ps1') -Source $hires.FullName
    } catch {
      Say "Tiling failed: $($_.Exception.Message)" "Red"
      $warnings += "Tiling the high resolution map failed; the live map uses the basic map."
    }
  } else {
    Say "No high resolution map - using the package's basic map." "Gray"
    Say "Optional: save the 14k map as scum_map_hires.png" "DarkGray"
    Say "in livemap\map\ and run INSTALL.bat again (see README)." "DarkGray"
  }
}
if (-not (Test-Path (Join-Path $mapDir 'scum_map.png'))) {
  $warnings += "livemap\map\scum_map.png is missing - extract the package again."
}

# =========================================================== 6. live map ===
Step 6 "Live map"

$mapStarted = $false
if ($NoMap) {
  Say "Skipped (-NoMap)." "Yellow"
} else {
  $busy = $null
  try {
    $busy = Get-NetTCPConnection -LocalPort 8777 -State Listen -ErrorAction SilentlyContinue
  } catch {}
  if ($busy) {
    Say "The live map is already running on port 8777." "Green"
    $mapStarted = $true
  } else {
    try {
      Start-Process -FilePath "powershell.exe" -WorkingDirectory $here -ArgumentList @(
        "-NoLogo", "-NoProfile", "-ExecutionPolicy", "Bypass",
        "-File", (Join-Path $here 'livemap\server.ps1'), "-Port", "8777"
      ) | Out-Null
      Start-Sleep -Seconds 2
      Start-Process "http://127.0.0.1:8777/" | Out-Null
      Say "The live map started in its own window." "Green"
      Say "Address: http://127.0.0.1:8777/" "Green"
      Say "Keep that window open while you want the map." "DarkGray"
      $mapStarted = $true
    } catch {
      Say "Could not start the live map: $($_.Exception.Message)" "Yellow"
      Say "Start it by hand: START_LIVEMAP.bat" "Yellow"
    }
  }
}

# ============================================================== summary ===

# The mod is in place, but it only runs if UE4SS gets as far as loading mods.
# If the previous start proved it does not, better to say so now.
$health = $null
try { $health = Get-UE4SSHealth $win64 } catch {}

Write-Host ""
Write-Host "  ================================================" -ForegroundColor Green
Write-Host "   DONE - everything is installed" -ForegroundColor Green
Write-Host "  ================================================" -ForegroundColor Green
Write-Host ""

if ($ue4ssUnchanged -and -not $global:TeslesLoaderAlreadyCurrent) {
  Say "UE4SS.dll is still the same file as before the install." "Red"
  Say "Run: tools\INSTALL_UE4SS.bat -Force   and see what it says." "Yellow"
  Write-Host ""
} elseif ($health -and $health.verdict -in @("SCAN_ABORTED", "SCAN_LOOP")) {
  Say "NOTE: on the last start UE4SS did not get as far as loading mods." "Yellow"
  Say "The loader was just replaced, so try starting the server." "Yellow"
  Say "If it happens again, run:  tools\FIX_UE4SS_SCAN.bat -Auto" "Yellow"
  Say "It finds the missing byte pattern in SCUMServer.exe itself." "Yellow"
  Write-Host ""
}
foreach ($w in $warnings) { Say "WARNING: $w" "Yellow" }
if ($warnings.Count -gt 0) { Write-Host "" }

Say "One thing left for you:" "Cyan"
Say "  ->  Start the SCUM server as usual." "Cyan"
Write-Host ""
Say "The mod writes this file as soon as the server starts"
Say "  $outDir\boot.log"
Say "and starts working 25 seconds later."
if ($mapStarted) {
  Say "Live map paivittyy itsestaan: http://127.0.0.1:8777/"
} else {
  Say "Live map: START_LIVEMAP.bat  ->  http://127.0.0.1:8777/"
}
Write-Host ""
Say "If something does not work, run DIAGNOSE.bat." "DarkGray"
Say "Settings: $target\config.lua" "DarkGray"
Say "Your squad weapons: $target\loadouts.lua" "DarkGray"
Say "Your own squad types: $target\squads.lua" "DarkGray"
Write-Host ""
if (-not $NoPause) { Read-Host "  Press Enter to close" }
