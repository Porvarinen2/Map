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

# ------------------------------------------------ a second UE4SS at the root
# The UE4SS made for SCUM lives in Win64\ue4ss\.  An earlier SmartNPC could
# unpack a generic UE4SS at Win64 root; its proxy DLL then wins and fails SCUM's
# pattern scan, which stops every mod on the server.
$health0 = Test-UE4SSHealth -Win64 $Win64
if (-not $KeepUE4SS) {
    $stray = Get-StrayRootUE4SS -Win64 $Win64 -ModHome $Root -Version $health0.Version
    if ($stray.Duplicate) {
        Write-Host ''
        Say 'TWO UE4SS INSTALLS FOUND:' Yellow
        Say ("  in use  " + (Join-Path $Win64 'UE4SS.dll') + "   <- generic build, added by an earlier SmartNPC") Yellow
        Say ("  unused  " + (Join-Path $Win64 'ue4ss\UE4SS.dll') + "   <- your SCUM build") Yellow
        Write-Host ''

        if (-not $stray.Reference) {
            Say 'Could not fetch a reference copy to compare against, so nothing was' Red
            Say 'deleted automatically. Remove these from' Red
            Say ("  " + $Win64) Red
            foreach ($n in @('UE4SS.dll','UE4SS-settings.ini','dwmapi.dll','Changelog.md','README.md')) {
                if (Test-Path -LiteralPath (Join-Path $Win64 $n) -PathType Leaf) { Say ("    " + $n) DarkGray }
            }
            Say 'then reinstall the UE4SS build made for SCUM.' Yellow
        } else {
            $removable = @($stray.Files | Where-Object { $_.Unchanged })
            if ($removable.Count -eq 0) {
                Say 'The files at the root do not match the stock release, so they were' Yellow
                Say 'left alone. Remove them by hand if you know they are not yours.' Yellow
            } else {
                Say 'These are byte-for-byte the stock release and can be removed:' Gray
                foreach ($f in ($removable | Select-Object -First 12)) { Say ("    " + $f.Relative) DarkGray }
                if ($removable.Count -gt 12) { Say ("    ... and " + ($removable.Count - 12) + " more") DarkGray }
                Write-Host ''
                $go = 'y'
                if (-not $Quiet) { $go = Read-Host 'Remove them? [Y/n]'; if (-not $go) { $go = 'y' } }
                if ($go -match '^[yYkK]') {
                    $removed = 0; $kept = @()
                    foreach ($f in $removable) {
                        try { Remove-Item -LiteralPath $f.Path -Force -ErrorAction Stop; $removed++ }
                        catch { $kept += $f.Relative }
                    }
                    foreach ($pass in 1..3) {
                        foreach ($d in (Get-ChildItem -LiteralPath $Win64 -Recurse -Directory -Force -ErrorAction SilentlyContinue |
                                        Sort-Object { $_.FullName.Length } -Descending)) {
                            if ($d.Name -eq 'ue4ss') { continue }
                            if (-not (Get-ChildItem -LiteralPath $d.FullName -Force -ErrorAction SilentlyContinue)) {
                                Remove-Item -LiteralPath $d.FullName -Force -ErrorAction SilentlyContinue
                            }
                        }
                    }
                    Say ("Removed " + $removed + " of " + $removable.Count + " files.") Green
                    if ($kept.Count -gt 0) {
                        Say 'Could not remove (close the server and retry):' DarkYellow
                        foreach ($k in ($kept | Select-Object -First 8)) { Say ("    " + $k) DarkGray }
                    }
                    Write-Host ''
                    Say 'IMPORTANT: that generic UE4SS overwrote the proxy DLL your SCUM' Yellow
                    Say 'UE4SS needs. Reinstall the UE4SS build made for SCUM now, then' Yellow
                    Say 'run REPAIR.bat again.' Yellow
                }
            }
        }
        Write-Host ''
    }
}

$layout = Get-UE4SSLayout -Win64 $Win64

# A UE4SS with no proxy DLL beside the game executable never gets loaded at all.
if ($layout.HasUE4SS) {
    $proxy = @(Get-UE4SSProxy -Win64 $Win64)
    if ($proxy.Count -eq 0) {
        Write-Host ''
        Say 'NO UE4SS LOADER DLL FOUND next to SCUMServer.exe.' Red
        Say 'UE4SS is loaded by a proxy DLL (dwmapi.dll and friends). Without one' Yellow
        Say 'it never starts. Reinstall the UE4SS build made for SCUM - that puts' Yellow
        Say 'the proxy back.' Yellow
        Write-Host ''
    }
}

# ------------------------------------------------------------ UE4SS health
$health = Test-UE4SSHealth -Win64 $Win64 -NotBefore (Get-LoaderWriteTime -Layout $layout)
if ($health.Stale) {
    Write-Host ''
    Say 'UE4SS has not run since the last change, so there is no verdict yet.' DarkGray
    Say 'Restart the SCUM server, then run STATUS.bat.' DarkGray
    Write-Host ''
} elseif ($health.Fatal) {
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

# Drop loaders left in a Mods folder that no installed UE4SS reads any more.
foreach ($dead in $layout.OtherRoots) {
    if (Remove-LoaderFrom -ModsRoot $dead) {
        Say ("removed a stale loader from " + $dead) DarkGray
    }
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
