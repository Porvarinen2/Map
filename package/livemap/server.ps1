<#
  TESLES NPC OVERHAUL - live map server.

  A minimal static HTTP server on the loopback interface. It uses TcpListener
  rather than HttpListener on purpose: HttpListener needs a URL reservation or
  an elevated prompt, and this has to run as a plain double-click.

  Serves:
    /                 the live map page
    /api/state        the director's snapshot, read from the mod's output dir
    /api/status       what the server can see, for troubleshooting
    /api/command      spawn / remove a squad (forwarded to the mod through
                      output\commands.txt; needs the session token)
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
Say "Page      : http://127.0.0.1:$Port/"
if ($ModOutput) {
  Say "Mod-output: $ModOutput" "Green"
  $stateFile = Join-Path $ModOutput "live_state.json"
  if (Test-Path $stateFile) {
    Say "live_state.json found." "Green"
  } else {
    Say "live_state.json not there yet - the map shows OFFLINE until" "Yellow"
    Say "the server has started and the mod has written its state." "Yellow"
  }
} else {
  Say "Mod output: NOT FOUND - run INSTALL.bat first." "Red"
}
$baseMap = Join-Path $root "map\scum_map.png"
if (-not (Test-Path $baseMap)) {
  Say "map\scum_map.png missing - the map shows an empty grid." "Yellow"
  Say "Run tools\SETUP_HIRES_MAP.bat, it rebuilds the basic map." "Yellow"
}
Say "Close this window when you are done."
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
  Say "Port $Port is taken or blocked: $($_.Exception.Message)" "Red"
  Say "Try another port: START_LIVEMAP.bat 8899" "Yellow"
  Read-Host "  Press Enter to close"
  exit 1
}

if (-not $NoBrowser) {
  try { Start-Process "http://127.0.0.1:$Port/" | Out-Null } catch {}
}

$served = 0
# A page on some other site could make the browser request
# http://127.0.0.1:8777/api/command too. Commands need this token, which only
# the map's own page can read (from /api/status; no CORS, so a foreign page
# cannot read the answer).
$token = [guid]::NewGuid().ToString("N")
$cmdSeq = 0

function Get-Query([string]$raw) {
  $q = @{}
  foreach ($pair in $raw.TrimStart("?").Split("&")) {
    if (-not $pair) { continue }
    $kv = $pair.Split("=", 2)
    $k = [System.Uri]::UnescapeDataString($kv[0])
    $v = if ($kv.Count -gt 1) { [System.Uri]::UnescapeDataString($kv[1]) } else { "" }
    $q[$k] = $v
  }
  return $q
}

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
    $query = ""
    if ($qs -ge 0) { $query = $url.Substring($qs); $url = $url.Substring(0, $qs) }
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

    if ($url -eq "/api/command") {
      $q = Get-Query $query
      $reply = $null
      if ($q["token"] -ne $token) {
        $reply = @{ ok = $false; error = "bad token - reload the map page" }
      } elseif (-not $ModOutput -or -not (Test-Path $ModOutput)) {
        $reply = @{ ok = $false; error = "mod output folder not found" }
      } else {
        $line = $null
        $cmdSeq++
        $id = "c" + [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() + "_" + $cmdSeq
        if ($q["op"] -eq "spawn" -and $q["class"] -match '^[a-z_]{2,40}$' -and $q["size"] -match '^[1-9]$' `
            -and $q["x"] -match '^-?\d{1,8}$' -and $q["y"] -match '^-?\d{1,8}$') {
          $line = "$id spawn $($q['class']) $($q['size']) $($q['x']) $($q['y'])"
        } elseif ($q["op"] -eq "remove" -and $q["gid"] -match '^SQD_\d{1,6}$') {
          $line = "$id remove $($q['gid'])"
        }
        if ($line) {
          [System.IO.File]::AppendAllText((Join-Path $ModOutput "commands.txt"), $line + "`n")
          $reply = @{ ok = $true; id = $id }
          if ($Verbose) { Say "command: $line" "Cyan" }
        } else {
          $reply = @{ ok = $false; error = "invalid command" }
        }
      }
      Send-Json -Stream $stream -Code 200 -Status "OK" -Json ($reply | ConvertTo-Json -Compress)
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
        token = $token
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
    if ($Verbose) { Say "request failed: $($_.Exception.Message)" "DarkYellow" }
    if ($client) { try { $client.Close() } catch {} }
  }
}
