<#
  SCUM Living NPC - asennus.

  Asentaa: Git, Node.js LTS, 7-Zip, Visual Studio 2022 Build Tools (C++),
  UE4SS-mod loaderin serverin binaarikansioon, repak-pakkaajan ja FModelin,
  kaantaa aivopalvelun ja rakentaa + asentaa pak-modin ~mods-kansioon.

  Aja tama setup.bat:n kautta (hoitaa admin-korotuksen).
#>
[CmdletBinding()]
param(
  [string]$ServerPath = "F:\SteamLibrary\steamapps\common\SCUM Server",
  [string]$RepoPath = "",
  [int]$BrainPort = 7771,
  [switch]$SkipTools,
  [switch]$SkipBuildTools
)

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$logFile = Join-Path $scriptDir "install.log"
if ($RepoPath -eq "") { $RepoPath = (Resolve-Path (Join-Path $scriptDir "..\..")).Path }
$toolsDir = Join-Path $RepoPath "tools\bin"
$downloadDir = Join-Path $env:TEMP "scum-living-npc-dl"

function Write-Log {
  param([string]$Message, [string]$Level = "INFO")
  $line = "{0} [{1}] {2}" -f (Get-Date -Format "HH:mm:ss"), $Level, $Message
  Add-Content -Path $logFile -Value $line
  switch ($Level) {
    "WARN"  { Write-Host $Message -ForegroundColor Yellow }
    "ERROR" { Write-Host $Message -ForegroundColor Red }
    "STEP"  { Write-Host "`n== $Message" -ForegroundColor Cyan }
    default { Write-Host "   $Message" }
  }
}

function Test-Command { param([string]$Name) $null -ne (Get-Command $Name -ErrorAction SilentlyContinue) }

function Install-WingetPackage {
  param([string]$Id, [string]$Label, [string]$Override = "")
  if (-not (Test-Command "winget")) {
    Write-Log "winget puuttuu - asenna $Label kasin: https://winget.run/pkg/$($Id.Replace('.','/'))" "WARN"
    return $false
  }
  $installed = (winget list --id $Id --exact --accept-source-agreements 2>$null | Out-String)
  if ($installed -match [regex]::Escape($Id)) {
    Write-Log "$Label on jo asennettu"
    return $true
  }
  Write-Log "Asennetaan $Label ..."
  $wgArgs = @("install", "--id", $Id, "--exact", "--silent",
              "--accept-package-agreements", "--accept-source-agreements", "--disable-interactivity")
  if ($Override -ne "") { $wgArgs += @("--override", $Override) }
  & winget @wgArgs 2>&1 | Out-File -Append $logFile
  if ($LASTEXITCODE -ne 0 -and $LASTEXITCODE -ne -1978335189) {
    Write-Log "$Label asennus palautti koodin $LASTEXITCODE - jatketaan, tarkista loki" "WARN"
    return $false
  }
  Write-Log "$Label asennettu"
  return $true
}

function Get-GitHubAsset {
  param([string]$Repo, [string]$Pattern, [string]$OutFile)
  $headers = @{ "User-Agent" = "scum-living-npc-setup" }
  $release = Invoke-RestMethod -Uri "https://api.github.com/repos/$Repo/releases/latest" -Headers $headers
  $asset = $release.assets | Where-Object { $_.name -match $Pattern } | Select-Object -First 1
  if ($null -eq $asset) {
    throw "Repo $Repo julkaisussa $($release.tag_name) ei ole tiedostoa joka vastaa '$Pattern'"
  }
  Write-Log "Ladataan $($asset.name) ($Repo $($release.tag_name))"
  Invoke-WebRequest -Uri $asset.browser_download_url -OutFile $OutFile -Headers $headers
  return $release.tag_name
}

function Expand-To {
  param([string]$Zip, [string]$Target)
  if (Test-Path $Target) { Remove-Item $Target -Recurse -Force }
  New-Item -ItemType Directory -Path $Target -Force | Out-Null
  Expand-Archive -Path $Zip -DestinationPath $Target -Force
}

