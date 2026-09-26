<#
  TESLES NPC OVERHAUL - uninstall.

  Removes the mod and undoes what INSTALL.bat changed:
    - the mod folder (a copy goes to <SCUM Server>\TeslesNPCOverhaul_Backups)
    - its mods.txt / mods.json entries
    - the UE4SS hook settings are put back as they were
    - Lua mods the installer switched off (-DisableOtherMods) are switched on
    - the live map is stopped
  and, only if you say so, removes UE4SS itself.
  The server's save game, database and settings are never touched.
#>
param(
  [string]$ServerRoot = "",
  [switch]$RemoveUE4SS,   # also remove UE4SS without asking
  [switch]$Yes,           # ask nothing (UE4SS stays unless -RemoveUE4SS)
  [switch]$NoPause
)
$ErrorActionPreference = "Stop"
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$MOD = "TeslesNPCOverhaul"
function Say($t, $c = "Gray") { Write-Host "  $t" -ForegroundColor $c }
function Done($code) {
  Write-Host ""
  if (-not $NoPause) { Read-Host "  Press Enter to close" }
  exit $code
}

Write-Host ""
Write-Host "  TESLES NPC OVERHAUL - uninstall" -ForegroundColor Yellow
Write-Host "  ==============================="

if (Get-Process -Name "SCUMServer" -ErrorAction SilentlyContinue) {
  Say "Stop the SCUM server first." "Red"
  Done 1
}

# ------------------------------------------------------ where it is ---
function Test-ServerRoot($p) {
  if (-not $p) { return $false }
  return Test-Path -LiteralPath (Join-Path $p 'SCUM\Binaries\Win64\SCUMServer.exe') -ErrorAction SilentlyContinue
}
$target = $null
$pathFile = Join-Path $here 'livemap\livemap_paths.txt'
if (Test-Path -LiteralPath $pathFile) {
  $out = (Get-Content -LiteralPath $pathFile -First 1).Trim()
  if ($out) { $target = Split-Path $out -Parent }
}
$server = $ServerRoot.Trim('"').Trim()
if (-not $target -or -not (Test-Path -LiteralPath $target)) {
  if (-not (Test-ServerRoot $server)) {
    $server = (Read-Host "  Path of the SCUM Server folder").Trim('"').Trim()
  }
  if (-not (Test-ServerRoot $server)) { Say "SCUMServer.exe not found under: $server" "Red"; Done 1 }
  $w = Join-Path $server 'SCUM\Binaries\Win64'
  foreach ($m in @((Join-Path $w 'ue4ss\Mods'), (Join-Path $w 'Mods'))) {
    if (Test-Path -LiteralPath (Join-Path $m $MOD)) { $target = Join-Path $m $MOD; break }
  }
}
if ($target) {
  $mods = Split-Path $target -Parent
} else {
  $w = Join-Path $server 'SCUM\Binaries\Win64'
  $mods = if (Test-Path (Join-Path $w 'ue4ss\Mods')) { Join-Path $w 'ue4ss\Mods' } else { Join-Path $w 'Mods' }
}
# ...\SCUM\Binaries\Win64\[ue4ss\]Mods
$win64 = Split-Path $mods -Parent
if ((Split-Path $win64 -Leaf) -eq 'ue4ss') { $win64 = Split-Path $win64 -Parent }
if (-not $server -or -not (Test-ServerRoot $server)) {
  $server = Split-Path (Split-Path (Split-Path $win64 -Parent) -Parent) -Parent
}
Say "Server: $server" "Green"

# ------------------------------------------------------ live map ---
try {
  $listen = Get-NetTCPConnection -LocalPort 8777 -State Listen -ErrorAction SilentlyContinue
  foreach ($c in @($listen)) {
    if ($c.OwningProcess) {
      $p = Get-Process -Id $c.OwningProcess -ErrorAction SilentlyContinue
      if ($p -and $p.ProcessName -match 'powershell|pwsh') {
        Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue
        Say "Live map stopped." "Green"
      }
    }
  }
} catch {}

# ------------------------------------------------------ the mod ---
$stamp = Get-Date -Format "yyyyMMdd-HHmmss"
$backupRoot = Join-Path $server 'TeslesNPCOverhaul_Backups'
if ($target -and (Test-Path -LiteralPath $target)) {
  $backup = Join-Path $backupRoot "uninstall-$stamp"
  New-Item -ItemType Directory -Path $backup -Force | Out-Null
  Copy-Item -LiteralPath $target -Destination (Join-Path $backup $MOD) -Recurse -Force
  Remove-Item -LiteralPath $target -Recurse -Force
  Say "Mod removed. A copy (with your saved world and settings): $backup" "Green"
} else {
  Say "The mod folder was not there any more." "Gray"
}

