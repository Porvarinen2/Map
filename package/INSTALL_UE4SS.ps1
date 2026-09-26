<#
  TESLES NPC OVERHAUL - UE4SS installer.

  This mod is a UE4SS Lua mod, so UE4SS has to be on the server before the mod
  can do anything. A clean SCUM server does not ship it.

  The release is downloaded from the official UE4SS repository on GitHub. The
  URL, version and SHA256 are printed before anything is written, and nothing
  outside the server's Win64 folder is touched.

  Run standalone, or let INSTALL.ps1 call it when the Mods folder is missing.
#>
param(
  [string]$Win64 = "",
  [switch]$Experimental,   # allow pre-release builds (newer engine support)
  [switch]$Force,          # reinstall even if UE4SS is already present
  [switch]$Yes,            # skip the confirmation prompt
  [string]$ZipFile = "",   # install from an already downloaded zip instead
  [switch]$KeepSampleMods, # leave UE4SS's own bundled mods enabled
  [switch]$Chained,        # called from INSTALL.ps1: no next-step advice
  [switch]$Online          # ignore the bundled build, fetch from GitHub
)

$ErrorActionPreference = "Stop"
$REPO = "UE4SS-RE/RE-UE4SS"
$API = "https://api.github.com/repos/$REPO/releases"

function Say($t, $c = "Gray") { Write-Host "  $t" -ForegroundColor $c }

function Find-ServerWin64 {
  $candidates = @(
    'F:\SteamLibrary\steamapps\common\SCUM Server',
    'D:\SteamLibrary\steamapps\common\SCUM Server',
    'E:\SteamLibrary\steamapps\common\SCUM Server',
    'C:\SteamLibrary\steamapps\common\SCUM Server',
    'C:\Program Files (x86)\Steam\steamapps\common\SCUM Server',
    'C:\Program Files\Steam\steamapps\common\SCUM Server'
  )
  foreach ($c in $candidates) {
    $p = Join-Path $c 'SCUM\Binaries\Win64'
    if (Test-Path (Join-Path $p 'SCUMServer.exe')) { return $p }
  }
  return $null
}