function Update-PathEnv {
  $machine = [Environment]::GetEnvironmentVariable("Path", "Machine")
  $user = [Environment]::GetEnvironmentVariable("Path", "User")
  $env:Path = "$machine;$user"
}

# --------------------------------------------------------------------------

Set-Content -Path $logFile -Value "SCUM Living NPC -asennus $(Get-Date)"
Write-Host "SCUM Living NPC - asennus" -ForegroundColor Green
Write-Log "Serveripolku: $ServerPath"
Write-Log "Repo: $RepoPath"

$binariesDir = Join-Path $ServerPath "SCUM\Binaries\Win64"
$paksDir = Join-Path $ServerPath "SCUM\Content\Paks"
$modsDir = Join-Path $paksDir "~mods"

Write-Log "Tarkistetaan serveriasennus" "STEP"
if (-not (Test-Path $ServerPath)) {
  Write-Log "Serveripolkua ei loydy: $ServerPath" "ERROR"
  Write-Log "Aja: setup.bat `"<polku SCUM Server -kansioon>`"" "ERROR"
  exit 2
}
if (-not (Test-Path $paksDir)) {
  Write-Log "Paks-kansiota ei loydy: $paksDir - onko tama SCUM-serverin kansio?" "ERROR"
  exit 2
}
if (-not (Test-Path $binariesDir)) {
  Write-Log "Binaarikansiota ei loydy: $binariesDir" "ERROR"
  exit 2
}
Write-Log "Serveri loytyi"

New-Item -ItemType Directory -Path $modsDir -Force | Out-Null
New-Item -ItemType Directory -Path $toolsDir -Force | Out-Null
New-Item -ItemType Directory -Path $downloadDir -Force | Out-Null
Write-Log "~mods-kansio: $modsDir"

if (-not $SkipTools) {
  Write-Log "Asennetaan perustyokalut" "STEP"
  Install-WingetPackage -Id "Git.Git" -Label "Git" | Out-Null
  Install-WingetPackage -Id "OpenJS.NodeJS.LTS" -Label "Node.js LTS" | Out-Null
  Install-WingetPackage -Id "7zip.7zip" -Label "7-Zip" | Out-Null
  if (-not $SkipBuildTools) {
    # C++-tyokalut tarvitaan modi-DLL:n kaantamiseen (iso lataus, ~5 GB).
    Install-WingetPackage -Id "Microsoft.VisualStudio.2022.BuildTools" -Label "VS 2022 Build Tools" `
      -Override "--quiet --wait --norestart --add Microsoft.VisualStudio.Workload.VCTools --includeRecommended" | Out-Null
  }
  Update-PathEnv
}

Write-Log "Asennetaan UE4SS (mod loader)" "STEP"
try {
  $ue4ssZip = Join-Path $downloadDir "ue4ss.zip"
  $tag = Get-GitHubAsset -Repo "UE4SS-RE/RE-UE4SS" -Pattern '^UE4SS_v?[\d\.]+\.zip$' -OutFile $ue4ssZip
  $ue4ssStage = Join-Path $downloadDir "ue4ss"
  Expand-To -Zip $ue4ssZip -Target $ue4ssStage
  Copy-Item -Path (Join-Path $ue4ssStage "*") -Destination $binariesDir -Recurse -Force
  Write-Log "UE4SS $tag kopioitu: $binariesDir"
  Write-Log "HUOM: UE4SS injektoituu serveriprosessiin. Kayta vain privaatti/offline-serverilla - EAC voi estaa rekisteroitymisen." "WARN"
} catch {
  Write-Log "UE4SS-asennus epaonnistui: $($_.Exception.Message)" "WARN"
  Write-Log "Voit asentaa sen kasin: https://github.com/UE4SS-RE/RE-UE4SS/releases" "WARN"
}

