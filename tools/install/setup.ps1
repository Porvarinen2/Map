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

<#
  Natiiviohjelmien ajo. PowerShell 5.1 muuttaa stderr-tulosteen virheeksi kun
  $ErrorActionPreference on Stop (npm kirjoittaa "npm notice" stderriin), joten
  ajetaan cmd.exe:n kautta ja tarkistetaan pelkka paluukoodi.
#>
function Invoke-Native {
  param([string]$CommandLine, [string]$WorkDir = $PWD.Path)
  $previous = $ErrorActionPreference
  $ErrorActionPreference = "Continue"
  try {
    Push-Location $WorkDir
    $output = & cmd.exe /c "$CommandLine 2>&1"
    $code = $LASTEXITCODE
    if ($output) { $output | Out-File -Append -Encoding UTF8 $logFile }
    return @{ Code = $code; Output = ($output -join "`n") }
  } finally {
    Pop-Location
    $ErrorActionPreference = $previous
  }
}

function Install-FromUrl {
  param([string]$Url, [string]$FileName, [string]$Arguments, [string]$Label)
  $installer = Join-Path $downloadDir $FileName
  Write-Log "Ladataan $Label suoraan: $Url"
  Invoke-WebRequest -Uri $Url -OutFile $installer -UseBasicParsing
  Write-Log "Asennetaan $Label hiljaisesti (tama voi kestaa)"
  $proc = Start-Process -FilePath $installer -ArgumentList $Arguments -Wait -PassThru
  if ($proc.ExitCode -ne 0 -and $proc.ExitCode -ne 3010) {
    Write-Log "$Label asennin palautti koodin $($proc.ExitCode)" "WARN"
    return $false
  }
  Write-Log "$Label asennettu"
  return $true
}

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
  $line = "winget install --id $Id --exact --silent --accept-package-agreements --accept-source-agreements"
  if ($Override -ne "") { $line += " --override `"$Override`"" }
  $result = Invoke-Native -CommandLine $line
  # 0x8A15002B = jo asennettu, 0x8A150056 = ei paivitettavaa.
  if ($result.Code -eq 0 -or $result.Code -eq -1978335189 -or $result.Code -eq -1978335130) {
    Write-Log "$Label asennettu"
    return $true
  }
  Write-Log "${Label}: winget palautti 0x$('{0:X8}' -f $result.Code)" "WARN"
  $tail = ($result.Output -split "`n" | Where-Object { $_.Trim() -ne "" } | Select-Object -Last 3) -join " | "
  if ($tail) { Write-Log "winget: $tail" "WARN" }
  return $false
}

