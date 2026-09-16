# StrictMode tests for lib.ps1.
# These exist because an empty array returned from a function is the single
# easiest way to break a PowerShell script only on the user's machine: under
# Set-StrictMode the collapsed value throws on .Count and on property access,
# and a wrapper like ",@($x)" hands the caller the array itself instead of its
# items. Both bugs shipped once; this file makes sure they cannot ship again.

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$here = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $here '../package/payload/SmartNPC/lib.ps1')

$fail = 0
function Check([string]$name, [scriptblock]$body) {
    try {
        & $body
        Write-Host "  [PASS] $name" -ForegroundColor Green
    } catch {
        $script:fail++
        Write-Host "  [FAIL] $name" -ForegroundColor Red
        Write-Host "         $($_.Exception.Message)" -ForegroundColor DarkRed
    }
}

$tmp = Join-Path ([IO.Path]::GetTempPath()) ("smartnpc_tests_" + [guid]::NewGuid().ToString('N'))
$win64 = Join-Path $tmp 'Win64'
$home_ = Join-Path $tmp 'SmartNPC'
New-Item -ItemType Directory -Path $win64 -Force | Out-Null
New-Item -ItemType Directory -Path $home_ -Force | Out-Null

Write-Host ''
Write-Host 'lib.ps1 under StrictMode' -ForegroundColor Cyan

# ---------------------------------------------------------------- empty cases
Check 'Get-DownloadedUE4SSFiles with no tools folder is an empty list' {
    $r = @(Get-DownloadedUE4SSFiles -ModHome $home_ -Win64 $win64)
    if ($r.Count -ne 0) { throw "expected 0 items, got $($r.Count)" }
    # the exact shape that broke REPAIR on the user's machine
    $sel = @($r | Where-Object { $_.Unchanged })
    if ($sel.Count -ne 0) { throw 'filter over an empty result must stay empty' }
}

Check 'Remove-DownloadedUE4SS on a clean server is a no-op' {
    $r = Remove-DownloadedUE4SS -ModHome $home_ -Win64 $win64
    if ($r.Removed -ne 0 -or $r.Total -ne 0) { throw "expected nothing removed, got $($r.Removed)/$($r.Total)" }
    if (@($r.Kept).Count -ne 0) { throw 'nothing should be kept' }
}

Check 'Get-MapServerProcess returns an enumerable list' {
    $r = @(Get-MapServerProcess -ModHome $home_)
    foreach ($p in $r) { $null = $p.ProcessId }   # would throw on a nested array
}

# ----------------------------------------------------------- populated cases
$extracted = Join-Path $home_ 'tools\ue4ss\extracted'
New-Item -ItemType Directory -Path (Join-Path $extracted 'Mods') -Force | Out-Null
'stock' | Set-Content -LiteralPath (Join-Path $extracted 'UE4SS.dll') -NoNewline
'stock' | Set-Content -LiteralPath (Join-Path $extracted 'dwmapi.dll') -NoNewline
'stock' | Set-Content -LiteralPath (Join-Path $extracted 'Mods\mods.txt') -NoNewline
'stock' | Set-Content -LiteralPath (Join-Path $win64 'UE4SS.dll') -NoNewline
'stock' | Set-Content -LiteralPath (Join-Path $win64 'dwmapi.dll') -NoNewline
New-Item -ItemType Directory -Path (Join-Path $win64 'Mods') -Force | Out-Null
'edited by the user' | Set-Content -LiteralPath (Join-Path $win64 'Mods\mods.txt') -NoNewline

Check 'each returned entry really is an object with Unchanged' {
    $r = @(Get-DownloadedUE4SSFiles -ModHome $home_ -Win64 $win64)
    if ($r.Count -ne 3) { throw "expected 3 entries, got $($r.Count)" }
    foreach ($e in $r) {
        if ($null -eq $e.Relative) { throw 'entry without Relative' }
        if ($e -is [array]) { throw 'entry is an array, not an object' }
    }
    $unchanged = @($r | Where-Object { $_.Unchanged })
    if ($unchanged.Count -ne 2) { throw "expected 2 untouched files, got $($unchanged.Count)" }
}

Check 'Remove-DownloadedUE4SS deletes only byte-identical files' {
    $r = Remove-DownloadedUE4SS -ModHome $home_ -Win64 $win64
    if ($r.Removed -ne 2) { throw "expected 2 removed, got $($r.Removed)" }
    if (Test-Path -LiteralPath (Join-Path $win64 'UE4SS.dll')) { throw 'stock UE4SS.dll should be gone' }
    if (-not (Test-Path -LiteralPath (Join-Path $win64 'Mods\mods.txt'))) { throw 'edited mods.txt must survive' }
    if (@($r.Kept).Count -ne 1) { throw "expected 1 kept, got $(@($r.Kept).Count)" }
}

