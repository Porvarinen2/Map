# SmartNPC :: lib.ps1
# Shared helpers for INSTALL / REPAIR / UNINSTALL / STATUS.
# Dot-sourced; defines functions only.

<#
    Reads a property that may not exist.  Under Set-StrictMode, touching a
    missing property throws, and both the install manifest and the telemetry
    snapshot are files written by an older version whose shape we cannot assume.
#>
function Get-Prop {
    param($Object, [string]$Name, $Default = $null)
    if ($null -eq $Object) { return $Default }
    try {
        $p = $Object.PSObject.Properties[$Name]
        if ($null -eq $p -or $null -eq $p.Value) { return $Default }
        return $p.Value
    } catch { return $Default }
}

function Find-ScumServer {
    param([string]$Hint = '', [string]$SelfDir = '')

    $candidates = @()
    if ($Hint) { $candidates += $Hint }
    # When a script runs from <server>\SmartNPC, the server is its parent.
    if ($SelfDir) { $candidates += (Split-Path -Parent $SelfDir) }
    $candidates += @(
        'F:\SteamLibrary\steamapps\common\SCUM Server',
        'E:\SteamLibrary\steamapps\common\SCUM Server',
        'D:\SteamLibrary\steamapps\common\SCUM Server',
        'C:\SteamLibrary\steamapps\common\SCUM Server',
        'C:\Program Files (x86)\Steam\steamapps\common\SCUM Server',
        'C:\Program Files\Steam\steamapps\common\SCUM Server'
    )
    foreach ($d in (Get-PSDrive -PSProvider FileSystem -ErrorAction SilentlyContinue)) {
        $candidates += (Join-Path $d.Root 'SteamLibrary\steamapps\common\SCUM Server')
        $candidates += (Join-Path $d.Root 'SCUM Server')
    }
    foreach ($c in ($candidates | Select-Object -Unique)) {
        if (-not $c) { continue }
        try {
            if (Test-Path -LiteralPath (Join-Path $c 'SCUM\Binaries\Win64\SCUMServer.exe') -PathType Leaf) {
                return (Resolve-Path -LiteralPath $c).Path
            }
        } catch {}
    }
    return $null
}

<#
    UE4SS has shipped two layouts:
      2.x :  <Win64>\UE4SS.dll        mods in <Win64>\Mods         list <Win64>\Mods\mods.txt
      3.x :  <Win64>\ue4ss\UE4SS.dll  mods in <Win64>\ue4ss\Mods   list <Win64>\ue4ss\Mods\mods.txt

    Guessing wrong means the loader is written somewhere UE4SS never reads, and
    the mod silently never starts.  So: return every plausible mods root, most
    likely first, and let the caller install into all of them.  A loader stub in
    an unused folder is inert.
#>
function Get-UE4SSLayout {
    param([Parameter(Mandatory = $true)][string]$Win64)

    $modern     = Join-Path $Win64 'ue4ss'
    $modernMods = Join-Path $modern 'Mods'
    $legacyMods = Join-Path $Win64 'Mods'

    $modernDll = (Test-Path -LiteralPath (Join-Path $modern 'UE4SS.dll') -PathType Leaf)
    $legacyDll = (Test-Path -LiteralPath (Join-Path $Win64 'UE4SS.dll') -PathType Leaf)

    # The DLL decides which Mods folder is real.  A leftover Mods folder from a
    # UE4SS that is no longer installed must not receive a loader: that is how a
    # stub ends up somewhere nothing ever reads it.
    $roots = @()
    $other = @()
    if ($legacyDll -and $modernDll) {
        # Two installs. The one at the root is what actually loads.
        $roots += $legacyMods
        $other += $modernMods
    } elseif ($modernDll) {
        $roots += $modernMods
        if (Test-Path -LiteralPath $legacyMods -PathType Container) { $other += $legacyMods }
    } elseif ($legacyDll) {
        $roots += $legacyMods
        if (Test-Path -LiteralPath $modernMods -PathType Container) { $other += $modernMods }
    } else {
        # No UE4SS yet: cover both conventions.
        if (Test-Path -LiteralPath $modernMods -PathType Container) { $roots += $modernMods }
        if (Test-Path -LiteralPath $legacyMods -PathType Container) { $roots += $legacyMods }
        if ($roots.Count -eq 0) { $roots += $legacyMods }
    }

    [pscustomobject]@{
        Win64       = $Win64
        ModsRoots   = @($roots | Select-Object -Unique)
        OtherRoots  = @($other | Select-Object -Unique)
        Dll         = $(if ($legacyDll) { Join-Path $Win64 'UE4SS.dll' }
                        elseif ($modernDll) { Join-Path $modern 'UE4SS.dll' }
                        else { $null })
        HasUE4SS    = ($legacyDll -or $modernDll)
        Duplicate   = ($legacyDll -and $modernDll)
    }
}

