#requires -Version 5.1
<#
    SmartNPC live map server.

    Serves the web UI in SmartNPC\web and the telemetry snapshot the mod writes
    to SmartNPC\output\world.json.  Pure PowerShell: no runtime is downloaded
    and nothing is installed outside this folder.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false) } catch {}

$Root      = Split-Path -Parent $MyInvocation.MyCommand.Path
# Never keep the mod folder as the working directory: that alone is enough to
# make Windows refuse to replace it during an update.
try { Set-Location -LiteralPath ([IO.Path]::GetTempPath()) } catch {}
$WebRoot   = Join-Path $Root 'web'
$OutputDir = Join-Path $Root 'output'
$LogFile   = Join-Path $Root 'logs\map_server.log'

if (-not (Test-Path -LiteralPath $WebRoot -PathType Container)) {
    throw "SmartNPC web folder missing: $WebRoot"
}
foreach ($d in @($OutputDir, (Split-Path -Parent $LogFile))) {
    if (-not (Test-Path -LiteralPath $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
}

function Write-Log([string]$msg) {
    $line = "[{0}] {1}" -f (Get-Date -Format 'HH:mm:ss'), $msg
    Write-Host $line
    try { Add-Content -LiteralPath $LogFile -Value $line -Encoding UTF8 } catch {}
}

$MIME = @{
    '.html' = 'text/html; charset=utf-8'
    '.htm'  = 'text/html; charset=utf-8'
    '.js'   = 'application/javascript; charset=utf-8'
    '.css'  = 'text/css; charset=utf-8'
    '.json' = 'application/json; charset=utf-8'
    '.png'  = 'image/png'
    '.jpg'  = 'image/jpeg'
    '.jpeg' = 'image/jpeg'
    '.webp' = 'image/webp'
    '.svg'  = 'image/svg+xml'
    '.ico'  = 'image/x-icon'
    '.woff2'= 'font/woff2'
    '.txt'  = 'text/plain; charset=utf-8'
}

function Send-Bytes($ctx, [byte[]]$bytes, [string]$type, [int]$status = 200) {
    try {
        $ctx.Response.StatusCode = $status
        $ctx.Response.ContentType = $type
        $ctx.Response.Headers['Cache-Control'] = 'no-store, no-cache, must-revalidate'
        $ctx.Response.ContentLength64 = $bytes.Length
        $ctx.Response.OutputStream.Write($bytes, 0, $bytes.Length)
    } catch {
    } finally {
        try { $ctx.Response.OutputStream.Close() } catch {}
    }
}

function Send-Text($ctx, [string]$text, [string]$type = 'text/plain; charset=utf-8', [int]$status = 200) {
    Send-Bytes $ctx ([Text.Encoding]::UTF8.GetBytes($text)) $type $status
}

# Reads a file that another process rewrites constantly.  FileShare.ReadWrite
# keeps us from ever blocking the mod's own write.
function Read-Shared([string]$path) {
    for ($i = 0; $i -lt 4; $i++) {
        try {
            $fs = [IO.File]::Open($path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
            try {
                $ms = New-Object IO.MemoryStream
                $fs.CopyTo($ms)
                return $ms.ToArray()
            } finally { $fs.Dispose() }
        } catch {
            Start-Sleep -Milliseconds 25
        }
    }
    return $null
}

# -------------------------------------------------------------------- listener
$listener = New-Object Net.HttpListener
$port = 0
$prefix = $null
foreach ($p in 8770..8790) {
    foreach ($host_ in @('localhost', '127.0.0.1')) {
        $try = "http://$host_`:$p/"
        try {
            $listener.Prefixes.Clear()
            $listener.Prefixes.Add($try)
            $listener.Start()
            $port = $p
            $prefix = $try
            break
        } catch {
            try { $listener.Close() } catch {}
            $listener = New-Object Net.HttpListener
        }
    }
    if ($prefix) { break }
}

if (-not $prefix) {
    Write-Host ''
    Write-Host 'SmartNPC map: no free port between 8770 and 8790, or Windows refused the' -ForegroundColor Red
    Write-Host 'HTTP reservation. Try running this window as Administrator once.' -ForegroundColor Red
    Read-Host 'Press Enter to close'
    exit 1
}

$url = "http://localhost:$port/"
Write-Log "SmartNPC map server listening on $prefix"
Write-Log "telemetry: $OutputDir\world.json"
Write-Host ''
Write-Host "   Open:  $url" -ForegroundColor Green
Write-Host '   Leave this window open. Ctrl+C stops the map (the mod keeps running).'
Write-Host ''

try { Start-Process $url | Out-Null } catch { Write-Log "could not open a browser automatically: $($_.Exception.Message)" }

$deadline = $null
try {
    while ($listener.IsListening) {
        $ctx = $listener.GetContext()
        $path = $ctx.Request.Url.AbsolutePath
        if ($path -eq '/') { $path = '/index.html' }

        try {
            if ($path -eq '/api/world') {
                $wf = Join-Path $OutputDir 'world.json'
                if (Test-Path -LiteralPath $wf -PathType Leaf) {
                    $bytes = Read-Shared $wf
                    if ($bytes) {
                        Send-Bytes $ctx $bytes 'application/json; charset=utf-8'
                    } else {
                        Send-Text $ctx '{"ok":false,"error":"snapshot busy"}' 'application/json; charset=utf-8' 503
                    }
                } else {
                    Send-Text $ctx '{"ok":false,"error":"no snapshot yet - is the server running with SmartNPC installed?"}' 'application/json; charset=utf-8' 503
                }
                continue
            }

            if ($path -eq '/api/ping') {
                Send-Text $ctx (@{ ok = $true; time = (Get-Date -Format 'o') } | ConvertTo-Json -Compress) 'application/json; charset=utf-8'
                continue
            }

            if ($path -eq '/api/log') {
                $lf = Join-Path $Root 'logs\smartnpc.log'
                if (Test-Path -LiteralPath $lf -PathType Leaf) {
                    $tail = (Get-Content -LiteralPath $lf -Tail 200 -Encoding UTF8) -join "`n"
                    Send-Text $ctx $tail
                } else {
                    Send-Text $ctx 'no log yet'
                }
                continue
            }

            # static files, confined to the web folder
            $rel = $path.TrimStart('/') -replace '/', '\'
            $full = Join-Path $WebRoot $rel
            $resolvedRoot = [IO.Path]::GetFullPath($WebRoot)
            $resolved = $null
            try { $resolved = [IO.Path]::GetFullPath($full) } catch {}
            if (-not $resolved -or -not $resolved.StartsWith($resolvedRoot, [StringComparison]::OrdinalIgnoreCase)) {
                Send-Text $ctx 'Forbidden' 'text/plain; charset=utf-8' 403
                continue
            }
            if (Test-Path -LiteralPath $resolved -PathType Leaf) {
                $ext = [IO.Path]::GetExtension($resolved).ToLowerInvariant()
                $type = $MIME[$ext]
                if (-not $type) { $type = 'application/octet-stream' }
                Send-Bytes $ctx ([IO.File]::ReadAllBytes($resolved)) $type
            } else {
                Send-Text $ctx 'Not found' 'text/plain; charset=utf-8' 404
            }
        } catch {
            Write-Log "request error on $path : $($_.Exception.Message)"
            try { Send-Text $ctx 'Server error' 'text/plain; charset=utf-8' 500 } catch {}
        }
    }
} finally {
    try { $listener.Stop(); $listener.Close() } catch {}
    Write-Log 'map server stopped'
}
