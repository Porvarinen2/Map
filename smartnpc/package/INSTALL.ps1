#requires -Version 5.1
<#
    SmartNPC installer.

    Everything the mod owns lives in ONE folder:
        <SCUM Server>\SmartNPC\

    The only footprint outside it is the small loader UE4SS requires:
        <SCUM Server>\SCUM\Binaries\Win64\Mods\SmartNPC\Scripts\main.lua
        <SCUM Server>\SCUM\Binaries\Win64\Mods\SmartNPC\enabled.txt
        one line in Mods\mods.txt
    Those three are listed in the install manifest and removed by UNINSTALL.
#>

param(
    [string]$ServerPath = '',
    [switch]$ResetConfig,
    [switch]$SkipUE4SS,
    [switch]$Quiet
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false) } catch {}
try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch {}

$Here = Split-Path -Parent $MyInvocation.MyCommand.Path
$Payload = Join-Path $Here 'payload\SmartNPC'
. (Join-Path $Payload 'lib.ps1')

function Say([string]$m, [string]$c = 'Gray') { Write-Host $m -ForegroundColor $c }
function Head([string]$m) { Write-Host ''; Write-Host $m -ForegroundColor Cyan }

Head 'SmartNPC installer'

if (-not (Test-Path -LiteralPath $Payload -PathType Container)) {
    throw "Broken package: payload\SmartNPC is missing next to INSTALL.ps1. Extract the whole ZIP first, do not run it from inside the archive."
}
foreach ($need in @('lua\boot.lua','lua\world.lua','lua\body.lua','lua\squad.lua','lua\director.lua',
                    'data\navgrid.lua','data\pois.lua','web\index.html','web\map.png',
                    'smartnpc.config.lua','START_MAP.ps1','lib.ps1','REPAIR.ps1')) {
    if (-not (Test-Path -LiteralPath (Join-Path $Payload $need) -PathType Leaf)) {
        throw "Broken package: payload\SmartNPC\$need is missing."
    }
}

# ---------------------------------------------------------------- find server
$Server = Find-ScumServer -Hint $ServerPath
if (-not $Server) {
    Say 'Could not find the SCUM dedicated server.' Red
    Say 'Run the installer again and pass the path, for example:' Yellow
    Say '  INSTALL.bat "F:\SteamLibrary\steamapps\common\SCUM Server"' Yellow
    throw 'SCUM Dedicated Server not found.'
}
Say "server:   $Server" Green

if (Get-Process -Name SCUMServer -ErrorAction SilentlyContinue) {
    throw 'SCUMServer.exe is running. Stop the server first - nothing has been changed.'
}

$Win64 = Join-Path $Server 'SCUM\Binaries\Win64'
$Dest  = Join-Path $Server 'SmartNPC'

Say "mod home: $Dest" Green

