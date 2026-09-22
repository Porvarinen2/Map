<#
  TESLES NPC OVERHAUL - live map server.

  A minimal static HTTP server on the loopback interface. It uses TcpListener
  rather than HttpListener on purpose: HttpListener needs a URL reservation or
  an elevated prompt, and this has to run as a plain double-click.

  Serves:
    /                 the live map page
    /api/state        the director's snapshot, read from the mod's output dir
    /api/status       what the server can see, for troubleshooting
    everything else   files from this folder
#>
param(
  [int]$Port = 8777,
  [string]$ModOutput = "",
  [switch]$NoBrowser,
  [switch]$Verbose
)

$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $MyInvocation.MyCommand.Path

function Say($t, $c = "Gray") { Write-Host "  $t" -ForegroundColor $c }

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
Say "Sivu      : http://127.0.0.1:$Port/"
if ($ModOutput) {
  Say "Mod-output: $ModOutput" "Green"
  $stateFile = Join-Path $ModOutput "live_state.json"
  if (Test-Path $stateFile) {
    Say "live_state.json loytyy." "Green"
  } else {
    Say "live_state.json puuttuu viela - kartta nayttaa OFFLINE kunnes" "Yellow"
    Say "palvelin on kaynnistynyt ja director on kirjoittanut tilan." "Yellow"
  }
} else {
  Say "Mod-output: EI LOYTYNYT - aja INSTALL.bat ensin." "Red"
}
$baseMap = Join-Path $root "map\scum_map.png"
if (-not (Test-Path $baseMap)) {
  Say "map\scum_map.png puuttuu - kartta nakyy tyhjana ruudukkona." "Yellow"
  Say "Aja SETUP_HIRES_MAP.bat, se luo peruskartan uudestaan." "Yellow"
}
Say "Sulje tama ikkuna kun lopetat."
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

function Send-Response {
  param($Stream, [int]$Code, [string]$Status, [string]$CType, [byte[]]$Body, [bool]$NoStore = $false)
  if ($null -eq $Body) { $Body = New-Object byte[] 0 }
  $head = "HTTP/1.1 $Code $Status`r`n"
  $head += "Content-Type: $CType`r`n"
  $head += "Content-Length: $($Body.Length)`r`n"
  if ($NoStore) { $head += "Cache-Control: no-store`r`n" }
  $head += "Connection: close`r`n`r`n"
  $hb = [System.Text.Encoding]::ASCII.GetBytes($head)
  $Stream.Write($hb, 0, $hb.Length)
  if ($Body.Length -gt 0) { $Stream.Write($Body, 0, $Body.Length) }
  $Stream.Flush()
}

function Send-Json {
  param($Stream, [int]$Code, [string]$Status, [string]$Json)
  $body = [System.Text.Encoding]::UTF8.GetBytes($Json)
  Send-Response -Stream $Stream -Code $Code -Status $Status -CType "application/json; charset=utf-8" -Body $body -NoStore $true
}

function Send-Text {
  param($Stream, [int]$Code, [string]$Status, [string]$Text)
  $body = [System.Text.Encoding]::UTF8.GetBytes($Text)
  Send-Response -Stream $Stream -Code $Code -Status $Status -CType "text/plain; charset=utf-8" -Body $body
}

$listener = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Loopback, $Port)
try {
  $listener.Start()
} catch {
  Say "Portti $Port on varattu tai estetty: $($_.Exception.Message)" "Red"
  Say "Kokeile toista porttia: START_LIVEMAP.bat 8899" "Yellow"
  Read-Host "  Enter sulkee"
  exit 1
}

if (-not $NoBrowser) {
  try { Start-Process "http://127.0.0.1:$Port/" | Out-Null } catch {}
}