Write-Log "Asennetaan repak (pak-pakkaaja)" "STEP"
try {
  $repakZip = Join-Path $downloadDir "repak.zip"
  Get-GitHubAsset -Repo "trumank/repak" -Pattern 'repak.*(windows|msvc).*\.zip$' -OutFile $repakZip | Out-Null
  $repakStage = Join-Path $downloadDir "repak"
  Expand-To -Zip $repakZip -Target $repakStage
  $repakExe = Get-ChildItem -Path $repakStage -Filter "repak*.exe" -Recurse | Select-Object -First 1
  if ($null -eq $repakExe) { throw "repak.exe ei loytynyt paketista" }
  Copy-Item -Path $repakExe.FullName -Destination (Join-Path $toolsDir "repak.exe") -Force
  Write-Log "repak asennettu: $toolsDir\repak.exe"
} catch {
  Write-Log "repak-asennus epaonnistui: $($_.Exception.Message)" "WARN"
}

Write-Log "Asennetaan FModel (assettien tarkastelu)" "STEP"
try {
  $fmZip = Join-Path $downloadDir "fmodel.zip"
  Get-GitHubAsset -Repo "4sval/FModel" -Pattern '\.zip$' -OutFile $fmZip | Out-Null
  Expand-To -Zip $fmZip -Target (Join-Path $toolsDir "FModel")
  Write-Log "FModel asennettu: $toolsDir\FModel"
} catch {
  Write-Log "FModel-asennus epaonnistui (ei pakollinen): $($_.Exception.Message)" "WARN"
}

Write-Log "Kaannetaan aivopalvelu" "STEP"
Update-PathEnv
if (-not (Test-Command "npm")) {
  Write-Log "npm ei ole viela polussa. Sulje ja avaa setup.bat uudelleen kun Node on asennettu." "WARN"
} else {
  Push-Location $RepoPath
  try {
    & npm install --no-audit --no-fund 2>&1 | Out-File -Append $logFile
    if ($LASTEXITCODE -ne 0) { throw "npm install palautti $LASTEXITCODE" }
    & npm run build 2>&1 | Out-File -Append $logFile
    if ($LASTEXITCODE -ne 0) { throw "npm run build palautti $LASTEXITCODE" }
    Write-Log "Aivopalvelu kaannetty"
  } catch {
    Write-Log "Kaannos epaonnistui: $($_.Exception.Message)" "WARN"
  } finally {
    Pop-Location
  }
}

Write-Log "Rakennetaan ja asennetaan pak-modi" "STEP"
try {
  & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $RepoPath "tools\pak\build-pak.ps1") `
    -RepoPath $RepoPath -ServerPath $ServerPath 2>&1 | Tee-Object -Append -FilePath $logFile
  if ($LASTEXITCODE -ne 0) { throw "build-pak.ps1 palautti $LASTEXITCODE" }
} catch {
  Write-Log "Pak-modin rakennus epaonnistui: $($_.Exception.Message)" "WARN"
}

Write-Log "Kirjoitetaan asetukset ja kaynnistysskripti" "STEP"
$config = [ordered]@{
  serverPath = $ServerPath
  paksDir = $paksDir
  modsDir = $modsDir
  binariesDir = $binariesDir
  brainHost = "127.0.0.1"
  brainPort = $BrainPort
  installedAt = (Get-Date).ToString("s")
}
$configPath = Join-Path $RepoPath "scum-living-npc.config.json"
$config | ConvertTo-Json -Depth 4 | Set-Content -Path $configPath -Encoding UTF8
Write-Log "Asetukset: $configPath"

$startBrain = Join-Path $RepoPath "start-brain.bat"
@"
@echo off
title SCUM Living NPC - brain
cd /d "%~dp0"
node dist\cli\brain.js --port $BrainPort
pause
"@ | Set-Content -Path $startBrain -Encoding ASCII
Write-Log "Kaynnistys: $startBrain"

Write-Host ""
Write-Host "VALMIS." -ForegroundColor Green
Write-Host "  1. Kaynnista aivopalvelu: $startBrain"
Write-Host "  2. Kaynnista SCUM-serveri ja tarkista UE4SS-loki: $binariesDir\UE4SS.log"
Write-Host "  3. Pak-modi asennettu: $modsDir"
Write-Host ""
Write-Host "Kayta vain privaatti/offline-serverilla." -ForegroundColor Yellow
exit 0