try {
  Write-Host ""
  Write-Host "  UE4SS - install on the SCUM server" -ForegroundColor Yellow
  Write-Host "  ---------------------------------"

  if (Get-Process -Name "SCUMServer" -ErrorAction SilentlyContinue) {
    Say "SCUMServer is running. Stop the server first." "Red"
    return
  }

  if (-not $Win64) { $Win64 = Find-ServerWin64 }
  if (-not $Win64) {
    $root = Read-Host "  Path of the SCUM Server folder"
    $Win64 = Join-Path ($root.Trim('"').Trim()) 'SCUM\Binaries\Win64'
  }
  if (-not (Test-Path (Join-Path $Win64 'SCUMServer.exe'))) {
    Say "SCUMServer.exe not found in: $Win64" "Red"
    return
  }
  Say "Server: $Win64" "Green"

  # Record what is installed now, so the end of the run can prove whether the
  # update actually replaced anything. "I updated it" and "the loader on disk
  # changed" are not the same claim.
  function Get-LoaderInfo($w) {
    foreach ($n in @(@('ue4ss', 'UE4SS.dll'), @('UE4SS.dll'))) {
      $p = $w; foreach ($seg in $n) { $p = Join-Path $p $seg }
      if (Test-Path $p) {
        $f = Get-Item $p
        return [pscustomobject]@{
          path = $p; size = $f.Length; date = $f.LastWriteTime
          hash = (Get-FileHash $p -Algorithm SHA256).Hash
        }
      }
    }
    return $null
  }
  $before = Get-LoaderInfo $Win64
  if ($before) {
    Say ("Installed now: UE4SS.dll  {0:N0} B  {1}" -f $before.size,
         $before.date.ToString("yyyy-MM-dd")) "DarkGray"
  }

  if ($before -and -not $Force) {
    Say "UE4SS is already installed. Use -Force to reinstall." "Yellow"
    return
  }

  # ------------------------------------------------------------- download ---

  $zip = $ZipFile
  $tag = "(local zip)"
  # Only a zip this run downloaded into TEMP may be deleted afterwards. The
  # bundled copy and a zip the user pointed at are theirs, not ours.
  $zipIsTemp = $false

  # The package ships a UE4SS build, so a clean server can be set up without a
  # network and always gets the exact build this mod was tested against.
  if (-not $zip -and -not $Online) {
    $bundleDir = Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) 'ue4ss'
    $bundle = Get-ChildItem -LiteralPath $bundleDir -Filter 'UE4SS_*.zip' `
                            -ErrorAction SilentlyContinue |
              Sort-Object Name -Descending | Select-Object -First 1
    if ($bundle) {
      $zip = $bundle.FullName
      $tag = [IO.Path]::GetFileNameWithoutExtension($bundle.Name)
      Say "Using the UE4SS shipped with this package: $($bundle.Name)" "Cyan"
      Say "To download instead: tools\INSTALL_UE4SS.bat -Force -Online" "DarkGray"
    }
  }

  if (-not $zip) {
    [Net.ServicePointManager]::SecurityProtocol =
      [Net.SecurityProtocolType]::Tls12 -bor [Net.SecurityProtocolType]::Tls11
    Say "Fetching the release list: $API"
    $headers = @{ "User-Agent" = "TeslesNPCOverhaul-Installer"
                  "Accept" = "application/vnd.github+json" }
    $releases = $null
    try {
      $releases = Invoke-RestMethod -Uri "$API`?per_page=15" -Headers $headers -TimeoutSec 60
    } catch {
      Write-Host ""
      Say "Could not fetch the release list:" "Red"
      Say "  $($_.Exception.Message)" "Red"
      Write-Host ""
      Say "Usual causes: network, firewall, or GitHub's rate limit" "Yellow"
      Say "(60 requests an hour without logging in)." "Yellow"
      Write-Host ""
      Say "Download the zip by hand and install from it:" "Cyan"
      Say "  1. Open https://github.com/$REPO/releases" "Cyan"
      Say "  2. Download the latest UE4SS_vX.Y.Z.zip" "Cyan"
      Say "  3. tools\INSTALL_UE4SS.bat -Force -ZipFile C:\path\UE4SS.zip" "Cyan"
      Write-Host ""
      return
    }

    # Pick the newest release that ships a plain UE4SS zip. Development and
    # debug builds are skipped; a pre-release is only used when asked for,
    # because newer engine support sometimes only exists there.
    $chosen = $null
    $asset = $null
    foreach ($r in $releases) {
      if ($r.prerelease -and -not $Experimental) { continue }
      if ($r.draft) { continue }
      $a = $r.assets | Where-Object {
        $_.name -match '^UE4SS.*\.zip$' -and
        $_.name -notmatch 'dev|DEV|pdb|Debug|docs|source'
      } | Sort-Object { $_.name.Length } | Select-Object -First 1
      if ($a) { $chosen = $r; $asset = $a; break }
    }
    if (-not $asset) {
      Say "No suitable UE4SS package in the releases." "Red"
      Say "Download it by hand from https://github.com/$REPO/releases" "Yellow"
      Say "and run: tools\INSTALL_UE4SS.bat -ZipFile <path to zip>" "Yellow"
      return
    }

    $tag = $chosen.tag_name
    $published = $null
    try { $published = ([datetime]$chosen.published_at).ToString("yyyy-MM-dd") } catch {}
    Write-Host ""
    Say "Version : $tag$(if ($chosen.prerelease) { '  (pre-release)' })" "Cyan"
    if ($published) { Say "Published: $published" "Cyan" }
    if ($before) {
      Say ("Current  : {0}" -f $before.date.ToString("yyyy-MM-dd")) "DarkGray"
      if ($published -and $published -le $before.date.ToString("yyyy-MM-dd")) {
        Say "This is not newer than the installed version." "Yellow"
        if (-not $Experimental) {
          Say "Try: tools\INSTALL_UE4SS.bat -Force -Experimental" "Yellow"
        }
      }
    }
    Say "File    : $($asset.name)  ($([math]::Round($asset.size/1MB,2)) MB)"
    Say "URL     : $($asset.browser_download_url)"
    Write-Host ""

    if (-not $Yes) {
      $ans = Read-Host "  Download and install this? (Y/n)"
      if ($ans -and $ans -notmatch '^[kKyY]') { Say "Cancelled." "Yellow"; return }
    }

    $zip = Join-Path ([System.IO.Path]::GetTempPath()) ("ue4ss_" + $asset.name)
    $zipIsTemp = $true
    Say "Downloading..."
    Invoke-WebRequest -Uri $asset.browser_download_url -OutFile $zip `
                      -Headers @{ "User-Agent" = "TeslesNPCOverhaul-Installer" } `
                      -TimeoutSec 600
  }

  if (-not (Test-Path $zip)) {
    Say "Zip file not found: $zip" "Red"
    return
  }
  $hash = (Get-FileHash $zip -Algorithm SHA256).Hash
  Say ("{0}: {1:N2} MB" -f $(if ($zipIsTemp) { "Downloaded" } else { "Package" }),
       ((Get-Item $zip).Length / 1MB)) "Green"
  Say "SHA256 : $hash" "DarkGray"

  # -------------------------------------------------------------- extract ---

  $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("ue4ss_x_" + [guid]::NewGuid().ToString("N"))
  New-Item -ItemType Directory -Path $tmp -Force | Out-Null
  Expand-Archive -LiteralPath $zip -DestinationPath $tmp -Force

  # The zip's layout varies between releases. Up to v3.0.1 the loader, its
  # settings and Mods all sat at the archive root; newer builds keep those in a
  # ue4ss\ subfolder and leave only the proxy DLL at the root. The proxy is the
  # one file that always belongs directly in Win64, so root the copy there and
  # the rest of the layout follows unchanged.
  $proxyNames = @("dwmapi.dll", "xinput1_3.dll", "d3d11.dll", "dinput8.dll", "version.dll")
  $proxyFile = Get-ChildItem $tmp -Recurse -File |
               Where-Object { $proxyNames -contains $_.Name } |
               Sort-Object { $_.FullName.Length } | Select-Object -First 1
  if (-not $proxyFile) {
    Say "No proxy DLL in the package - wrong zip?" "Red"
    Say "Contents: $((Get-ChildItem $tmp | Select-Object -First 12 | ForEach-Object { $_.Name }) -join ', ')" "DarkGray"
    return
  }
  $srcRoot = $proxyFile.Directory.FullName
  $proxy = @($proxyFile)
  $rel = $srcRoot.Substring($tmp.Length).Trim('\', '/')
  Say "Package root: $(if ($rel) { $rel } else { '(archive root)' })" "DarkGray"
  $nested = Test-Path (Join-Path (Join-Path $srcRoot 'ue4ss') 'UE4SS.dll')
  if ($nested) { Say "New layout: loader in the ue4ss\ folder" "DarkGray" }

  # Back up anything we are about to overwrite.
  $stamp = Get-Date -Format "yyyyMMdd-HHmmss"
  $backup = Join-Path (Split-Path (Split-Path $Win64 -Parent) -Parent) "UE4SS_Backups\$stamp"
  $existing = Get-ChildItem $srcRoot | ForEach-Object {
    $t = Join-Path $Win64 $_.Name
    if (Test-Path $t) { $t }
  }
  if ($existing) {
    New-Item -ItemType Directory -Path $backup -Force | Out-Null
    foreach ($e in $existing) { Copy-Item $e $backup -Recurse -Force }
    Say "Backup of replaced files: $backup"
  }

  Copy-Item (Join-Path $srcRoot '*') $Win64 -Recurse -Force
  Say "UE4SS copied to the server." "Green"

  # An older flat install leaves UE4SS.dll and Mods\ directly in Win64. The new
  # proxy loads ue4ss\UE4SS.dll instead, so those are dead weight that would
  # read as the live install. Park them rather than delete them.
  if ($nested) {
    foreach ($stale in @('UE4SS.dll', 'Mods')) {
      $sp = Join-Path $Win64 $stale
      if (Test-Path -LiteralPath $sp) {
        $dest = "$sp.vanha-rakenne"
        if (Test-Path -LiteralPath $dest) { Remove-Item $dest -Recurse -Force -ErrorAction SilentlyContinue }
        Move-Item -LiteralPath $sp -Destination $dest -Force -ErrorAction SilentlyContinue
        Say "Old layout moved aside: $stale -> $stale.vanha-rakenne" "Yellow"
      }
    }
  }

  # ---------------------------------------------------------------- verify --

  $modsDir = Join-Path (Join-Path $Win64 'ue4ss') 'Mods'
  if (-not (Test-Path $modsDir)) {
    $modsDir = Join-Path $Win64 'Mods'
  }
  if (-not (Test-Path $modsDir)) {
    New-Item -ItemType Directory -Path $modsDir -Force | Out-Null
    Say "Created the Mods folder: $modsDir" "Yellow"
  }
  $modsTxt = Join-Path $modsDir 'mods.txt'
  if (-not (Test-Path $modsTxt)) {
    Set-Content -LiteralPath $modsTxt -Value @("Keybinds : 1") -Encoding ASCII
    Say "Created mods.txt." "Yellow"
  }

  # A server does not need UE4SS's sample mods, and every extra Lua mod is one
  # more thing that can fail before this one loads. Off by default.
  if (-not $KeepSampleMods) {
    $lines = @(Get-Content $modsTxt)
    $keep = @("Keybinds")
    $changed = $false
    $out = foreach ($l in $lines) {
      if ($l -match '^\s*([A-Za-z0-9_]+)\s*:\s*1\s*$') {
        $name = $Matches[1]
        if ($keep -contains $name -or $name -like 'Tesles*') { $l }
        else { $changed = $true; "$name : 0" }
      } else { $l }
    }
    # UE4SS also starts any mod folder holding enabled.txt, whatever mods.txt
    # says, so those markers have to move aside too.
    $parked = 0
    foreach ($d in Get-ChildItem $modsDir -Directory -ErrorAction SilentlyContinue) {
      if ($d.Name -like 'Tesles*') { continue }
      $marker = Join-Path $d.FullName 'enabled.txt'
      if (Test-Path $marker) {
        Move-Item $marker "$marker.disabled" -Force
        $parked++
      }
    }
    if ($changed -or $parked -gt 0) {
      if ($changed) { Set-Content -LiteralPath $modsTxt -Value $out -Encoding ASCII }
      Say "UE4SS's own sample mods switched off ($parked enabled.txt moved)." "Yellow"
      Say "Get them back with -KeepSampleMods, or edit mods.txt by hand."
    }
  }

  $after = Get-LoaderInfo $Win64
  Write-Host ""
  if (-not $after) {
    Say "UE4SS.dll is missing after the install - something went wrong." "Red"
  } elseif ($before -and $before.hash -eq $after.hash -and -not $zipIsTemp) {
    # Reinstalling the bundled build over itself is the normal case once the
    # server is up to date. That is not a warning.
    Say ("UE4SS already was this version ({0:N0} B, {1}) - no change." -f
         $after.size, $after.date.ToString("yyyy-MM-dd")) "Green"
    Say "proxy-DLL : $($proxy.Name -join ', ')"
    Say "Mods      : $modsDir"
    $global:TeslesLoaderAlreadyCurrent = $true
  } elseif ($before -and $before.hash -eq $after.hash) {
    Say "WARNING: the loader did not change." "Yellow"
    Say ("UE4SS.dll is still the same file ({0:N0} B, {1})." -f
         $after.size, $after.date.ToString("yyyy-MM-dd")) "Yellow"
    Say "So the same version was installed again. If the problem was"
    Say "compatibility, this does not fix it."
  } else {
    Say "DONE - UE4SS $tag installed." "Green"
    if ($before) {
      Say ("Loader changed: {0} -> {1}" -f $before.date.ToString("yyyy-MM-dd"),
           $after.date.ToString("yyyy-MM-dd")) "Green"
    }
    Say "proxy-DLL : $($proxy.Name -join ', ')"
    Say "Mods      : $modsDir"
    if (-not $Chained) {
      Write-Host ""
      Say "Next: run INSTALL.bat to install the mod itself,"
      Say "start the server and run tools\CHECK.bat."
    }
  }
  Write-Host ""

  Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
  if ($zipIsTemp) { Remove-Item $zip -Force -ErrorAction SilentlyContinue }
}
catch {
  Write-Host ""
  Say "ERROR: $($_.Exception.Message)" "Red"
  if ($_.InvocationInfo) {
    Say "Line $($_.InvocationInfo.ScriptLineNumber): $($_.InvocationInfo.Line.Trim())" "DarkGray"
  }
  Write-Host ""
  if (-not $Chained) {
    Say "You can also download UE4SS by hand:" "Yellow"
    Say "  https://github.com/UE4SS-RE/RE-UE4SS/releases" "Yellow"
    Say "and install it with:" "Yellow"
    Say "  tools\INSTALL_UE4SS.bat -ZipFile C:\path\UE4SS.zip" "Yellow"
  }
  Write-Host ""
}
