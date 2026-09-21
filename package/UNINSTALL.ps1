<# TESLES NPC OVERHAUL - uninstaller. Removes the mod and its mods.txt entry.
   The world state is copied aside first so a later reinstall can restore it. #>
$ErrorActionPreference = "Stop"
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$MOD = "TeslesNPCOverhaul"
function Say($t, $c = "Gray") { Write-Host "  $t" -ForegroundColor $c }

Write-Host ""
Write-Host "  TESLES NPC OVERHAUL - poisto" -ForegroundColor Yellow
Write-Host ""

if (Get-Process -Name "SCUMServer" -ErrorAction SilentlyContinue) {
  Say "Sammuta SCUM-palvelin ensin." "Red"
  Read-Host "  Enter sulkee"; exit 1
}

$pathFile = Join-Path $here 'livemap\livemap_paths.txt'
if (-not (Test-Path $pathFile)) {
  Say "Asennuspolkua ei loydy. Poista kansio Mods\$MOD kasin." "Red"
  Read-Host "  Enter sulkee"; exit 1
}
$out = (Get-Content $pathFile -First 1).Trim()
$target = Split-Path $out -Parent
$mods = Split-Path $target -Parent

if (Test-Path $target) {
  $stamp = Get-Date -Format "yyyyMMdd-HHmmss"
  $server = Split-Path (Split-Path (Split-Path $mods -Parent) -Parent) -Parent
  $backup = Join-Path $server "TeslesNPCOverhaul_Backups\uninstall-$stamp"
  New-Item -ItemType Directory -Path $backup -Force | Out-Null
  Copy-Item -LiteralPath $target -Destination (Join-Path $backup $MOD) -Recurse -Force
  Remove-Item -LiteralPath $target -Recurse -Force
  Say "Poistettu. Varmuuskopio: $backup" "Green"
}

$modsTxt = Join-Path $mods 'mods.txt'
if (Test-Path $modsTxt) {
  $lines = @(Get-Content $modsTxt) | Where-Object { $_ -notmatch "^\s*$MOD\s*:" }
  Set-Content -LiteralPath $modsTxt -Value $lines -Encoding ASCII
  Say "mods.txt siivottu." "Green"
}

Say "Vanhaa TeslesWorldDirectoria ei palautettu automaattisesti." "Yellow"
Write-Host ""
Read-Host "  Enter sulkee"