# ------------------------------------------------------------------- health
Check 'Test-UE4SSHealth with no log is not fatal' {
    $h = Test-UE4SSHealth -Win64 $win64
    if ($h.Fatal) { throw 'a missing log is not a failure' }
}

Check 'Test-UE4SSHealth detects a timed out pattern scan' {
    @(
        '[2026-09-16 01:41:07] UE4SS - v3.0.1 Beta #0 - Git SHA #d935b5b'
        '[2026-09-16 01:41:38] [PS] Scan failed'
        '[2026-09-16 01:41:38] Fatal Error: PS scan timed out'
    ) | Set-Content -LiteralPath (Join-Path $win64 'UE4SS.log')
    $h = Test-UE4SSHealth -Win64 $win64
    if (-not $h.Fatal) { throw 'must be reported as fatal' }
    if ($h.Version -notlike 'v3.0.1*') { throw "version not parsed: $($h.Version)" }
}

# ------------------------------------------------------------------- layout
Check 'Get-UE4SSLayout prefers the ue4ss folder when it exists' {
    New-Item -ItemType Directory -Path (Join-Path $win64 'ue4ss\Mods') -Force | Out-Null
    'x' | Set-Content -LiteralPath (Join-Path $win64 'ue4ss\UE4SS.dll') -NoNewline
    $l = Get-UE4SSLayout -Win64 $win64
    if (-not $l.HasUE4SS) { throw 'UE4SS not detected' }
    $roots = @($l.ModsRoots)
    if ($roots.Count -lt 1) { throw 'no mods root' }
    if ($roots[0] -notlike '*ue4ss*Mods') { throw "wrong first root: $($roots[0])" }
}

Check 'loader round trip: stub, mods.txt entry, verification' {
    $modsRoot = Join-Path $win64 'ue4ss\Mods'
    'Keybinds : 1' | Set-Content -LiteralPath (Join-Path $modsRoot 'mods.txt')
    [void](Write-LoaderStub -ModsRoot $modsRoot -ModHome $home_)
    $m = Set-ModsTxtEntry -ModsRoot $modsRoot
    if (-not $m.Ok) { throw 'mods.txt entry not verified' }
    Set-EnabledTxt -ModsRoot $modsRoot -Wanted (-not $m.Ok)
    $c = Test-SmartNPCLoader -ModsRoot $modsRoot -ModHome $home_
    if (-not $c.StubOk) { throw 'stub missing' }
    if (-not $c.PointsHere) { throw 'stub does not point at the mod home' }
    if (-not $c.Listed) { throw 'not listed in mods.txt' }
    if ($c.Enabled) { throw 'enabled.txt must not be written when mods.txt works' }
    $lines = @(Get-Content -LiteralPath (Join-Path $modsRoot 'mods.txt'))
    if ($lines -notcontains 'Keybinds : 1') { throw 'other mods must survive' }
}

Check 'uninstall removes only the SmartNPC line' {
    $modsRoot = Join-Path $win64 'ue4ss\Mods'
    [void](Set-ModsTxtEntry -ModsRoot $modsRoot -Remove)
    $lines = @(Get-Content -LiteralPath (Join-Path $modsRoot 'mods.txt'))
    if ($lines -contains 'SmartNPC : 1') { throw 'SmartNPC line still present' }
    if ($lines -notcontains 'Keybinds : 1') { throw 'other mods must survive' }
}

# ------------------------------------------------------------------- sync
Check 'Sync-ModFiles never touches the user folders' {
    $src = Join-Path $tmp 'payload'
    New-Item -ItemType Directory -Path (Join-Path $src 'lua') -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $src 'state') -Force | Out-Null
    'new' | Set-Content -LiteralPath (Join-Path $src 'lua\boot.lua') -NoNewline
    'package state that must be ignored' | Set-Content -LiteralPath (Join-Path $src 'state\squads.tsv') -NoNewline

    $dst = Join-Path $tmp 'installed'
    New-Item -ItemType Directory -Path (Join-Path $dst 'state') -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $dst 'lua') -Force | Out-Null
    'MY STATE' | Set-Content -LiteralPath (Join-Path $dst 'state\squads.tsv') -NoNewline
    'stale module' | Set-Content -LiteralPath (Join-Path $dst 'lua\gone.lua') -NoNewline

    $r = Sync-ModFiles -Source $src -Dest $dst
    if (@($r.Failed).Count -ne 0) { throw "unexpected failures: $($r.Failed -join ',')" }
    if ((Get-Content -LiteralPath (Join-Path $dst 'state\squads.tsv') -Raw) -ne 'MY STATE') {
        throw 'user state was overwritten'
    }
    if (Test-Path -LiteralPath (Join-Path $dst 'lua\gone.lua')) { throw 'stale module not pruned' }
    if ((Get-Content -LiteralPath (Join-Path $dst 'lua\boot.lua') -Raw) -ne 'new') { throw 'code not updated' }
}

