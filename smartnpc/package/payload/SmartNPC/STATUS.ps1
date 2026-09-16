#requires -Version 5.1
<#
    SmartNPC status check.
    Answers, in order, the questions that matter when something looks wrong:
    is the mod installed, did it load, is it ticking, and is it moving anyone.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Continue'
try { [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false) } catch {}

$Root   = Split-Path -Parent $MyInvocation.MyCommand.Path
$Server = Split-Path -Parent $Root
$Win64  = Join-Path $Server 'SCUM\Binaries\Win64'

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

Line 'mod home' $Root
Line 'server' $Server

$running = [bool](Get-Process -Name SCUMServer -ErrorAction SilentlyContinue)
Line 'SCUMServer.exe' $(if ($running) { 'running' } else { 'not running' }) $(if ($running) { 'Green' } else { 'Yellow' })

Check 'UE4SS' (Test-Path -LiteralPath (Join-Path $Win64 'UE4SS.dll')) (Join-Path $Win64 'UE4SS.dll')
$stub = Join-Path $Win64 'Mods\SmartNPC\Scripts\main.lua'
Check 'loader stub' (Test-Path -LiteralPath $stub) $stub
$modsTxt = Join-Path $Win64 'Mods\mods.txt'
$enabled = $false
if (Test-Path -LiteralPath $modsTxt) {
    $enabled = [bool](Get-Content -LiteralPath $modsTxt -Encoding UTF8 | Where-Object { $_ -match '^\s*SmartNPC\s*:\s*1' })
}
Check 'mods.txt entry' $enabled 'SmartNPC : 1'

Write-Host ''

$log = Join-Path $Root 'logs\smartnpc.log'
if (Test-Path -LiteralPath $log -PathType Leaf) {
    $info = Get-Item -LiteralPath $log
    Line 'log file' ("{0:N0} kB, last write {1:HH:mm:ss}" -f ($info.Length / 1kb), $info.LastWriteTime)
    Write-Host ''
    Write-Host '  last log lines' -ForegroundColor DarkCyan
    Get-Content -LiteralPath $log -Tail 12 -Encoding UTF8 | ForEach-Object { Write-Host "    $_" -ForegroundColor DarkGray }
} else {
    Line 'log file' 'none yet - the mod has not started' Yellow
}

Write-Host ''
$world = Join-Path $Root 'output\world.json'
if (Test-Path -LiteralPath $world -PathType Leaf) {
    $age = ((Get-Date) - (Get-Item -LiteralPath $world).LastWriteTime).TotalSeconds
    Line 'telemetry age' ("{0:N1} s" -f $age) $(if ($age -lt 10) { 'Green' } elseif ($age -lt 60) { 'Yellow' } else { 'Red' })
    try {
        $j = Get-Content -LiteralPath $world -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($j.stats) {
            Line 'squads'   $j.stats.squads
            Line 'npcs'     $j.stats.npcs
            Line 'physical / virtual' ("{0} / {1}" -f $j.stats.physical, $j.stats.virtual)
            Line 'players'  $j.stats.players
            Line 'npcs moving' $j.stats.moving
            Line 'move commands' $j.stats.commands
            Line 'stall recoveries' $j.stats.stalls
            Line 'ground samples' $j.stats.ground
            if ($j.stats.classes) {
                $hits = @()
                foreach ($p in $j.stats.classes.PSObject.Properties) {
                    if ($p.Value -gt 0) { $hits += ("{0}={1}" -f $p.Name, $p.Value) }
                }
                Line 'npc classes found' $(if ($hits.Count) { ($hits -join ', ') } else { 'none yet' }) `
                     $(if ($hits.Count) { 'Green' } else { 'Yellow' })
            }
        }
        if ($j.events) {
            Write-Host ''
            Write-Host '  recent world events' -ForegroundColor DarkCyan
            $j.events | Select-Object -Last 10 | ForEach-Object {
                Write-Host ("    {0}  {1,-14} {2,-10} {3}" -f $_.t, $_.kind, $_.who, $_.what) -ForegroundColor DarkGray
            }
        }
    } catch {
        Line 'telemetry' "could not be parsed: $($_.Exception.Message)" Red
    }
} else {
    Line 'telemetry' 'output\world.json missing - the mod has not ticked yet' Yellow
}

Write-Host ''
Write-Host '  If NPC classes stay at "none yet" after a few minutes with the server up,' -ForegroundColor DarkYellow
Write-Host '  send logs\smartnpc.log - the class names in this SCUM build differ.' -ForegroundColor DarkYellow
Write-Host ''