# ------------------------------------------------------------------- backup
$Backup = $null
if (Test-Path -LiteralPath $Dest) {
    $Backup = Join-Path $Server ('SmartNPC_Backups\' + (Get-Date -Format 'yyyyMMdd_HHmmss'))
    New-Item -ItemType Directory -Path $Backup -Force | Out-Null
    Copy-Item -LiteralPath $Dest -Destination (Join-Path $Backup 'SmartNPC') -Recurse -Force
    Say "backup:   $Backup" DarkGray
}

# keep the user's config and squad state across an upgrade
$keepConfig = $null
$keepState  = $null
if (-not $ResetConfig) {
    $cfg = Join-Path $Dest 'smartnpc.config.lua'
    if (Test-Path -LiteralPath $cfg -PathType Leaf) { $keepConfig = Get-Content -LiteralPath $cfg -Raw -Encoding UTF8 }
    $st = Join-Path $Dest 'state'
    if (Test-Path -LiteralPath $st -PathType Container) {
        $keepState = Join-Path ([IO.Path]::GetTempPath()) ('smartnpc_state_' + [guid]::NewGuid().ToString('N'))
        Copy-Item -LiteralPath $st -Destination $keepState -Recurse -Force
    }
}

# ------------------------------------------------------------------- install
if (Test-Path -LiteralPath $Dest) { Remove-Item -LiteralPath $Dest -Recurse -Force }
Copy-Item -LiteralPath $Payload -Destination $Dest -Recurse -Force
foreach ($sub in @('state','output','logs','tools')) {
    $p = Join-Path $Dest $sub
    if (-not (Test-Path -LiteralPath $p)) { New-Item -ItemType Directory -Path $p -Force | Out-Null }
}
if ($keepConfig) {
    [IO.File]::WriteAllText((Join-Path $Dest 'smartnpc.config.lua'), $keepConfig, (New-Object Text.UTF8Encoding($false)))
    Say 'config:   kept your existing smartnpc.config.lua' DarkGray
}
if ($keepState) {
    Copy-Item -Path (Join-Path $keepState '*') -Destination (Join-Path $Dest 'state') -Recurse -Force
    Remove-Item -LiteralPath $keepState -Recurse -Force
    Say 'state:    kept your existing squad state' DarkGray
}

# ------------------------------------------------------------------- UE4SS
$layout = Get-UE4SSLayout -Win64 $Win64
$ue4ssInstalledByUs = $false
if ($layout.HasUE4SS) {
    Say "UE4SS:    already installed ($($layout.Dll))" Green
} elseif ($SkipUE4SS) {
    Say 'UE4SS:    MISSING (skipped on request) - SmartNPC will not load' Yellow
} else {
    Say 'UE4SS:    not found. SmartNPC needs it to run.' Yellow
    $answer = 'y'
    if (-not $Quiet) {
        $answer = Read-Host 'Download and install UE4SS now into SmartNPC\tools and the server? [Y/n]'
        if (-not $answer) { $answer = 'y' }
    }
    if ($answer -match '^[yYkK]') {
        $toolDir = Join-Path $Dest 'tools\ue4ss'
        New-Item -ItemType Directory -Path $toolDir -Force | Out-Null
        $zip = Join-Path $toolDir 'ue4ss.zip'
        $url = $null
        try {
            $rel = Invoke-RestMethod -Uri 'https://api.github.com/repos/UE4SS-RE/RE-UE4SS/releases/latest' `
                                     -Headers @{ 'User-Agent' = 'SmartNPC-Installer' } -TimeoutSec 30
            $asset = $rel.assets | Where-Object { $_.name -match '^UE4SS_v[\d\.]+\.zip$' } | Select-Object -First 1
            if (-not $asset) { $asset = $rel.assets | Where-Object { $_.name -match '\.zip$' -and $_.name -notmatch 'dev|pdb|Debug' } | Select-Object -First 1 }
            if ($asset) { $url = $asset.browser_download_url }
        } catch {
            Say "  release lookup failed: $($_.Exception.Message)" DarkYellow
        }
        if (-not $url) { $url = 'https://github.com/UE4SS-RE/RE-UE4SS/releases/latest/download/UE4SS_v3.0.1.zip' }

        try {
            Say "  downloading $url" DarkGray
            Invoke-WebRequest -Uri $url -OutFile $zip -UseBasicParsing -TimeoutSec 180
            Add-Type -AssemblyName System.IO.Compression.FileSystem
            $ext = Join-Path $toolDir 'extracted'
            if (Test-Path -LiteralPath $ext) { Remove-Item -LiteralPath $ext -Recurse -Force }
            [IO.Compression.ZipFile]::ExtractToDirectory($zip, $ext)
            foreach ($item in (Get-ChildItem -LiteralPath $ext -Force)) {
                Copy-Item -LiteralPath $item.FullName -Destination $Win64 -Recurse -Force
            }
            $ue4ssInstalledByUs = $true
            $layout = Get-UE4SSLayout -Win64 $Win64   # the download decides the layout
            Say '  UE4SS installed into the server.' Green
        } catch {
            Say "  UE4SS download failed: $($_.Exception.Message)" Red
            Say '  Install UE4SS manually from https://github.com/UE4SS-RE/RE-UE4SS/releases' Yellow
            Say "  (extract it into $Win64), then run INSTALL.bat again." Yellow
        }
    } else {
        Say '  Skipped. Install UE4SS yourself before starting the server.' Yellow
    }
}

# ------------------------------------------------------------ UE4SS loader
# UE4SS 2.x keeps mods in Win64\Mods, 3.x in Win64\ue4ss\Mods.  Install the
# loader into every plausible root: a stub in the unused one is inert, while
# guessing wrong means the mod never starts at all.
$loaderReports = @()
foreach ($modsRoot in $layout.ModsRoots) {
    $stubPath = Write-LoaderStub -ModsRoot $modsRoot -ModHome $Dest
    $m = Set-ModsTxtEntry -ModsRoot $modsRoot
    $check = Test-SmartNPCLoader -ModsRoot $modsRoot -ModHome $Dest
    $loaderReports += $check
    if ($check.StubOk -and $check.Listed) {
        Say "loader:   $stubPath  (mods.txt updated)" Green
    } elseif ($check.StubOk) {
        Say "loader:   $stubPath  (mods.txt line COULD NOT be written to $($m.Path))" Yellow
    } else {
        Say "loader:   FAILED to write $stubPath" Red
    }
}
$Stub = Join-Path $layout.ModsRoots[0] 'SmartNPC'
$modsTxt = Join-Path $layout.ModsRoots[0] 'mods.txt'
$modsTxtExisted = $true
if (-not ($loaderReports | Where-Object { $_.StubOk -and ($_.Listed -or $_.Enabled) })) {
    Say '' 
    Say 'The loader could not be registered. SmartNPC will not start.' Red
    Say 'Run this window as Administrator and try again.' Yellow
}

# ---------------------------------------------------------------- manifest
$manifest = [ordered]@{
    product          = 'SmartNPC'
    version          = ((Get-Content -LiteralPath (Join-Path $Payload 'VERSION.txt') -Raw -ErrorAction SilentlyContinue) -replace "\s+$","")
    installedAt      = (Get-Date -Format 'o')
    serverPath       = $Server
    modHome          = $Dest
    loaderStub       = $Stub
    modsRoots        = @($layout.ModsRoots)
    modsTxt          = $modsTxt
    modsTxtExisted   = $modsTxtExisted
    ue4ssInstalledBy = $(if ($ue4ssInstalledByUs) { 'SmartNPC' } else { 'pre-existing-or-missing' })
    backup           = $Backup
}
($manifest | ConvertTo-Json -Depth 4) |
    Set-Content -LiteralPath (Join-Path $Dest 'install-manifest.json') -Encoding UTF8

Copy-Item -LiteralPath (Join-Path $Here 'UNINSTALL.ps1') -Destination $Dest -Force
Copy-Item -LiteralPath (Join-Path $Here 'UNINSTALL.bat') -Destination $Dest -Force

Head 'Done.'
Say "  Mod home        $Dest"
Say "  Config          $Dest\smartnpc.config.lua"
Say "  Logs            $Dest\logs\smartnpc.log"
Say "  Live map        $Dest\START_MAP.bat"
Say "  Repair / verify $Dest\REPAIR.bat"
Say "  Uninstall       $Dest\UNINSTALL.bat"
Write-Host ''
Say '  1. Start the SCUM server the way you normally do.' White
Say '  2. Run START_MAP.bat from the SmartNPC folder.' White
Say '  3. The first squads start moving about a minute after the server is up.' White
Write-Host ''
