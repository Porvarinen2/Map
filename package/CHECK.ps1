<# TESLES NPC OVERHAUL - status check. Reports what the mod has actually
   proven on this server, not what it is supposed to do. #>
$ErrorActionPreference = "SilentlyContinue"
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$MOD = "TeslesNPCOverhaul"

function Say($t, $c = "Gray") { Write-Host "  $t" -ForegroundColor $c }

Write-Host ""
Write-Host "  TESLES NPC OVERHAUL - tilanne" -ForegroundColor Yellow
Write-Host "  ============================="
Write-Host ""

$pathFile = Join-Path $here 'livemap\livemap_paths.txt'
$out = $null
if (Test-Path $pathFile) { $out = (Get-Content $pathFile -First 1).Trim() }
if (-not $out -or -not (Test-Path $out)) {
  Say "Mod-output -kansiota ei loydy. Onko INSTALL.bat ajettu?" "Red"
  Read-Host "  Enter sulkee"
  exit 1
}
Say "Output: $out"

$proc = Get-Process -Name "SCUMServer" -ErrorAction SilentlyContinue
if ($proc) { Say "SCUMServer: kaynnissa (PID $($proc.Id))" "Green" }
else { Say "SCUMServer: ei kaynnissa" "Yellow" }

$state = Join-Path $out 'live_state.json'
if (-not (Test-Path $state)) {
  Say "live_state.json puuttuu - director ei ole viela kirjoittanut mitaan." "Red"
  Say "Katso director.log samasta kansiosta." "Yellow"
} else {
  $age = [int]((Get-Date) - (Get-Item $state).LastWriteTime).TotalSeconds
  if ($age -le 15) { Say "live_state.json: paivitetty $age s sitten" "Green" }
  else { Say "live_state.json: vanha ($age s) - tickaako director?" "Yellow" }

  try {
    $j = Get-Content $state -Raw | ConvertFrom-Json
    Write-Host ""
    Say "Versio      : $($j.version)"
    Say "Tick        : $($j.tick)   uptime $([int]($j.uptime/60)) min"
    Say "NPC         : $($j.stats.alive) elossa / $($j.stats.npcs)"
    Say "Ryhmat      : $($j.stats.groups)"
    Say "Fyysisia    : $($j.stats.physical)"
    Say "Reitit      : $($j.stats.routes) (epaonnistui $($j.stats.route_fail))"
    Say "Liikekaskyt : $($j.stats.commands)"
    Say "Spawnit     : $($j.stats.spawns) (epaonnistui $($j.stats.spawn_fail))"
    Write-Host ""
    Say "Osajarjestelmat:"
    foreach ($h in $j.health) {
      $col = switch ($h.status) { "OK" { "Green" } "PENDING" { "Cyan" }
                                  "DEGRADED" { "Yellow" } default { "Red" } }
      Write-Host ("    {0,-24} {1,-9} {2}" -f $h.key, $h.status, $h.detail) -ForegroundColor $col
    }
  } catch {
    Say "live_state.json ei jasenny: $_" "Red"
  }
}

Write-Host ""
$log = Join-Path $out 'director.log'
if (Test-Path $log) {
  Say "director.log viimeiset rivit:" "Cyan"
  Get-Content $log -Tail 12 | ForEach-Object { Write-Host "    $_" }
} else {
  Say "director.log puuttuu." "Yellow"
}

Write-Host ""
$world = Join-Path (Split-Path $out -Parent) 'state\world_state.json'
if (Test-Path $world) {
  $kb = [math]::Round((Get-Item $world).Length / 1KB, 1)
  Say "Maailman tallennus: $kb KB, $((Get-Item $world).LastWriteTime)" "Green"
} else {
  Say "Maailmaa ei ole viela tallennettu (tallennus 45 s valein)." "Yellow"
}

Write-Host ""
Read-Host "  Enter sulkee"