# UE4SS is loaded by a proxy DLL sitting next to the game executable.  Removing
# a wrongly installed UE4SS can take that proxy with it, and then nothing loads
# at all - with no error anywhere, because UE4SS never runs.
function Get-UE4SSProxy {
    param([Parameter(Mandatory = $true)][string]$Win64)
    $names = @('dwmapi.dll','xinput1_3.dll','d3d11.dll','dinput8.dll','winmm.dll','version.dll','bink2w64.dll')
    $found = @()
    foreach ($n in $names) {
        if (Test-Path -LiteralPath (Join-Path $Win64 $n) -PathType Leaf) { $found += $n }
    }
    return $found
}

# UE4SS writes its log next to the DLL in 2.x and inside ue4ss\ in 3.x.
function Get-UE4SSLogPath {
    param([Parameter(Mandatory = $true)][string]$Win64)
    foreach ($p in @(
        (Join-Path $Win64 'UE4SS.log'),
        (Join-Path $Win64 'ue4ss\UE4SS.log'),
        (Join-Path $Win64 'ue4ss\UE4SS-log.txt'),
        (Join-Path $Win64 'UE4SS-log.txt')
    )) {
        if (Test-Path -LiteralPath $p -PathType Leaf) { return $p }
    }
    return $null
}

function Write-LoaderStub {
    param(
        [Parameter(Mandatory = $true)][string]$ModsRoot,
        [Parameter(Mandatory = $true)][string]$ModHome
    )
    $stub = Join-Path $ModsRoot 'SmartNPC'
    New-Item -ItemType Directory -Path (Join-Path $stub 'Scripts') -Force | Out-Null

    $lua = @"
-- SmartNPC loader stub.
-- Generated by the SmartNPC installer - do not edit.
-- All SmartNPC code, data, config, state and logs live in the folder below.
SMARTNPC_ROOT = [[$ModHome]]
local ok, err = pcall(dofile, SMARTNPC_ROOT .. "\\lua\\boot.lua")
if not ok then
    print("[SmartNPC] boot failed: " .. tostring(err) .. "\n")
end
"@
    $enc = New-Object Text.UTF8Encoding($false)
    [IO.File]::WriteAllText((Join-Path $stub 'Scripts\main.lua'), $lua, $enc)
    return $stub
}

<#
    mods.txt is the documented way to enable a mod and it carries the load
    order.  enabled.txt is only a fallback: on some builds its presence makes
    UE4SS ignore mods.txt entirely, so it is written only when the mods.txt
    entry could not be verified, and removed again once mods.txt works.
#>
function Set-EnabledTxt {
    param(
        [Parameter(Mandatory = $true)][string]$ModsRoot,
        [Parameter(Mandatory = $true)][bool]$Wanted
    )
    $path = Join-Path $ModsRoot 'SmartNPC\enabled.txt'
    if ($Wanted) {
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
            [IO.File]::WriteAllText($path, '', (New-Object Text.UTF8Encoding($false)))
        }
    } elseif (Test-Path -LiteralPath $path -PathType Leaf) {
        Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
    }
}

