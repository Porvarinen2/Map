<#
  TESLES NPC OVERHAUL - live map server.

  A minimal static HTTP server on the loopback interface. It uses TcpListener
  rather than HttpListener on purpose: HttpListener needs a URL reservation or
  an elevated prompt, and this has to run as a plain double-click.

  Serves:
    /                 the live map page
    /api/state        the director's snapshot, read from the mod's output dir
    everything else   files from this folder
#>
param(
  [int]$Port = 8777,
  [string]$ModOutput = "",
  [switch]$NoBrowser
)

$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $MyInvocation.MyCommand.Path

# Where the mod writes live_state.json. The installer records it in
# livemap_paths.txt; otherwise fall back to the folder layout in the package.
if (-not $ModOutput) {
  $pathFile = Join-Path $root "livemap_paths.txt"
  if (Test-Path $pathFile) {
    $ModOutput = (Get-Content $pathFile -First 1).Trim()
  }
}
if (-not $ModOutput -or -not (Test-Path $ModOutput)) {
  $guess = Join-Path (Split-Path -Parent $root) "mod\TeslesNPCOverhaul\output"
  if (Test-Path $guess) { $ModOutput = $guess }
}

Write-Host ""
Write-Host "  TESLES NPC OVERHAUL - Live Map" -ForegroundColor Yellow
Write-Host "  ------------------------------"
Write-Host "  Sivu      : http://127.0.0.1:$Port/"
if ($ModOutput) {
  Write-Host "  Mod-output: $ModOutput"
} else {
  Write-Host "  Mod-output: EI LOYTYNYT - kartta nayttaa OFFLINE" -ForegroundColor Red
}
Write-Host "  Sulje tama ikkuna kun lopetat."
Write-Host ""

$types = @{
  ".html" = "text/html; charset=utf-8"
  ".css"  = "text/css; charset=utf-8"
  ".js"   = "application/javascript; charset=utf-8"
  ".json" = "application/json; charset=utf-8"
  ".png"  = "image/png"
  ".jpg"  = "image/jpeg"
  ".jpeg" = "image/jpeg"
  ".webp" = "image/webp"
  ".svg"  = "image/svg+xml"
  ".ico"  = "image/x-icon"
  ".txt"  = "text/plain; charset=utf-8"
}

$listener = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Loopback, $Port)
try {
  $listener.Start()
} catch {
  Write-Host "  Portti $Port on varattu. Kokeile: START_LIVEMAP.bat 8899" -ForegroundColor Red
  Read-Host "  Enter sulkee"
  exit 1
}

if (-not $NoBrowser) {
  Start-Process "http://127.0.0.1:$Port/" | Out-Null
}

function Send-Response {
  param($stream, [int]$code, [string]$status, [string]$ctype, [byte[]]$body, [switch]$NoStore)
  $head = "HTTP/1.1 $code $status`r`n"
  $head += "Content-Type: $ctype`r`n"
  $head += "Content-Length: $($body.Length)`r`n"
  if ($NoStore) { $head += "Cache-Control: no-store`r`n" }
  $head += "Connection: close`r`n`r`n"
  $hb = [System.Text.Encoding]::ASCII.GetBytes($head)
  $stream.Write($hb, 0, $hb.Length)
  if ($body.Length -gt 0) { $stream.Write($body, 0, $body.Length) }
  $stream.Flush()
}

while ($true) {
  $client = $null
  try {
    $client = $listener.AcceptTcpClient()
    $client.ReceiveTimeout = 4000
    $client.SendTimeout = 20000
    $stream = $client.GetStream()

    # Read just the request line; this server only answers GET.
    $buf = New-Object byte[] 4096
    $read = $stream.Read($buf, 0, $buf.Length)
    if ($read -le 0) { $client.Close(); continue }
    $text = [System.Text.Encoding]::ASCII.GetString($buf, 0, $read)
    $line = ($text -split "`r`n")[0]
    $parts = $line -split " "
    if ($parts.Count -lt 2 -or $parts[0] -ne "GET") {
      Send-Response $stream 405 "Method Not Allowed" "text/plain" ([byte[]]@()) 
      $client.Close(); continue
    }

    $url = $parts[1]
    $qs = $url.IndexOf("?")
    if ($qs -ge 0) { $url = $url.Substring(0, $qs) }
    $url = [System.Uri]::UnescapeDataString($url)
    if ($url -eq "/") { $url = "/index.html" }

    if ($url -eq "/api/state") {
      $json = $null
      if ($ModOutput) {
        $file = Join-Path $ModOutput "live_state.json"
        if (Test-Path $file) {
          # The mod writes to a temp file and renames, so a partial read is
          # unlikely; a retry still covers the rename window.
          for ($i = 0; $i -lt 3 -and -not $json; $i++) {
            try { $json = [System.IO.File]::ReadAllText($file) } catch { Start-Sleep -Milliseconds 60 }
          }
        }
      }
      if (-not $json) {
        $json = '{"error":"no live_state.json","groups":[],"health":[],"stats":{},"events":[]}'
        Send-Response $stream 503 "Service Unavailable" "application/json; charset=utf-8" `
          ([System.Text.Encoding]::UTF8.GetBytes($json)) -NoStore
      } else {
        Send-Response $stream 200 "OK" "application/json; charset=utf-8" `
          ([System.Text.Encoding]::UTF8.GetBytes($json)) -NoStore
      }
      $client.Close(); continue
    }

    # Static file, restricted to this folder.
    $rel = $url.TrimStart("/").Replace("/", "\")
    $full = [System.IO.Path]::GetFullPath((Join-Path $root $rel))
    if (-not $full.StartsWith($root, [StringComparison]::OrdinalIgnoreCase) -or -not (Test-Path $full -PathType Leaf)) {
      Send-Response $stream 404 "Not Found" "text/plain; charset=utf-8" `
        ([System.Text.Encoding]::UTF8.GetBytes("404"))
      $client.Close(); continue
    }
    $ext = [System.IO.Path]::GetExtension($full).ToLower()
    $ctype = $types[$ext]
    if (-not $ctype) { $ctype = "application/octet-stream" }
    $bytes = [System.IO.File]::ReadAllBytes($full)
    Send-Response $stream 200 "OK" $ctype $bytes
    $client.Close()
  } catch {
    if ($client) { try { $client.Close() } catch {} }
  }
}