$served = 0
while ($true) {
  $client = $null
  try {
    $client = $listener.AcceptTcpClient()
    $client.ReceiveTimeout = 5000
    $client.SendTimeout = 30000
    $stream = $client.GetStream()

    # Read just the request line; this server only answers GET.
    $buf = New-Object byte[] 8192
    $read = $stream.Read($buf, 0, $buf.Length)
    if ($read -le 0) { $client.Close(); continue }
    $text = [System.Text.Encoding]::ASCII.GetString($buf, 0, $read)
    $line = ($text -split "`r`n")[0]
    $parts = $line -split " "
    if ($parts.Count -lt 2 -or $parts[0] -ne "GET") {
      Send-Text -Stream $stream -Code 405 -Status "Method Not Allowed" -Text "only GET"
      $client.Close(); continue
    }

    $url = $parts[1]
    $qs = $url.IndexOf("?")
    if ($qs -ge 0) { $url = $url.Substring(0, $qs) }
    try { $url = [System.Uri]::UnescapeDataString($url) } catch {}
    if ($url -eq "/") { $url = "/index.html" }
    if ($Verbose) { Say "GET $url" "DarkGray" }

    if ($url -eq "/api/state") {
      $json = $null
      $why = "no mod output folder configured"
      if ($ModOutput) {
        $file = Join-Path $ModOutput "live_state.json"
        if (Test-Path $file) {
          # The mod writes to a temp file and renames, so a partial read is
          # unlikely; a retry still covers the rename window.
          for ($i = 0; $i -lt 3 -and -not $json; $i++) {
            try { $json = [System.IO.File]::ReadAllText($file) }
            catch { Start-Sleep -Milliseconds 80 }
          }
          if (-not $json) { $why = "live_state.json could not be read" }
        } else {
          $why = "live_state.json does not exist yet"
        }
      }
      if ($json) {
        Send-Json -Stream $stream -Code 200 -Status "OK" -Json $json
      } else {
        # Answer 200 with an explanation: a transport error in the browser is
        # much harder to read than a message on the page.
        # Build it as an object so the path's backslashes are escaped for us.
        $payload = @{
          waiting = $true
          reason = $why
          output = [string]$ModOutput
          groups = @()
          health = @()
          stats = @{}
          events = @()
        } | ConvertTo-Json -Compress -Depth 3
        Send-Json -Stream $stream -Code 200 -Status "OK" -Json $payload
      }
      $served++
      $client.Close(); continue
    }

    if ($url -eq "/api/status") {
      $files = @()
      $mapDir = Join-Path $root "map"
      if (Test-Path $mapDir) {
        $files = Get-ChildItem $mapDir -File | ForEach-Object { $_.Name }
      }
      $payload = @{
        output = $ModOutput
        outputExists = [bool]($ModOutput -and (Test-Path $ModOutput))
        stateExists = [bool]($ModOutput -and (Test-Path (Join-Path $ModOutput "live_state.json")))
        mapFiles = $files
        served = $served
      } | ConvertTo-Json -Compress
      Send-Json -Stream $stream -Code 200 -Status "OK" -Json $payload
      $client.Close(); continue
    }

    # Static file, restricted to this folder.
    $rel = $url.TrimStart("/").Replace("/", "\")
    $full = $null
    try { $full = [System.IO.Path]::GetFullPath((Join-Path $root $rel)) } catch {}
    $inside = $full -and $full.StartsWith($root, [StringComparison]::OrdinalIgnoreCase)
    if (-not $inside -or -not (Test-Path $full -PathType Leaf)) {
      Send-Text -Stream $stream -Code 404 -Status "Not Found" -Text "404 $url"
      $client.Close(); continue
    }
    $ext = [System.IO.Path]::GetExtension($full).ToLower()
    $ctype = $types[$ext]
    if (-not $ctype) { $ctype = "application/octet-stream" }
    $bytes = [System.IO.File]::ReadAllBytes($full)
    Send-Response -Stream $stream -Code 200 -Status "OK" -CType $ctype -Body $bytes
    $served++
    $client.Close()
  } catch {
    # One bad request must never take the server down.
    if ($Verbose) { Say "pyynto epaonnistui: $($_.Exception.Message)" "DarkYellow" }
    if ($client) { try { $client.Close() } catch {} }
  }
}