function Set-ModsTxtEntry {
    param(
        [Parameter(Mandatory = $true)][string]$ModsRoot,
        [switch]$Remove
    )
    $path = Join-Path $ModsRoot 'mods.txt'
    $existed = Test-Path -LiteralPath $path -PathType Leaf
    $lines = @()
    if ($existed) {
        $lines = @(Get-Content -LiteralPath $path -Encoding UTF8 -ErrorAction SilentlyContinue)
    }
    $lines = @($lines | Where-Object { $_ -notmatch '^\s*SmartNPC\s*:' })
    if (-not $Remove) { $lines += 'SmartNPC : 1' }

    if ($Remove -and -not $existed) { return [pscustomobject]@{ Path = $path; Existed = $false; Ok = $true } }

    New-Item -ItemType Directory -Path $ModsRoot -Force | Out-Null
    [IO.File]::WriteAllLines($path, [string[]]$lines, (New-Object Text.UTF8Encoding($false)))

    # Read back: a silently failed write here is the difference between a mod
    # that runs and a mod that never starts.
    $ok = $true
    if (-not $Remove) {
        $ok = [bool](Get-Content -LiteralPath $path -Encoding UTF8 -ErrorAction SilentlyContinue |
                     Where-Object { $_ -match '^\s*SmartNPC\s*:\s*1\s*$' })
    }
    [pscustomobject]@{ Path = $path; Existed = $existed; Ok = $ok }
}

function Test-SmartNPCLoader {
    param(
        [Parameter(Mandatory = $true)][string]$ModsRoot,
        [Parameter(Mandatory = $true)][string]$ModHome
    )
    $stub = Join-Path $ModsRoot 'SmartNPC\Scripts\main.lua'
    $stubOk = Test-Path -LiteralPath $stub -PathType Leaf
    $pointsHere = $false
    if ($stubOk) {
        $txt = Get-Content -LiteralPath $stub -Raw -Encoding UTF8 -ErrorAction SilentlyContinue
        $pointsHere = $txt -and $txt.Contains($ModHome)
    }
    $modsTxt = Join-Path $ModsRoot 'mods.txt'
    $listed = $false
    if (Test-Path -LiteralPath $modsTxt -PathType Leaf) {
        $listed = [bool](Get-Content -LiteralPath $modsTxt -Encoding UTF8 -ErrorAction SilentlyContinue |
                         Where-Object { $_ -match '^\s*SmartNPC\s*:\s*1\s*$' })
    }
    [pscustomobject]@{
        ModsRoot   = $ModsRoot
        Stub       = $stub
        StubOk     = $stubOk
        PointsHere = $pointsHere
        Enabled    = (Test-Path -LiteralPath (Join-Path $ModsRoot 'SmartNPC\enabled.txt') -PathType Leaf)
        Listed     = $listed
        ModsTxt    = $modsTxt
    }
}

<#
    A running SmartNPC map server keeps a PowerShell process alive whose working
    directory is the mod folder, which locks the folder against deletion.  Find
    those processes by command line so the installer can close them instead of
    failing with "used by another process".
#>
function Get-MapServerProcess {
    param([string]$ModHome = '')
    $out = @()
    try {
        $procs = Get-CimInstance Win32_Process -ErrorAction Stop |
                 Where-Object { $_.Name -in @('powershell.exe','pwsh.exe') -and $_.CommandLine }
        foreach ($p in $procs) {
            if ($p.CommandLine -match 'START_MAP\.ps1') {
                if (-not $ModHome -or $p.CommandLine -like ("*" + $ModHome + "*")) { $out += $p }
            }
        }
    } catch {}
    return $out
}

