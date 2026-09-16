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
    [switch]$InstallUE4SS,
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

# ----------------------------------------------- close anything holding files
$stopped = Stop-MapServer -ModHome $Dest
if ($stopped -gt 0) { Say "map:      closed $stopped running map server window(s)" DarkGray }

# ------------------------------------------------------------------- backup
$Backup = $null
if (Test-Path -LiteralPath $Dest) {
    $Backup = Join-Path $Server ('SmartNPC_Backups\' + (Get-Date -Format 'yyyyMMdd_HHmmss'))
    try {
        New-Item -ItemType Directory -Path $Backup -Force | Out-Null
        Copy-Item -LiteralPath $Dest -Destination (Join-Path $Backup 'SmartNPC') -Recurse -Force -ErrorAction Stop
        Say "backup:   $Backup" DarkGray
    } catch {
        Say "backup:   partial ($($_.Exception.Message))" DarkYellow
    }
}

# keep the user's config across an upgrade (state, output, logs and tools are
# never touched by the file sync at all)
$keepConfig = $null
if (-not $ResetConfig) {
    $cfg = Join-Path $Dest 'smartnpc.config.lua'
    if (Test-Path -LiteralPath $cfg -PathType Leaf) {
        try { $keepConfig = Get-Content -LiteralPath $cfg -Raw -Encoding UTF8 } catch {}
    }
}

# ------------------------------------------------------------------- install
# Files are replaced one by one rather than by deleting the folder: an open
# Explorer window, an editor or a leftover map server locks the directory, and
# a failed delete used to abort the whole install.
$sync = Sync-ModFiles -Source $Payload -Dest $Dest
if ($sync.Failed.Count -gt 0) {
    Write-Host ''
    Say 'These files are locked by another program and were NOT updated:' Red
    foreach ($f in $sync.Failed) { Say "  $f" Red }
    Write-Host ''
    Say 'Close any SmartNPC map server window, editor or Explorer window open in' Yellow
    Say "$Dest and run INSTALL.bat again." Yellow
    throw 'Install incomplete: some files could not be replaced.'
}
Say "files:    $($sync.Copied) written" Green

foreach ($sub in @('state','output','logs','tools')) {
    $p = Join-Path $Dest $sub
    if (-not (Test-Path -LiteralPath $p)) { New-Item -ItemType Directory -Path $p -Force | Out-Null }
}
if ($keepConfig) {
    [IO.File]::WriteAllText((Join-Path $Dest 'smartnpc.config.lua'), $keepConfig, (New-Object Text.UTF8Encoding($false)))
    Say 'config:   kept your existing smartnpc.config.lua' DarkGray
}

# ------------------------------------------------------------------- UE4SS
# SmartNPC does NOT install UE4SS on its own any more.  Earlier versions did,
# and on a server whose UE4SS lives in Win64\ue4ss\ that put a second, generic
# UE4SS (and its dwmapi.dll proxy) at Win64 root, where it took over loading and
# then failed on SCUM's build - killing every mod on the server.
$layout = Get-UE4SSLayout -Win64 $Win64
$ue4ssInstalledByUs = $false

if ($layout.HasUE4SS) {
    Say "UE4SS:    found ($($layout.Dll))" Green
} elseif ($InstallUE4SS) {
    Say 'UE4SS:    not found; downloading because -InstallUE4SS was given.' Yellow
    $toolDir = Join-Path $Dest 'tools\ue4ss'
    New-Item -ItemType Directory -Path $toolDir -Force | Out-Null
    $zip = Join-Path $toolDir 'ue4ss.zip'
    $url = 'https://github.com/UE4SS-RE/RE-UE4SS/releases/latest/download/UE4SS_v3.0.1.zip'
    try {
        $rel = Invoke-RestMethod -Uri 'https://api.github.com/repos/UE4SS-RE/RE-UE4SS/releases/latest' `
                                 -Headers @{ 'User-Agent' = 'SmartNPC-Installer' } -TimeoutSec 30
        $asset = $rel.assets | Where-Object { $_.name -match '^UE4SS_v[\d\.]+\.zip$' } | Select-Object -First 1
        if ($asset) { $url = $asset.browser_download_url }
    } catch {}
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
        $layout = Get-UE4SSLayout -Win64 $Win64
        Say '  UE4SS installed. If the server now logs a UE4SS scan failure, run' Green
        Say '  REPAIR.bat: it removes exactly these files again.' Green
    } catch {
        Say "  UE4SS download failed: $($_.Exception.Message)" Red
    }
} else {
    Say 'UE4SS:    NOT FOUND - SmartNPC cannot run without it.' Red
    Say '  Install the UE4SS build made for SCUM, then run INSTALL.bat again.' Yellow
    Say '  SmartNPC deliberately does not pick a UE4SS version for you: the wrong' Yellow
    Say '  one silently disables every mod on the server.' Yellow
}

# If a previous SmartNPC version installed UE4SS on top of a working one, say so.
$stray = @(Get-DownloadedUE4SSFiles -ModHome $Dest -Win64 $Win64)
if ($stray.Count -gt 0 -and -not $ue4ssInstalledByUs) {
    Write-Host ''
    Say "NOTE:     an earlier SmartNPC version installed UE4SS into $Win64." Yellow
    Say '          If mods stopped loading, run REPAIR.bat to remove it again.' Yellow
    Write-Host ''
}

# ------------------------------------------------------------ UE4SS loader
# UE4SS 2.x keeps mods in Win64\Mods, 3.x in Win64\ue4ss\Mods.  Install the
# loader into every plausible root: a stub in the unused one is inert, while
# guessing wrong means the mod never starts at all.
$loaderReports = @()
foreach ($modsRoot in $layout.ModsRoots) {
    $stubPath = Write-LoaderStub -ModsRoot $modsRoot -ModHome $Dest
    $m = Set-ModsTxtEntry -ModsRoot $modsRoot
    Set-EnabledTxt -ModsRoot $modsRoot -Wanted (-not $m.Ok)
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