Check 'Sync-ModFiles clears a directory sitting where a file belongs' {
    $src = Join-Path $tmp 'payload'
    $dst = Join-Path $tmp 'installed'
    Remove-Item -LiteralPath (Join-Path $dst 'lua\boot.lua') -Force
    New-Item -ItemType Directory -Path (Join-Path $dst 'lua\boot.lua') -Force | Out-Null
    $r = Sync-ModFiles -Source $src -Dest $dst
    if (@($r.Failed).Count -ne 0) { throw "unexpected failures: $($r.Failed -join ',')" }
    if (-not (Test-Path -LiteralPath (Join-Path $dst 'lua\boot.lua') -PathType Leaf)) {
        throw 'boot.lua should be a file again'
    }
}

Check 'Get-StrayRootUE4SS: single install is not a duplicate' {
    $w = Join-Path $tmp 'single'
    New-Item -ItemType Directory -Path (Join-Path $w 'ue4ss') -Force | Out-Null
    'x' | Set-Content -LiteralPath (Join-Path $w 'ue4ss\UE4SS.dll') -NoNewline
    $r = Get-StrayRootUE4SS -Win64 $w
    if ($r.Duplicate) { throw 'one install must not be flagged' }
    if (@($r.Files).Count -ne 0) { throw 'no files expected' }
}

Check 'Get-StrayRootUE4SS: two installs are flagged and matched by hash' {
    $w = Join-Path $tmp 'dupe'
    $mh = Join-Path $tmp 'dupehome'
    New-Item -ItemType Directory -Path (Join-Path $w 'ue4ss') -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $mh 'tools\ue4ss\extracted\Mods') -Force | Out-Null
    'scum-build'  | Set-Content -LiteralPath (Join-Path $w 'ue4ss\UE4SS.dll') -NoNewline
    'stock'       | Set-Content -LiteralPath (Join-Path $w 'UE4SS.dll') -NoNewline
    'stock'       | Set-Content -LiteralPath (Join-Path $w 'dwmapi.dll') -NoNewline
    'user edited' | Set-Content -LiteralPath (Join-Path $w 'UE4SS-settings.ini') -NoNewline
    foreach ($n in @('UE4SS.dll','dwmapi.dll','UE4SS-settings.ini')) {
        'stock' | Set-Content -LiteralPath (Join-Path $mh "tools\ue4ss\extracted\$n") -NoNewline
    }
    $r = Get-StrayRootUE4SS -Win64 $w -ModHome $mh
    if (-not $r.Duplicate) { throw 'duplicate not detected' }
    $removable = @($r.Files | Where-Object { $_.Unchanged })
    if ($removable.Count -ne 2) { throw "expected 2 removable, got $($removable.Count)" }
    if (@($r.Files | Where-Object { -not $_.Unchanged }).Count -ne 1) { throw 'edited file must be kept' }
    $sep = [IO.Path]::DirectorySeparatorChar
    if ($r.Files | Where-Object { $_.Path -like ("*" + $sep + "ue4ss" + $sep + "*") }) {
        throw 'must never touch anything inside the ue4ss folder'
    }
}

Check 'layout: the DLL decides which Mods folder is real' {
    $w = Join-Path $tmp 'layout'
    New-Item -ItemType Directory -Path (Join-Path $w 'ue4ss\Mods') -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $w 'Mods') -Force | Out-Null
    'x' | Set-Content -LiteralPath (Join-Path $w 'ue4ss\UE4SS.dll') -NoNewline
    $l = Get-UE4SSLayout -Win64 $w
    if (@($l.ModsRoots).Count -ne 1) { throw "expected one live root, got $(@($l.ModsRoots).Count)" }
    if (@($l.ModsRoots)[0] -notlike '*ue4ss*Mods') { throw 'wrong live root' }
    if (@($l.OtherRoots).Count -ne 1) { throw 'the leftover Mods folder should be listed as dead' }
    if ($l.Duplicate) { throw 'one DLL is not a duplicate' }

    'x' | Set-Content -LiteralPath (Join-Path $w 'UE4SS.dll') -NoNewline
    $l2 = Get-UE4SSLayout -Win64 $w
    if (-not $l2.Duplicate) { throw 'two DLLs must read as a duplicate' }
    if (@($l2.ModsRoots)[0] -like '*ue4ss*') { throw 'the root install is the one that loads' }
}

