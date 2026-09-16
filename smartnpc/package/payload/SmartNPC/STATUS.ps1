#requires -Version 5.1
<#
    SmartNPC status.
    Answers, in order, the questions that matter when something looks wrong:
    is the loader registered where UE4SS actually reads it, did UE4SS load the
    mod, is the mod ticking, and is it moving anyone.
#>

param([string]$ServerPath = '')

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Continue'
try { [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false) } catch {}

$Root = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $Root 'lib.ps1')

function Line($k, $v, $c = 'Gray') {
    Write-Host ("  {0,-22}" -f $k) -NoNewline
    Write-Host $v -ForegroundColor $c
}
function Check($k, $ok, $detail) {
    Write-Host ("  {0,-22}" -f $k) -NoNewline
    if ($ok) { Write-Host "OK    $detail" -ForegroundColor Green }
    else     { Write-Host "FAIL  $detail" -ForegroundColor Red }
}

Write-Host ''
Write-Host 'SmartNPC status' -ForegroundColor Cyan
Write-Host ''

$Server = Find-ScumServer -Hint $ServerPath -SelfDir $Root
if (-not $Server) {
    Line 'server' 'NOT FOUND - pass -ServerPath "<path>"' Red
    Write-Host ''
    exit 1
}
$Win64 = Join-Path $Server 'SCUM\Binaries\Win64'

Line 'mod home' $Root
Line 'server' $Server
$running = [bool](Get-Process -Name SCUMServer -ErrorAction SilentlyContinue)
Line 'SCUMServer.exe' $(if ($running) { 'running' } else { 'not running' }) $(if ($running) { 'Green' } else { 'Yellow' })

$layout = Get-UE4SSLayout -Win64 $Win64
Check 'UE4SS' $layout.HasUE4SS $(if ($layout.Dll) { $layout.Dll } else { "not found under $Win64" })

# Whether UE4SS itself started is the first thing that matters: when its
# pattern scan fails, no Lua mod on the server loads and nothing below applies.
$health = Test-UE4SSHealth -Win64 $Win64
if ($health.Version) { Line 'UE4SS version' $health.Version }
if ($health.Fatal) {
    Write-Host ''
    Write-Host '  ##############################################################' -ForegroundColor Red
    Write-Host '  UE4SS IS NOT STARTING. No mod on this server can load.' -ForegroundColor Red
    Write-Host ("  " + $health.Reason) -ForegroundColor Red
    Write-Host '  This is not a SmartNPC problem: Keybinds, BPModLoader and every' -ForegroundColor Yellow
    Write-Host '  other mod are dead too. Install the UE4SS build made for this' -ForegroundColor Yellow
    Write-Host '  SCUM version, then run REPAIR.bat.' -ForegroundColor Yellow
    Write-Host '  ##############################################################' -ForegroundColor Red
}

# Two UE4SS installs in one folder is the failure mode that kills every mod:
# the one at the root wins, and on SCUM it is the wrong one.
if ((Test-Path -LiteralPath (Join-Path $Win64 'UE4SS.dll') -PathType Leaf) -and
    (Test-Path -LiteralPath (Join-Path $Win64 'ue4ss\UE4SS.dll') -PathType Leaf)) {
    Write-Host ''
    Line 'UE4SS installs' 'TWO FOUND - the one at Win64 root is loading, not your ue4ss\ one' Red
    Line '' 'run REPAIR.bat to remove the duplicate' Yellow
}

Write-Host ''
Write-Host '  loader registration' -ForegroundColor DarkCyan
$loaderOk = $false
foreach ($modsRoot in $layout.ModsRoots) {
    $c = Test-SmartNPCLoader -ModsRoot $modsRoot -ModHome $Root
    Line '  mods root' $modsRoot
    Check '  Scripts\main.lua' ($c.StubOk -and $c.PointsHere) $(if ($c.StubOk -and -not $c.PointsHere) { 'stub points at a different folder' } else { '' })
    Check '  mods.txt entry' $c.Listed 'SmartNPC : 1'
    Line '  enabled.txt' $(if ($c.Enabled) { 'present (UE4SS 3.x)' } else { 'missing' }) $(if ($c.Enabled) { 'Green' } else { 'Yellow' })
    if (Test-Path -LiteralPath $c.ModsTxt -PathType Leaf) {
        $content = @(Get-Content -LiteralPath $c.ModsTxt -Encoding UTF8 -ErrorAction SilentlyContinue)
        Line '  mods.txt contents' $(if ($content.Count) { ($content -join ' | ') } else { '(empty)' }) DarkGray
    } else {
        Line '  mods.txt' 'missing' Red
    }
    if ($c.StubOk -and ($c.Listed -or $c.Enabled)) { $loaderOk = $true }
    Write-Host ''
}
if (-not $loaderOk) {
    Write-Host '  >>> The loader is not registered. Run REPAIR.bat, then restart the server.' -ForegroundColor Yellow
    Write-Host ''
}

