#requires -Version 5.1
<#
    SmartNPC repair.

    Re-registers the UE4SS loader without touching your config, state or logs.
    Run this if STATUS reports a failing loader stub or mods.txt entry - that is
    the one thing that stops the mod from starting at all.
#>

param(
    [string]$ServerPath = ''
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
$layout = Get-UE4SSLayout -Win64 $Win64

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
        $check = Test-SmartNPCLoader -ModsRoot $modsRoot -ModHome $Root

        Say ("  " + $modsRoot)
        Say ("    Scripts\main.lua   " + $(if ($check.StubOk -and $check.PointsHere) { 'OK' } else { 'FAILED' })) `
            $(if ($check.StubOk -and $check.PointsHere) { 'Green' } else { 'Red' })
        Say ("    enabled.txt        " + $(if ($check.Enabled) { 'OK' } else { 'missing' })) `
            $(if ($check.Enabled) { 'Green' } else { 'Yellow' })
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