Check 'stale loaders are removed from a dead Mods folder' {
    $w = Join-Path $tmp 'layout'
    Remove-Item -LiteralPath (Join-Path $w 'UE4SS.dll') -Force
    $dead = Join-Path $w 'Mods'
    [void](Write-LoaderStub -ModsRoot $dead -ModHome $home_)
    [void](Set-ModsTxtEntry -ModsRoot $dead)
    if (-not (Remove-LoaderFrom -ModsRoot $dead)) { throw 'stub should have been removed' }
    if (Test-Path -LiteralPath (Join-Path $dead 'SmartNPC')) { throw 'stub still there' }
    $lines = @(Get-Content -LiteralPath (Join-Path $dead 'mods.txt'))
    if ($lines -contains 'SmartNPC : 1') { throw 'mods.txt line still there' }
}

Check 'a UE4SS log older than the loader is reported as stale, not fatal' {
    $w = Join-Path $tmp 'stale'
    New-Item -ItemType Directory -Path (Join-Path $w 'ue4ss\Mods') -Force | Out-Null
    'x' | Set-Content -LiteralPath (Join-Path $w 'ue4ss\UE4SS.dll') -NoNewline
    'Fatal Error: PS scan timed out' | Set-Content -LiteralPath (Join-Path $w 'UE4SS.log')
    (Get-Item -LiteralPath (Join-Path $w 'UE4SS.log')).LastWriteTime = (Get-Date).AddHours(-2)

    $l = Get-UE4SSLayout -Win64 $w
    [void](Write-LoaderStub -ModsRoot (Join-Path $w 'ue4ss\Mods') -ModHome $home_)
    $t = Get-LoaderWriteTime -Layout $l
    $h = Test-UE4SSHealth -Win64 $w -NotBefore $t
    if (-not $h.Stale) { throw 'an old log must not be treated as a current verdict' }
    if ($h.Fatal) { throw 'stale must not also be fatal' }

    $h2 = Test-UE4SSHealth -Win64 $w
    if (-not $h2.Fatal) { throw 'without a cutoff the same log is still a failure' }
}

Check 'a missing proxy DLL is detectable' {
    $w = Join-Path $tmp 'proxy'
    New-Item -ItemType Directory -Path $w -Force | Out-Null
    if (@(Get-UE4SSProxy -Win64 $w).Count -ne 0) { throw 'no proxy expected yet' }
    'x' | Set-Content -LiteralPath (Join-Path $w 'dwmapi.dll') -NoNewline
    if (@(Get-UE4SSProxy -Win64 $w) -notcontains 'dwmapi.dll') { throw 'proxy not found' }
}

Check 'Get-Prop survives objects written by an older version' {
    $old = '{"product":"SmartNPC"}' | ConvertFrom-Json
    if ((Get-Prop $old 'modsTxtExisted' $true) -ne $true) { throw 'default not returned' }
    if ($null -ne (Get-Prop $old 'ue4ssInstalledBy')) { throw 'missing property should be null' }
    if ((Get-Prop $old 'product') -ne 'SmartNPC') { throw 'existing property not returned' }
    if ($null -ne (Get-Prop $null 'anything')) { throw 'null object should be tolerated' }
    $lean = '{"stats":{"squads":3}}' | ConvertFrom-Json
    $st = Get-Prop $lean 'stats'
    if ((Get-Prop $st 'squads' 0) -ne 3) { throw 'present stat not read' }
    if ((Get-Prop $st 'stalls' 0) -ne 0) { throw 'absent stat must fall back' }
    if (@(Get-Prop $lean 'events' @()).Count -ne 0) { throw 'absent list must fall back' }
}

Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue

Write-Host ''
if ($fail -gt 0) {
    Write-Host "$fail test(s) failed" -ForegroundColor Red
    exit 1
}
Write-Host 'all lib tests passed' -ForegroundColor Green
exit 0
