<# TESLES NPC OVERHAUL - status check. Reports what the mod has actually
   proven on this server, not what it is supposed to do. #>
$ErrorActionPreference = "SilentlyContinue"
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$MOD = "TeslesNPCOverhaul"
. (Join-Path $here 'ue4ss_health.ps1')

function Say($t, $c = "Gray") { Write-Host "  $t" -ForegroundColor $c }

Write-Host ""
Write-Host "  TESLES NPC OVERHAUL - status" -ForegroundColor Yellow
Write-Host "  ============================"
Write-Host ""

$pathFile = Join-Path $here 'livemap\livemap_paths.txt'
$out = $null
if (Test-Path $pathFile) { $out = (Get-Content $pathFile -First 1).Trim() }
if (-not $out -or -not (Test-Path $out)) {
  Say "The mod output folder is not found. Has INSTALL.bat been run?" "Red"
  Read-Host "  Press Enter to close"
  exit 1
}
Say "Output: $out"

$proc = Get-Process -Name "SCUMServer" -ErrorAction SilentlyContinue
if ($proc) { Say "SCUMServer: running (PID $($proc.Id))" "Green" }
else { Say "SCUMServer: not running" "Yellow" }

# boot.log is written before any module loads, so it is the first thing to
# read when the mod is quiet.
$boot = Join-Path $out 'boot.log'
if (Test-Path $boot) {
  Say "boot.log found - the mod started. Last lines:" "Green"
  Get-Content $boot -Tail 14 | ForEach-Object { Write-Host "    $_" }
} else {
  Say "boot.log MISSING - UE4SS has not run the mod's main.lua at all." "Red"
  Write-Host ""
  Say "Check in this order:" "Yellow"
  $modRoot = Split-Path $out -Parent
  $modsDir = Split-Path $modRoot -Parent
  Say "  1. Does this file exist:"
  Say "     $modRoot\Scripts\main.lua"
  if (Test-Path (Join-Path $modRoot 'Scripts\main.lua')) {
    Say "     -> it exists" "Green"
  } else {
    Say "     -> MISSING. Run INSTALL.bat again." "Red"
  }
  Say "  2. Does mods.txt have the line  TeslesNPCOverhaul : 1"
  $modsTxt = Join-Path $modsDir 'mods.txt'
  if (Test-Path $modsTxt) {
    $hit = Select-String -Path $modsTxt -Pattern "TeslesNPCOverhaul" -SimpleMatch
    if ($hit) { Say "     -> $($hit.Line.Trim())" "Green" }
    else { Say "     -> the line is MISSING" "Red" }
  } else {
    Say "     -> mods.txt missing: $modsTxt" "Red"
  }
  Say "  3. UE4SS status:"
  $win64 = Split-Path $modsDir -Parent
  if ((Split-Path $modsDir -Leaf) -eq 'Mods' -and
      (Split-Path $win64 -Leaf) -eq 'ue4ss') {
    $win64 = Split-Path $win64 -Parent
  }
  Write-UE4SSHealth (Get-UE4SSHealth $win64)
  Say "  4. Run DIAGNOSE.bat and share the zip it makes if this is not enough."
  Write-Host ""
}

$state = Join-Path $out 'live_state.json'
if (-not (Test-Path $state)) {
  Say "live_state.json missing - the director has not written its state yet." "Yellow"
  Say "If boot.log ends with 'startup deferred', wait 25 s and run this again." "Yellow"
} else {
  $age = [int]((Get-Date) - (Get-Item $state).LastWriteTime).TotalSeconds
  if ($age -le 15) { Say "live_state.json: updated $age s ago" "Green" }
  else { Say "live_state.json: old ($age s) - is the director ticking?" "Yellow" }

  try {
    $j = Get-Content $state -Raw | ConvertFrom-Json
    Write-Host ""
    Say "Version     : $($j.version)"
    Say "Tick        : $($j.tick)   uptime $([int]($j.uptime/60)) min"
    Say "NPCs        : $($j.stats.alive) alive / $($j.stats.npcs)"
    Say "Squads      : $($j.stats.groups)"
    Say "Physical    : $($j.stats.physical)"
    Say "Routes      : $($j.stats.routes) (failed $($j.stats.route_fail))"
    Say "Move orders : $($j.stats.commands)"
    Say "Spawns      : $($j.stats.spawns) (failed $($j.stats.spawn_fail))"
    Write-Host ""
    Say "Subsystems:"
    foreach ($h in $j.health) {
      $col = switch ($h.status) { "OK" { "Green" } "PENDING" { "Cyan" }
                                  "DEGRADED" { "Yellow" } default { "Red" } }
      Write-Host ("    {0,-24} {1,-9} {2}" -f $h.key, $h.status, $h.detail) -ForegroundColor $col
    }
  } catch {
    Say "live_state.json could not be parsed: $_" "Red"
  }
}

Write-Host ""
$log = Join-Path $out 'director.log'
if (Test-Path $log) {
  Say "director.log, last lines:" "Cyan"
  Get-Content $log -Tail 12 | ForEach-Object { Write-Host "    $_" }
} else {
  Say "director.log missing (written once the director starts)." "Yellow"
}

Write-Host ""
$world = Join-Path (Split-Path $out -Parent) 'state\world_state.json'
if (Test-Path $world) {
  $kb = [math]::Round((Get-Item $world).Length / 1KB, 1)
  Say "Saved world: $kb KB, $((Get-Item $world).LastWriteTime)" "Green"
} else {
  Say "The world has not been saved yet (every 45 s)." "Yellow"
}

Write-Host ""
Read-Host "  Press Enter to close"