# ---------------------------------------------------------------- UE4SS log
$ue4ssLog = Get-UE4SSLogPath -Win64 $Win64
if ($ue4ssLog) {
    $hits = @(Select-String -LiteralPath $ue4ssLog -Pattern 'SmartNPC' -SimpleMatch -ErrorAction SilentlyContinue |
              Select-Object -Last 10)
    Line 'UE4SS log' $ue4ssLog DarkGray
    if ($hits.Count) {
        Write-Host '  UE4SS says about SmartNPC' -ForegroundColor DarkCyan
        $hits | ForEach-Object { Write-Host ("    " + $_.Line.Trim()) -ForegroundColor DarkGray }
    } else {
        Line 'UE4SS log mentions' 'nothing about SmartNPC - UE4SS never loaded it' Yellow
    }
} else {
    Line 'UE4SS log' "not found under $Win64" Yellow
}

# ------------------------------------------------------------------ mod log
Write-Host ''
$log = Join-Path $Root 'logs\smartnpc.log'
if (Test-Path -LiteralPath $log -PathType Leaf) {
    $info = Get-Item -LiteralPath $log
    Line 'log file' ("{0:N0} kB, last write {1:HH:mm:ss}" -f ($info.Length / 1kb), $info.LastWriteTime)
    Write-Host ''
    Write-Host '  last log lines' -ForegroundColor DarkCyan
    Get-Content -LiteralPath $log -Tail 14 -Encoding UTF8 | ForEach-Object { Write-Host "    $_" -ForegroundColor DarkGray }
} else {
    Line 'log file' 'none yet - the mod has not started' Yellow
}

# ---------------------------------------------------------------- telemetry
Write-Host ''
$world = Join-Path $Root 'output\world.json'
if (Test-Path -LiteralPath $world -PathType Leaf) {
    $age = ((Get-Date) - (Get-Item -LiteralPath $world).LastWriteTime).TotalSeconds
    Line 'telemetry age' ("{0:N1} s" -f $age) $(if ($age -lt 10) { 'Green' } elseif ($age -lt 60) { 'Yellow' } else { 'Red' })
    try {
        $j = Get-Content -LiteralPath $world -Raw -Encoding UTF8 | ConvertFrom-Json
        $st = Get-Prop $j 'stats'
        if ($st) {
            Line 'squads'   (Get-Prop $st 'squads' 0)
            Line 'npcs'     (Get-Prop $st 'npcs' 0)
            Line 'physical / virtual' ("{0} / {1}" -f (Get-Prop $st 'physical' 0), (Get-Prop $st 'virtual' 0))
            Line 'players'  (Get-Prop $st 'players' 0)
            Line 'npcs moving' (Get-Prop $st 'moving' 0)
            Line 'move commands' (Get-Prop $st 'commands' 0)
            Line 'stall recoveries' (Get-Prop $st 'stalls' 0)
            $classes = Get-Prop $st 'classes'
            if ($classes) {
                $hits2 = @()
                foreach ($p in $classes.PSObject.Properties) {
                    if ($p.Value -gt 0) { $hits2 += ("{0}={1}" -f $p.Name, $p.Value) }
                }
                Line 'npc classes found' $(if ($hits2.Count) { ($hits2 -join ', ') } else { 'none yet' }) `
                     $(if ($hits2.Count) { 'Green' } else { 'Yellow' })
            }
        }
        $events = @(Get-Prop $j 'events' @())
        if ($events.Count -gt 0) {
            Write-Host ''
            Write-Host '  recent world events' -ForegroundColor DarkCyan
            $events | Select-Object -Last 10 | ForEach-Object {
                Write-Host ("    {0}  {1,-14} {2,-10} {3}" -f (Get-Prop $_ 't'), (Get-Prop $_ 'kind'),
                            (Get-Prop $_ 'who'), (Get-Prop $_ 'what')) -ForegroundColor DarkGray
            }
        }
    } catch {
        Line 'telemetry' "could not be parsed: $($_.Exception.Message)" Red
    }
} else {
    Line 'telemetry' 'output\world.json missing - the mod has not ticked yet' Yellow
}

Write-Host ''
Write-Host '  If the loader is OK but no log appears, send the UE4SS log above.' -ForegroundColor DarkYellow
Write-Host '  If "npc classes found" stays empty, send logs\smartnpc.log.' -ForegroundColor DarkYellow
Write-Host ''
