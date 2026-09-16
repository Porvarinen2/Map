#requires -Version 5.1
<#
    SmartNPC uninstaller.

    Removes exactly what the installer added:
      <SCUM Server>\SmartNPC\
      <SCUM Server>\SCUM\Binaries\Win64\Mods\SmartNPC\
      the "SmartNPC : 1" line in Mods\mods.txt

    UE4SS is left alone unless SmartNPC installed it and -RemoveUE4SS is passed.
    Nothing else on the server is touched.
#>

param(
    [string]$ServerPath = '',
    [switch]$KeepBackup,
    [switch]$RemoveUE4SS,
    [switch]$Quiet
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false) } catch {}

function Say([string]$m, [string]$c = 'Gray') { Write-Host $m -ForegroundColor $c }

Write-Host ''
Write-Host 'SmartNPC uninstaller' -ForegroundColor Cyan

$Here = Split-Path -Parent $MyInvocation.MyCommand.Path
$libCandidates = @((Join-Path $Here 'lib.ps1'), (Join-Path $Here 'payload\SmartNPC\lib.ps1'))
foreach ($lib in $libCandidates) { if (Test-Path -LiteralPath $lib -PathType Leaf) { . $lib; break } }

# The uninstaller is copied into the mod home, so it can find the server from
# its own location; otherwise fall back to the usual search.
$Server = Find-ScumServer -Hint $ServerPath -SelfDir $Here
if (-not $Server) { throw 'SCUM Dedicated Server not found. Pass -ServerPath "<path>".' }
Say "server: $Server" Green

if (Get-Process -Name SCUMServer -ErrorAction SilentlyContinue) {
    throw 'SCUMServer.exe is running. Stop the server first - nothing has been changed.'
}

$Win64 = Join-Path $Server 'SCUM\Binaries\Win64'
$Dest  = Join-Path $Server 'SmartNPC'
$layout = Get-UE4SSLayout -Win64 $Win64

$manifest = $null
$mf = Join-Path $Dest 'install-manifest.json'
if (Test-Path -LiteralPath $mf -PathType Leaf) {
    try { $manifest = Get-Content -LiteralPath $mf -Raw -Encoding UTF8 | ConvertFrom-Json } catch {}
}

if (-not $Quiet) {
    Write-Host ''
    Say 'This removes:' Yellow
    Say "  $Dest"
    foreach ($modsRoot in $layout.ModsRoots) { Say ("  " + (Join-Path $modsRoot 'SmartNPC')) }
    Say '  the SmartNPC line in mods.txt'
    $a = Read-Host 'Continue? [y/N]'
    if ($a -notmatch '^[yYkK]') { Say 'Cancelled. Nothing changed.' ; exit 0 }
}

# ------------------------------------------------------- keep a final backup
if (-not $KeepBackup -and (Test-Path -LiteralPath $Dest)) {
    $bk = Join-Path $Server ('SmartNPC_Backups\uninstall_' + (Get-Date -Format 'yyyyMMdd_HHmmss'))
    New-Item -ItemType Directory -Path $bk -Force | Out-Null
    foreach ($keep in @('smartnpc.config.lua','state','logs','install-manifest.json')) {
        $p = Join-Path $Dest $keep
        if (Test-Path -LiteralPath $p) { Copy-Item -LiteralPath $p -Destination $bk -Recurse -Force }
    }
    Say "config, state and logs saved to: $bk" DarkGray
}

# --------------------------------------------------- loader in every mods root
foreach ($modsRoot in $layout.ModsRoots) {
    $stub = Join-Path $modsRoot 'SmartNPC'
    if (Test-Path -LiteralPath $stub) {
        Remove-Item -LiteralPath $stub -Recurse -Force -ErrorAction SilentlyContinue
        Say "removed $stub" Green
    }
    $modsTxt = Join-Path $modsRoot 'mods.txt'
    if (Test-Path -LiteralPath $modsTxt -PathType Leaf) {
        [void](Set-ModsTxtEntry -ModsRoot $modsRoot -Remove)
        $left = @(Get-Content -LiteralPath $modsTxt -Encoding UTF8 -ErrorAction SilentlyContinue)
        if ($manifest -and ($manifest.modsTxtExisted -eq $false) -and $left.Count -eq 0) {
            Remove-Item -LiteralPath $modsTxt -Force -ErrorAction SilentlyContinue
            Say "removed $modsTxt (SmartNPC created it)" DarkGray
        } else {
            Say "mods.txt: SmartNPC line removed from $modsTxt" Green
        }
    }
}

if ($RemoveUE4SS -and $manifest -and $manifest.ue4ssInstalledBy -eq 'SmartNPC') {
    $ext = Join-Path $Dest 'tools\ue4ss\extracted'
    if (Test-Path -LiteralPath $ext -PathType Container) {
        foreach ($item in (Get-ChildItem -LiteralPath $ext -Force)) {
            $target = Join-Path $Win64 $item.Name
            if (Test-Path -LiteralPath $target) { Remove-Item -LiteralPath $target -Recurse -Force }
        }
        Say 'UE4SS files installed by SmartNPC removed' Green
    }
}

if (Test-Path -LiteralPath $Dest) {
    # The uninstaller may be running from inside this folder; schedule the last
    # step so PowerShell is not deleting the script it is executing.
    $self = $MyInvocation.MyCommand.Path
    $inside = $self -and $self.StartsWith($Dest, [StringComparison]::OrdinalIgnoreCase)
    if (-not $inside) {
        Remove-Item -LiteralPath $Dest -Recurse -Force
        Say "removed $Dest" Green
    } else {
        # Delete everything we can right now, then let a detached shell remove
        # the folder itself once this script has exited.
        Get-ChildItem -LiteralPath $Dest -Force | Where-Object {
            $_.FullName -ne $self -and $_.Name -notlike 'UNINSTALL.*'
        } | ForEach-Object { Remove-Item -LiteralPath $_.FullName -Recurse -Force -ErrorAction SilentlyContinue }

        $exe = $null
        try { $exe = [Diagnostics.Process]::GetCurrentProcess().MainModule.FileName } catch {}
        if (-not $exe) { $exe = 'powershell.exe' }
        $cmd = "Start-Sleep -Seconds 2; Remove-Item -LiteralPath '$Dest' -Recurse -Force -ErrorAction SilentlyContinue"
        $spawned = $false
        try {
            Start-Process -FilePath $exe `
                -ArgumentList '-NoLogo','-NoProfile','-WindowStyle','Hidden','-Command',$cmd `
                -ErrorAction Stop | Out-Null
            $spawned = $true
        } catch {}
        if ($spawned) {
            Say "removing $Dest ..." Green
        } else {
            Say "Everything was removed except $Dest itself (the uninstaller is running from inside it)." Yellow
            Say 'Delete that folder by hand once this window is closed.' Yellow
        }
    }
}

Write-Host ''
Say 'SmartNPC uninstalled. The server, its save data and other mods are untouched.' Cyan
Write-Host ''
