<#
  Rakentaa ScumLivingNPC_P.pak ja asentaa sen serverin ~mods-kansioon.
  Kayttaa repak.exe:ta (asennetaan setup.bat:lla) - Unreal Engine ei ole tarpeen.
#>
[CmdletBinding()]
param(
  [string]$RepoPath = (Resolve-Path (Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) "..\..")).Path,
  [string]$ServerPath = "",
  [string]$PakName = "ScumLivingNPC_P.pak",
  [switch]$NoInstall
)

$ErrorActionPreference = "Stop"

$repak = Join-Path $RepoPath "tools\bin\repak.exe"
$contentDir = Join-Path $RepoPath "mod\pak-content"
$stageDir = Join-Path $RepoPath "build\pak-stage"
$outDir = Join-Path $RepoPath "build"
$outPak = Join-Path $outDir $PakName

if (-not (Test-Path $repak)) { throw "repak.exe puuttuu: $repak - aja tools\install\setup.bat" }
if (-not (Test-Path $contentDir)) { throw "Pak-sisaltoa ei loydy: $contentDir" }

# Stage: mod-sisalto + generoitu persoonadata, jotta pak on itsenainen paketti.
if (Test-Path $stageDir) { Remove-Item $stageDir -Recurse -Force }
New-Item -ItemType Directory -Path $stageDir -Force | Out-Null
Copy-Item -Path (Join-Path $contentDir "*") -Destination $stageDir -Recurse -Force

$dataTarget = Join-Path $stageDir "SCUM\Content\Mods\LivingNPC\Data"
New-Item -ItemType Directory -Path $dataTarget -Force | Out-Null
Copy-Item -Path (Join-Path $RepoPath "data\*") -Destination $dataTarget -Recurse -Force

$manifest = [ordered]@{
  mod = "scum-living-npc"
  builtAt = (Get-Date).ToString("s")
  traitFiles = (Get-ChildItem (Join-Path $RepoPath "data\traits") -Filter *.json).Name
} | ConvertTo-Json -Depth 4
Set-Content -Path (Join-Path $dataTarget "manifest.json") -Value $manifest -Encoding UTF8

New-Item -ItemType Directory -Path $outDir -Force | Out-Null
if (Test-Path $outPak) { Remove-Item $outPak -Force }

Write-Host "Pakataan: $stageDir -> $outPak"
& $repak pack --version V11 $stageDir $outPak
if ($LASTEXITCODE -ne 0) {
  Write-Host "V11 epaonnistui, yritetaan oletusversiolla" -ForegroundColor Yellow
  & $repak pack $stageDir $outPak
  if ($LASTEXITCODE -ne 0) { throw "repak pack palautti $LASTEXITCODE" }
}

& $repak list $outPak | Select-Object -First 10
Write-Host "Pak valmis: $outPak ($([math]::Round((Get-Item $outPak).Length / 1KB)) KB)"

if (-not $NoInstall) {
  if ($ServerPath -eq "") {
    $configPath = Join-Path $RepoPath "scum-living-npc.config.json"
    if (Test-Path $configPath) { $ServerPath = (Get-Content $configPath -Raw | ConvertFrom-Json).serverPath }
  }
  if ($ServerPath -eq "") { throw "ServerPath puuttuu - anna -ServerPath tai aja setup.bat ensin" }
  $modsDir = Join-Path $ServerPath "SCUM\Content\Paks\~mods"
  New-Item -ItemType Directory -Path $modsDir -Force | Out-Null
  Copy-Item -Path $outPak -Destination $modsDir -Force
  Write-Host "Asennettu: $modsDir\$PakName"
}
exit 0