function Get-NodeLtsMsiUrl {
  $index = Invoke-RestMethod -Uri "https://nodejs.org/dist/index.json" -UseBasicParsing
  $lts = $index | Where-Object { $_.lts -ne $false } | Select-Object -First 1
  if ($null -eq $lts) { throw "Node LTS -versiota ei loytynyt" }
  return "https://nodejs.org/dist/$($lts.version)/node-$($lts.version)-x64.msi"
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

  if (Test-Command "node") {
    Write-Log "Node.js on jo asennettu ($(& node -v))"
  } else {
    $ok = Install-WingetPackage -Id "OpenJS.NodeJS.LTS" -Label "Node.js LTS"
    Update-PathEnv
    if (-not (Test-Command "node")) {
      try {
        Install-FromUrl -Url (Get-NodeLtsMsiUrl) -FileName "node-lts-x64.msi" `
          -Arguments "/quiet /norestart" -Label "Node.js LTS (MSI)" | Out-Null
      } catch {
        Write-Log "Node.js -varalataus epaonnistui: $($_.Exception.Message)" "WARN"
      }
      Update-PathEnv
    }
  }

  if (Test-Command "git") {
    Write-Log "Git on jo asennettu"
  } else {
    Install-WingetPackage -Id "Git.Git" -Label "Git" | Out-Null
    Update-PathEnv
    if (-not (Test-Command "git")) {
      try {
        $gitExe = Join-Path $downloadDir "git-setup.exe"
        Get-GitHubAsset -Repo "git-for-windows/git" -Pattern 'Git-.*-64-bit\.exe$' -OutFile $gitExe | Out-Null
        $proc = Start-Process -FilePath $gitExe -ArgumentList "/VERYSILENT /NORESTART /NOCANCEL /SP-" -Wait -PassThru
        if ($proc.ExitCode -eq 0) { Write-Log "Git asennettu" } else { Write-Log "Git-asennin palautti $($proc.ExitCode)" "WARN" }
      } catch {
        Write-Log "Git-varalataus epaonnistui: $($_.Exception.Message)" "WARN"
      }
      Update-PathEnv
    }
  }

  if (-not $SkipBuildTools) {
    # C++-tyokalut tarvitaan modi-DLL:n kaantamiseen. Iso lataus (useita GB).
    $hasCl = (Test-Path "${env:ProgramFiles(x86)}\Microsoft Visual Studio\2022") -or (Test-Path "$env:ProgramFiles\Microsoft Visual Studio\2022")
    if ($hasCl) {
      Write-Log "Visual Studio 2022 -tyokalut loytyvat jo"
    } else {
      $ok = Install-WingetPackage -Id "Microsoft.VisualStudio.2022.BuildTools" -Label "VS 2022 Build Tools" `
        -Override "--quiet --wait --norestart --add Microsoft.VisualStudio.Workload.VCTools --includeRecommended"
      if (-not $ok) {
        try {
          Install-FromUrl -Url "https://aka.ms/vs/17/release/vs_BuildTools.exe" -FileName "vs_BuildTools.exe" `
            -Arguments "--quiet --wait --norestart --nocache --add Microsoft.VisualStudio.Workload.VCTools --includeRecommended" `
            -Label "VS 2022 Build Tools (bootstrapper)" | Out-Null
        } catch {
          Write-Log "Build Tools -varalataus epaonnistui: $($_.Exception.Message)" "WARN"
        }
      }
    }
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

Write-Log "Asennetaan UE4SS-modit" "STEP"
try {
  $ue4ssModsDir = Join-Path $binariesDir "Mods"
  New-Item -ItemType Directory -Path $ue4ssModsDir -Force | Out-Null
  $luaSource = Join-Path $RepoPath "mod\ue4ss\LivingNPCDiscovery"
  $luaTarget = Join-Path $ue4ssModsDir "LivingNPCDiscovery"
  New-Item -ItemType Directory -Path $luaTarget -Force | Out-Null
  Copy-Item -Path (Join-Path $luaSource "*") -Destination $luaTarget -Recurse -Force

  # mods.txt ohjaa mitka modit UE4SS lataa; lisataan rivi vain kertaalleen.
  $modsTxt = Join-Path $ue4ssModsDir "mods.txt"
  if (-not (Test-Path $modsTxt)) { Set-Content -Path $modsTxt -Value "" -Encoding ASCII }
  $modsTxtContent = Get-Content $modsTxt -Raw
  if ($modsTxtContent -notmatch "LivingNPCDiscovery") {
    Add-Content -Path $modsTxt -Value "LivingNPCDiscovery : 1"
    Write-Log "mods.txt paivitetty"
  } else {
    Write-Log "mods.txt sisaltaa jo LivingNPCDiscovery"
  }
  Write-Log "Kartoitusmodi asennettu: $luaTarget"
  Write-Log "Kaynnista serveri kerran ja katso: $binariesDir\LivingNPC_classes.txt"
} catch {
  Write-Log "UE4SS-modin asennus epaonnistui: $($_.Exception.Message)" "WARN"
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
  $install = Invoke-Native -CommandLine "npm install --no-audit --no-fund" -WorkDir $RepoPath
  if ($install.Code -ne 0) {
    Write-Log "npm install palautti $($install.Code) - katso loki" "WARN"
  }
  $build = Invoke-Native -CommandLine "npm run build" -WorkDir $RepoPath
  if ($build.Code -eq 0) {
    Write-Log "Aivopalvelu kaannetty"
  } else {
    Write-Log "npm run build palautti $($build.Code)" "WARN"
  }
  if (Test-Path (Join-Path $RepoPath "dist\cli\brain.js")) {
    Write-Log "dist/cli/brain.js on paikallaan"
  } else {
    Write-Log "dist/cli/brain.js puuttuu - aivopalvelu ei kaynnisty ennen kuin kaannos onnistuu" "WARN"
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

Write-Log "Tarkistetaan lopputulos" "STEP"
$checks = [ordered]@{
  "Node.js" = { Test-Command "node" }
  "npm" = { Test-Command "npm" }
  "Git" = { Test-Command "git" }
  "repak" = { Test-Path (Join-Path $toolsDir "repak.exe") }
  "UE4SS" = { Test-Path (Join-Path $binariesDir "UE4SS.dll") }
  "Kartoitusmodi" = { Test-Path (Join-Path $binariesDir "Mods\LivingNPCDiscovery\Scripts\main.lua") }
  "Pak ~mods" = { Test-Path (Join-Path $modsDir "ScumLivingNPC_P.pak") }
  "Aivopalvelu" = { Test-Path (Join-Path $RepoPath "dist\cli\brain.js") }
}
$missing = @()
foreach ($name in $checks.Keys) {
  $ok = $false
  try { $ok = [bool](& $checks[$name]) } catch { $ok = $false }
  if ($ok) { Write-Host ("   [OK]     " + $name) -ForegroundColor Green }
  else {
    Write-Host ("   [PUUTTUU] " + $name) -ForegroundColor Red
    $missing += $name
  }
}

Write-Host ""
Write-Host "VALMIS." -ForegroundColor Green
if ($missing.Count -gt 0) {
  Write-Host ("Puuttuu: " + ($missing -join ", ") + " - katso " + $logFile) -ForegroundColor Yellow
}
Write-Host "  1. Kaynnista aivopalvelu: $startBrain"
Write-Host "  2. Kaynnista SCUM-serveri ja tarkista UE4SS-loki: $binariesDir\UE4SS.log"
Write-Host "  3. Pak-modi asennettu: $modsDir"
Write-Host "  4. Luokkakartoitus serverin kaynnistyksen jalkeen: $binariesDir\LivingNPC_classes.txt"
Write-Host ""
Write-Host "Kayta vain privaatti/offline-serverilla." -ForegroundColor Yellow
exit 0