$modsTxt = Join-Path $mods 'mods.txt'
$modsJson = Join-Path $mods 'mods.json'
if (Test-Path -LiteralPath $modsTxt) {
  $lines = @(Get-Content -LiteralPath $modsTxt) | Where-Object { $_ -notmatch "^\s*$MOD\s*:" }
  Set-Content -LiteralPath $modsTxt -Value $lines -Encoding ASCII
  Say "mods.txt cleaned." "Green"
}
if (Test-Path -LiteralPath $modsJson) {
  try {
    $entries = @(Get-Content -LiteralPath $modsJson -Raw | ConvertFrom-Json | Where-Object { $_.mod_name -ne $MOD })
    $json = if ($entries.Count -eq 1) { "[" + ($entries | ConvertTo-Json -Depth 4) + "]" }
            elseif ($entries.Count -eq 0) { "[]" } else { $entries | ConvertTo-Json -Depth 4 }
    Set-Content -LiteralPath $modsJson -Value $json -Encoding ASCII
    Say "mods.json cleaned." "Green"
  } catch { Say "mods.json could not be read - left as it is." "Yellow" }
}

# ------------------------------------------------------ other mods back on ---
$lists = @()
if (Test-Path -LiteralPath $backupRoot) {
  $lists = @(Get-ChildItem -LiteralPath $backupRoot -Recurse -Filter 'disabled_mods.txt' -ErrorAction SilentlyContinue)
}
$again = @()
foreach ($f in $lists) {
  foreach ($name in (Get-Content -LiteralPath $f.FullName)) {
    $name = $name.Trim()
    if ($name -and $again -notcontains $name) { $again += $name }
  }
}
if ($again.Count -gt 0) {
  if (Test-Path -LiteralPath $modsTxt) {
    $lines = @(Get-Content -LiteralPath $modsTxt) | ForEach-Object {
      if ($_ -match '^\s*([A-Za-z0-9_\-\.]+)\s*:\s*0\s*$' -and $again -contains $Matches[1]) { "$($Matches[1]) : 1" } else { $_ }
    }
    Set-Content -LiteralPath $modsTxt -Value $lines -Encoding ASCII
  }
  foreach ($name in $again) {
    $parked = Join-Path (Join-Path $mods $name) 'enabled.txt.disabled'
    if (Test-Path -LiteralPath $parked) { Move-Item -LiteralPath $parked -Destination ($parked -replace '\.disabled$', '') -Force }
  }
  foreach ($f in $lists) { Rename-Item -LiteralPath $f.FullName -NewName 'disabled_mods.restored.txt' -Force -ErrorAction SilentlyContinue }
  Say ("Switched back on: {0}" -f ($again -join ', ')) "Green"
}

# ------------------------------------------------------ UE4SS settings ---
foreach ($ini in @((Join-Path $win64 'ue4ss\UE4SS-settings.ini'), (Join-Path $win64 'UE4SS-settings.ini'))) {
  foreach ($suffix in @('.tesles-hooks-backup', '.tesles-backup')) {
    $bak = "$ini$suffix"
    if (Test-Path -LiteralPath $bak) {
      Copy-Item -LiteralPath $bak -Destination $ini -Force
      Remove-Item -LiteralPath $bak -Force
      Say "UE4SS settings restored ($(Split-Path $ini -Leaf))." "Green"
    }
  }
}

# ------------------------------------------------------ UE4SS itself ---
$loader = @((Join-Path $win64 'dwmapi.dll'), (Join-Path $win64 'ue4ss')) | Where-Object { Test-Path -LiteralPath $_ }
if ($loader.Count -gt 0) {
  $others = @()
  if (Test-Path -LiteralPath $mods) {
    $others = @(Get-ChildItem -LiteralPath $mods -Directory -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -notin @('shared', 'Keybinds', 'ConsoleCommandsMod', 'ConsoleEnablerMod', 'BPModLoaderMod', 'BPML_GenericFunctions', 'LineTraceMod', 'SplitScreenMod', 'CheatManagerEnablerMod', 'ActorDumperMod', 'jsbLuaProfilerMod') })
  }
  $remove = [bool]$RemoveUE4SS
  if (-not $remove -and -not $Yes) {
    Write-Host ""
    if ($others.Count -gt 0) {
      Say ("Other mods still use UE4SS: {0}" -f (($others | ForEach-Object Name) -join ', ')) "Yellow"
    }
    $ans = Read-Host "  Also remove UE4SS (the Lua mod loader)? [y/N]"
    $remove = $ans -match '^\s*[yY]'
  }
  if ($remove) {
    $backup2 = Join-Path $backupRoot "ue4ss-$stamp"
    New-Item -ItemType Directory -Path $backup2 -Force | Out-Null
    foreach ($p in $loader) {
      Copy-Item -LiteralPath $p -Destination $backup2 -Recurse -Force
      Remove-Item -LiteralPath $p -Recurse -Force
    }
    Say "UE4SS removed (copy: $backup2)." "Green"
  } else {
    Say "UE4SS left in place." "Gray"
  }
}

Write-Host ""
Say "Done. TESLES NPC OVERHAUL is uninstalled." "Green"
Say "Backups stay in $backupRoot - delete that folder when you no longer need it." "DarkGray"
Done 0
