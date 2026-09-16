#requires -Version 5.1
<#
    SmartNPC repair.

    Re-registers the UE4SS loader without touching your config, state or logs.
    Run this if STATUS reports a failing loader stub or mods.txt entry - that is
    the one thing that stops the mod from starting at all.
#>

param(
    [string]$ServerPath = '',
    [switch]$KeepUE4SS,
    [switch]$Quiet
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false) } catch {}

$Root = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $Root 'lib.ps1')

function Say([string]$m, [string]$c = 'Gray') { Write-Host $m -ForegroundColor $c }

Write-Host ''
Write-Host 'SmartNPC repair' -ForegroundColor Cyan
Write-Host ''

$Server = Find-ScumServer -Hint $ServerPath -SelfDir $Root
if (-not $Server) { throw 'SCUM Dedicated Server not found. Pass -ServerPath "<path>".' }
Say "server:   $Server" Green
Say "mod home: $Root" Green

$running = [bool](Get-Process -Name SCUMServer -ErrorAction SilentlyContinue)
if ($running) {
    Say 'SCUMServer.exe is running: the repair is written now but only takes' Yellow
    Say 'effect after you restart the server.' Yellow
}

$Win64 = Join-Path $Server 'SCUM\Binaries\Win64'

# ---------------------------------------------------- UE4SS installed by us
# An earlier SmartNPC installed UE4SS when it did not find Win64\UE4SS.dll.
# On a server whose UE4SS lives in Win64\ue4ss\ that dropped a second, generic
# UE4SS - proxy DLL included - at Win64 root, where it takes over loading and
# then fails on SCUM's build, which stops every mod on the server.
if (-not $KeepUE4SS) {
    $stray = @(Get-DownloadedUE4SSFiles -ModHome $Root -Win64 $Win64)
    $removable = @($stray | Where-Object { $_.Unchanged })
    if ($removable.Count -gt 0) {
        Write-Host ''
        Say 'An earlier SmartNPC version installed UE4SS into the server:' Yellow
        foreach ($f in ($removable | Select-Object -First 12)) { Say ("    " + $f.Relative) DarkGray }
        if ($removable.Count -gt 12) { Say ("    ... and " + ($removable.Count - 12) + " more") DarkGray }
        Write-Host ''
        $go = 'y'
        if (-not $Quiet) { $go = Read-Host 'Remove these files again? [Y/n]'; if (-not $go) { $go = 'y' } }
        if ($go -match '^[yYkK]') {
            $res = Remove-DownloadedUE4SS -ModHome $Root -Win64 $Win64
            Say ("Removed " + $res.Removed + " of " + $res.Total + " files.") Green
            if ($res.Kept.Count -gt 0) {
                Say 'Left in place because they were modified after installation:' DarkYellow
                foreach ($k in ($res.Kept | Select-Object -First 8)) { Say ("    " + $k) DarkGray }
            }
            Write-Host ''
            Say 'Now reinstall the UE4SS build made for SCUM (it also restores the' Yellow
            Say 'proxy DLL), then run this repair again.' Yellow
        }
        Write-Host ''
    }
}

$layout = Get-UE4SSLayout -Win64 $Win64

# ------------------------------------------------------------ UE4SS health
$health = Test-UE4SSHealth -Win64 $Win64
if ($health.Fatal) {
    Write-Host ''
    Say 'UE4SS ITSELF IS FAILING:' Red
    Say ("  " + $health.Reason) Red
    if ($health.Version) { Say ("  installed: " + $health.Version) DarkGray }
    Say '  No Lua mod can load until UE4SS starts. Install the UE4SS build made' Yellow
    Say '  for this SCUM version, then run this repair again.' Yellow
    Write-Host ''
}

Write-Host ''
if ($layout.HasUE4SS) { Say "UE4SS:    $($layout.Dll)" Green }
else { Say 'UE4SS:    NOT FOUND - install it before anything else works' Red }
Say ("mods roots: " + ($layout.ModsRoots -join '  |  '))
Write-Host ''

foreach ($sub in @('state','output','logs','tools')) {
    $p = Join-Path $Root $sub
    if (-not (Test-Path -LiteralPath $p)) { New-Item -ItemType Directory -Path $p -Force | Out-Null }
}

$any = $false
foreach ($modsRoot in $layout.ModsRoots) {
    try {
        $stub = Write-LoaderStub -ModsRoot $modsRoot -ModHome $Root
        $m = Set-ModsTxtEntry -ModsRoot $modsRoot
        Set-EnabledTxt -ModsRoot $modsRoot -Wanted (-not $m.Ok)
        $check = Test-SmartNPCLoader -ModsRoot $modsRoot -ModHome $Root

        Say ("  " + $modsRoot)
        Say ("    Scripts\main.lua   " + $(if ($check.StubOk -and $check.PointsHere) { 'OK' } else { 'FAILED' })) `
            $(if ($check.StubOk -and $check.PointsHere) { 'Green' } else { 'Red' })
        Say ("    enabled.txt        " + $(if ($check.Enabled) { 'written (mods.txt fallback)' } else { 'not needed' })) DarkGray
        Say ("    mods.txt entry     " + $(if ($check.Listed) { 'OK' } else { 'FAILED' })) `
            $(if ($check.Listed) { 'Green' } else { 'Red' })
        if ($check.StubOk -and ($check.Listed -or $check.Enabled)) { $any = $true }
    } catch {
        Say ("  " + $modsRoot + "  -> " + $_.Exception.Message) Red
    }
}

Write-Host ''
if ($any) {
    Say 'Loader registered. Restart the SCUM server, then run STATUS.bat again.' Green
} else {
    Say 'Could not write the loader. Close the server, then run this as Administrator.' Red
}
Write-Host ''