function Stop-MapServer {
    param([string]$ModHome = '')
    $procs = @(Get-MapServerProcess -ModHome $ModHome)
    $stopped = 0
    foreach ($p in $procs) {
        try { Stop-Process -Id $p.ProcessId -Force -ErrorAction Stop; $stopped++ } catch {}
    }
    if ($stopped -gt 0) { Start-Sleep -Milliseconds 700 }
    return $stopped
}

<#
    Update the mod in place instead of deleting and re-creating the folder.

    Deleting the folder fails whenever anything holds a handle on it - an open
    Explorer window, a map server, a text editor - and the old installer then
    aborted having already made a backup.  Copying file by file only needs the
    individual files to be writable, and never touches state, output, logs or
    tools.
#>
function Sync-ModFiles {
    param(
        [Parameter(Mandatory = $true)][string]$Source,
        [Parameter(Mandatory = $true)][string]$Dest,
        [string[]]$CodeDirs = @('lua','data','web'),
        # The user's folders. Nothing in them is ever read from the package or
        # written over, even if a package accidentally ships something there.
        [string[]]$UserDirs = @('state','output','logs','tools')
    )
    $failed = @()
    $copied = 0

    New-Item -ItemType Directory -Path $Dest -Force | Out-Null
    foreach ($d in $UserDirs) {
        New-Item -ItemType Directory -Path (Join-Path $Dest $d) -Force | Out-Null
    }

    $srcRoot = (Resolve-Path -LiteralPath $Source).Path.TrimEnd('\','/')
    $files = Get-ChildItem -LiteralPath $Source -Recurse -File -Force
    $wanted = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)

    foreach ($f in $files) {
        $rel = $f.FullName.Substring($srcRoot.Length).TrimStart('\','/')
        $top = ($rel -split '[\\/]')[0]
        if ($UserDirs -contains $top) { continue }
        [void]$wanted.Add($rel)
        $target = Join-Path $Dest $rel
        $targetDir = Split-Path -Parent $target
        if (-not (Test-Path -LiteralPath $targetDir)) {
            New-Item -ItemType Directory -Path $targetDir -Force | Out-Null
        }
        try {
            # A stale directory sitting where a file belongs would silently turn
            # into a copy *inside* it, leaving a broken install that reports
            # success. Clear it first.
            if (Test-Path -LiteralPath $target -PathType Container) {
                Remove-Item -LiteralPath $target -Recurse -Force -ErrorAction Stop
            }
            Copy-Item -LiteralPath $f.FullName -Destination $target -Force -ErrorAction Stop
            if (-not (Test-Path -LiteralPath $target -PathType Leaf)) { throw 'file not present after copy' }
            $copied++
        } catch {
            $failed += $rel
        }
    }

    # Remove code files this version no longer ships, so an upgrade cannot leave
    # a stale module behind.  Only inside the code folders: state, output, logs
    # and tools are the user's and are never enumerated here.
    foreach ($dir in $CodeDirs) {
        $d = Join-Path $Dest $dir
        if (-not (Test-Path -LiteralPath $d -PathType Container)) { continue }
        $dRootLen = ((Resolve-Path -LiteralPath $Dest).Path.TrimEnd('\','/')).Length
        foreach ($existing in (Get-ChildItem -LiteralPath $d -Recurse -File -Force)) {
            $rel = $existing.FullName.Substring($dRootLen).TrimStart('\','/')
            if (-not $wanted.Contains($rel)) {
                Remove-Item -LiteralPath $existing.FullName -Force -ErrorAction SilentlyContinue
            }
        }
    }

    [pscustomobject]@{ Copied = $copied; Failed = @($failed) }
}

<#
    SmartNPC 1.0.0 and 1.0.1 could download UE4SS when they did not find
    Win64\UE4SS.dll.  On a SCUM server whose UE4SS lives in Win64\ue4ss\ that
    check was wrong: the download landed a second, generic UE4SS (including its
    dwmapi.dll proxy) at Win64 root, where it takes over loading and then dies
    on SCUM's build - after which no Lua mod loads at all.

    This undoes exactly that, and only that: a file is removed only when it is
    byte-for-byte the copy SmartNPC extracted, so anything the user has since
    replaced or edited is left alone.
#>
function Get-DownloadedUE4SSFiles {
    param(
        [Parameter(Mandatory = $true)][string]$ModHome,
        [Parameter(Mandatory = $true)][string]$Win64
    )
    $extracted = Join-Path $ModHome 'tools\ue4ss\extracted'
    if (-not (Test-Path -LiteralPath $extracted -PathType Container)) { return @() }

    $root = (Resolve-Path -LiteralPath $extracted).Path.TrimEnd('\','/')
    $out = @()
    foreach ($f in (Get-ChildItem -LiteralPath $extracted -Recurse -File -Force)) {
        $rel = $f.FullName.Substring($root.Length).TrimStart('\','/')
        $target = Join-Path $Win64 $rel
        if (-not (Test-Path -LiteralPath $target -PathType Leaf)) { continue }
        $same = $false
        try {
            $a = Get-FileHash -LiteralPath $f.FullName -Algorithm SHA256
            $b = Get-FileHash -LiteralPath $target -Algorithm SHA256
            $same = ($a.Hash -eq $b.Hash)
        } catch {}
        $out += [pscustomobject]@{ Relative = $rel; Path = $target; Unchanged = $same }
    }
    return $out
}

function Remove-DownloadedUE4SS {
    param(
        [Parameter(Mandatory = $true)][string]$ModHome,
        [Parameter(Mandatory = $true)][string]$Win64
    )
    $files = @(Get-DownloadedUE4SSFiles -ModHome $ModHome -Win64 $Win64)
    $removed = 0; $kept = @()
    foreach ($f in $files) {
        if ($f.Unchanged) {
            try { Remove-Item -LiteralPath $f.Path -Force -ErrorAction Stop; $removed++ } catch { $kept += $f.Relative }
        } else {
            $kept += $f.Relative
        }
    }
    # prune directories the download created and that are now empty
    for ($pass = 0; $pass -lt 4; $pass++) {
        foreach ($d in (Get-ChildItem -LiteralPath $Win64 -Recurse -Directory -Force -ErrorAction SilentlyContinue |
                        Sort-Object { $_.FullName.Length } -Descending)) {
            if (-not (Get-ChildItem -LiteralPath $d.FullName -Force -ErrorAction SilentlyContinue)) {
                Remove-Item -LiteralPath $d.FullName -Force -ErrorAction SilentlyContinue
            }
        }
    }
    [pscustomobject]@{ Removed = $removed; Kept = @($kept); Total = $files.Count }
}

# Read UE4SS's own log and decide whether UE4SS itself is healthy.  When its
# pattern scan fails, no Lua mod loads and nothing about SmartNPC matters.
function Test-UE4SSHealth {
    param(
        [Parameter(Mandatory = $true)][string]$Win64,
        # Anything logged before this moment predates the current setup and says
        # nothing about it.  Callers pass the time they last wrote the loader.
        [datetime]$NotBefore = [datetime]::MinValue
    )
    $log = Get-UE4SSLogPath -Win64 $Win64
    if (-not $log) {
        return [pscustomobject]@{ Log = $null; Fatal = $false; Stale = $false; Reason = 'no UE4SS log yet'; Version = $null }
    }
    $written = [datetime]::MinValue
    try { $written = (Get-Item -LiteralPath $log).LastWriteTime } catch {}
    if ($written -lt $NotBefore) {
        return [pscustomobject]@{
            Log = $log; Fatal = $false; Stale = $true
            Reason = 'the UE4SS log is from before the last change - restart the server for a fresh verdict'
            Version = $null
        }
    }
    $text = ''
    try { $text = Get-Content -LiteralPath $log -Raw -Encoding UTF8 -ErrorAction Stop } catch {}
    $version = $null
    if ($text -match 'UE4SS\s*-\s*(v[\d\.]+[^\r\n#]*)') { $version = $Matches[1].Trim() }
    $fatal = $false; $reason = 'looks healthy'
    if ($text -match 'PS scan timed out') { $fatal = $true; $reason = 'UE4SS pattern scan timed out - UE4SS never started, so no mod loaded' }
    elseif ($text -match 'Scan failed') { $fatal = $true; $reason = 'UE4SS pattern scan failed - UE4SS cannot attach to this game build' }
    elseif ($text -match 'Fatal Error') { $fatal = $true; $reason = 'UE4SS reported a fatal error' }
    [pscustomobject]@{ Log = $log; Fatal = $fatal; Stale = $false; Reason = $reason; Version = $version }
}

<#
    Two UE4SS installs in one game folder.

    The build made for SCUM lives in Win64\ue4ss\.  A generic UE4SS unpacked at
    Win64 root brings its own proxy DLL, which wins, and then fails SCUM's
    pattern scan - taking every mod on the server down with it.

    Earlier SmartNPC versions deleted the whole mod folder on upgrade, so the
    record of what they extracted is usually gone.  This rebuilds that record by
    fetching the same UE4SS release and comparing hashes, so removal stays
    exact: a file is deleted only when it is byte-for-byte the stock release.
#>
function Get-StrayRootUE4SS {
    param(
        [Parameter(Mandatory = $true)][string]$Win64,
        [string]$ModHome = '',
        [string]$Version = ''
    )
    $rootDll = Join-Path $Win64 'UE4SS.dll'
    $nestedDll = Join-Path $Win64 'ue4ss\UE4SS.dll'
    $result = [pscustomobject]@{
        Duplicate = $false
        Reference = $null
        Files     = @()
        Note      = ''
    }
    if (-not (Test-Path -LiteralPath $rootDll -PathType Leaf)) { $result.Note = 'no UE4SS at Win64 root'; return $result }
    if (-not (Test-Path -LiteralPath $nestedDll -PathType Leaf)) { $result.Note = 'only one UE4SS present'; return $result }
    $result.Duplicate = $true

    # reference copy: what SmartNPC extracted, or the same release re-fetched
    $reference = $null
    if ($ModHome) {
        $p = Join-Path $ModHome 'tools\ue4ss\extracted'
        if (Test-Path -LiteralPath $p -PathType Container) { $reference = $p }
    }
    if (-not $reference -and $ModHome) {
        $reference = Get-UE4SSReference -ModHome $ModHome -Version $Version
    }
    if (-not $reference) { $result.Note = 'no reference copy available'; return $result }
    $result.Reference = $reference

    $refRoot = (Resolve-Path -LiteralPath $reference).Path.TrimEnd('\','/')
    $files = @()
    foreach ($f in (Get-ChildItem -LiteralPath $reference -Recurse -File -Force)) {
        $rel = $f.FullName.Substring($refRoot.Length).TrimStart('\','/')
        $target = Join-Path $Win64 $rel
        if (-not (Test-Path -LiteralPath $target -PathType Leaf)) { continue }
        $same = $false
        try {
            $same = ((Get-FileHash -LiteralPath $f.FullName -Algorithm SHA256).Hash -eq
                     (Get-FileHash -LiteralPath $target   -Algorithm SHA256).Hash)
        } catch {}
        $files += [pscustomobject]@{ Relative = $rel; Path = $target; Unchanged = $same }
    }
    $result.Files = $files
    return $result
}

# Download the stock UE4SS release matching $Version (or the latest) and return
# the extracted folder, so removal can be hash-exact.
function Get-UE4SSReference {
    param(
        [Parameter(Mandatory = $true)][string]$ModHome,
        [string]$Version = ''
    )
    $dir = Join-Path $ModHome 'tools\ue4ss\reference'
    $marker = Join-Path $dir '.version'
    if ((Test-Path -LiteralPath $dir -PathType Container) -and (Test-Path -LiteralPath $marker -PathType Leaf)) {
        $have = (Get-Content -LiteralPath $marker -Raw -ErrorAction SilentlyContinue).Trim()
        if (-not $Version -or $have -eq $Version) { return $dir }
    }
    try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch {}

    $urls = @()
    if ($Version) {
        $v = $Version -replace '^v', '' -replace '\s.*$', ''
        $urls += "https://github.com/UE4SS-RE/RE-UE4SS/releases/download/v$v/UE4SS_v$v.zip"
    }
    $urls += 'https://github.com/UE4SS-RE/RE-UE4SS/releases/latest/download/UE4SS_v3.0.1.zip'

    New-Item -ItemType Directory -Path (Split-Path -Parent $dir) -Force | Out-Null
    $zip = Join-Path (Split-Path -Parent $dir) 'reference.zip'
    foreach ($u in $urls) {
        try {
            Invoke-WebRequest -Uri $u -OutFile $zip -UseBasicParsing -TimeoutSec 180 -ErrorAction Stop
            Add-Type -AssemblyName System.IO.Compression.FileSystem
            if (Test-Path -LiteralPath $dir) { Remove-Item -LiteralPath $dir -Recurse -Force }
            [IO.Compression.ZipFile]::ExtractToDirectory($zip, $dir)
            Set-Content -LiteralPath $marker -Value $Version -Encoding UTF8
            Remove-Item -LiteralPath $zip -Force -ErrorAction SilentlyContinue
            return $dir
        } catch { }
    }
    return $null
}

# Newest loader stub write time, used to tell a stale UE4SS verdict from a real one.
function Get-LoaderWriteTime {
    param([Parameter(Mandatory = $true)]$Layout)
    $newest = [datetime]::MinValue
    foreach ($r in @($Layout.ModsRoots) + @($Layout.OtherRoots)) {
        $p = Join-Path $r 'SmartNPC\Scripts\main.lua'
        if (Test-Path -LiteralPath $p -PathType Leaf) {
            try {
                $t = (Get-Item -LiteralPath $p).LastWriteTime
                if ($t -gt $newest) { $newest = $t }
            } catch {}
        }
    }
    return $newest
}

# Remove the SmartNPC loader from a Mods folder that no UE4SS reads any more.
function Remove-LoaderFrom {
    param([Parameter(Mandatory = $true)][string]$ModsRoot)
    $stub = Join-Path $ModsRoot 'SmartNPC'
    $removed = $false
    if (Test-Path -LiteralPath $stub -PathType Container) {
        Remove-Item -LiteralPath $stub -Recurse -Force -ErrorAction SilentlyContinue
        $removed = $true
    }
    if (Test-Path -LiteralPath (Join-Path $ModsRoot 'mods.txt') -PathType Leaf) {
        [void](Set-ModsTxtEntry -ModsRoot $ModsRoot -Remove)
    }
    return $removed
}

<#
    Some UE4SS packages keep a spare copy of the proxy DLL inside their own
    folder.  When the proxy next to the game executable is missing, that copy is
    the user's own file and is the safest thing to put back - far safer than
    downloading a proxy from a release that may not match their UE4SS.
#>
function Find-SpareProxy {
    param([Parameter(Mandatory = $true)][string]$Win64)
    $names = @('dwmapi.dll','xinput1_3.dll','d3d11.dll','dinput8.dll','winmm.dll','version.dll','bink2w64.dll')
    $out = @()
    foreach ($dir in @((Join-Path $Win64 'ue4ss'), (Join-Path $Win64 'ue4ss\proxy'), (Join-Path $Win64 'ue4ss\bin'))) {
        if (-not (Test-Path -LiteralPath $dir -PathType Container)) { continue }
        foreach ($n in $names) {
            $p = Join-Path $dir $n
            if (Test-Path -LiteralPath $p -PathType Leaf) {
                $out += [pscustomobject]@{ Name = $n; Source = $p; Target = (Join-Path $Win64 $n) }
            }
        }
    }
    return $out
}
