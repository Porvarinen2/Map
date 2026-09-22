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
  [switch]$KeepSampleMods  # leave UE4SS's own bundled mods enabled
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
  Write-Host "  UE4SS - asennus SCUM-palvelimelle" -ForegroundColor Yellow
  Write-Host "  ---------------------------------"

  if (Get-Process -Name "SCUMServer" -ErrorAction SilentlyContinue) {
    Say "SCUMServer on kaynnissa. Sammuta palvelin ensin." "Red"
    return
  }

  if (-not $Win64) { $Win64 = Find-ServerWin64 }
  if (-not $Win64) {
    $root = Read-Host "  Anna SCUM Server -kansion polku"
    $Win64 = Join-Path ($root.Trim('"').Trim()) 'SCUM\Binaries\Win64'
  }
  if (-not (Test-Path (Join-Path $Win64 'SCUMServer.exe'))) {
    Say "SCUMServer.exe ei loydy polusta: $Win64" "Red"
    return
  }
  Say "Palvelin: $Win64" "Green"

  # Record what is installed now, so the end of the run can prove whether the
  # update actually replaced anything. "I updated it" and "the loader on disk
  # changed" are not the same claim.
  function Get-LoaderInfo($w) {
    foreach ($n in @(@('UE4SS.dll'), @('ue4ss', 'UE4SS.dll'))) {
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
    Say ("Asennettuna nyt: UE4SS.dll  {0:N0} B  {1}" -f $before.size,
         $before.date.ToString("yyyy-MM-dd")) "DarkGray"
  }

  if ($before -and -not $Force) {
    Say "UE4SS on jo asennettu. Aja -Force jos haluat asentaa uudelleen." "Yellow"
    return
  }

  # ------------------------------------------------------------- download ---

  $zip = $ZipFile
  $tag = "(paikallinen zip)"

  if (-not $zip) {
    [Net.ServicePointManager]::SecurityProtocol =
      [Net.SecurityProtocolType]::Tls12 -bor [Net.SecurityProtocolType]::Tls11
    Say "Haetaan julkaisulista: $API"
    $headers = @{ "User-Agent" = "TeslesNPCOverhaul-Installer"
                  "Accept" = "application/vnd.github+json" }
    $releases = $null
    try {
      $releases = Invoke-RestMethod -Uri "$API`?per_page=15" -Headers $headers -TimeoutSec 60
    } catch {
      Write-Host ""
      Say "Julkaisulistaa ei saatu haettua:" "Red"
      Say "  $($_.Exception.Message)" "Red"
      Write-Host ""
      Say "Yleisimmat syyt: verkko, palomuuri, tai GitHubin tuntirajoitus" "Yellow"
      Say "(60 pyyntoa tunnissa ilman kirjautumista)." "Yellow"
      Write-Host ""
      Say "Lataa zip kasin ja asenna siita:" "Cyan"
      Say "  1. Avaa https://github.com/$REPO/releases" "Cyan"
      Say "  2. Lataa uusin UE4SS_vX.Y.Z.zip" "Cyan"
      Say "  3. INSTALL_UE4SS.bat -Force -ZipFile C:\polku\UE4SS.zip" "Cyan"
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
      Say "Sopivaa UE4SS-pakettia ei loytynyt julkaisuista." "Red"
      Say "Lataa se kasin osoitteesta https://github.com/$REPO/releases" "Yellow"
      Say "ja aja: INSTALL_UE4SS.bat -ZipFile <polku zipiin>" "Yellow"
      return
    }

    $tag = $chosen.tag_name
    $published = $null
    try { $published = ([datetime]$chosen.published_at).ToString("yyyy-MM-dd") } catch {}
    Write-Host ""
    Say "Versio  : $tag$(if ($chosen.prerelease) { '  (pre-release)' })" "Cyan"
    if ($published) { Say "Julkaistu: $published" "Cyan" }
    if ($before) {
      Say ("Nykyinen : {0}" -f $before.date.ToString("yyyy-MM-dd")) "DarkGray"
      if ($published -and $published -le $before.date.ToString("yyyy-MM-dd")) {
        Say "Tama ei ole uudempi kuin asennettu versio." "Yellow"
        if (-not $Experimental) {
          Say "Kokeile: INSTALL_UE4SS.bat -Force -Experimental" "Yellow"
        }
      }
    }
    Say "Tiedosto: $($asset.name)  ($([math]::Round($asset.size/1MB,2)) MB)"
    Say "Osoite  : $($asset.browser_download_url)"
    Write-Host ""

    if (-not $Yes) {
      $ans = Read-Host "  Ladataanko ja asennetaanko tama? (K/e)"
      if ($ans -and $ans -notmatch '^[kKyY]') { Say "Peruttu." "Yellow"; return }
    }

    $zip = Join-Path ([System.IO.Path]::GetTempPath()) ("ue4ss_" + $asset.name)
    Say "Ladataan..."
    Invoke-WebRequest -Uri $asset.browser_download_url -OutFile $zip `
                      -Headers @{ "User-Agent" = "TeslesNPCOverhaul-Installer" } `
                      -TimeoutSec 600
  }

  if (-not (Test-Path $zip)) {
    Say "Zip-tiedostoa ei loydy: $zip" "Red"
    return
  }
  $hash = (Get-FileHash $zip -Algorithm SHA256).Hash
  Say ("Ladattu: {0:N2} MB" -f ((Get-Item $zip).Length / 1MB)) "Green"
  Say "SHA256 : $hash" "DarkGray"

  # -------------------------------------------------------------- extract ---

  $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("ue4ss_x_" + [guid]::NewGuid().ToString("N"))
  New-Item -ItemType Directory -Path $tmp -Force | Out-Null
  Expand-Archive -LiteralPath $zip -DestinationPath $tmp -Force

  # The zip's layout varies between releases: the payload is whichever folder
  # actually holds the loader, not necessarily the archive root.
  $srcRoot = $tmp
  $marker = Get-ChildItem $tmp -Recurse -File -Include "UE4SS.dll", "UE4SS-settings.ini" |
            Select-Object -First 1
  if ($marker) { $srcRoot = $marker.Directory.FullName }
  Say "Paketin juuri: $($srcRoot.Substring($tmp.Length).TrimStart('\'))" "DarkGray"

  $proxy = Get-ChildItem $srcRoot -File | Where-Object {
    $_.Name -in @("dwmapi.dll", "xinput1_3.dll", "d3d11.dll", "dinput8.dll", "version.dll")
  }
  if (-not $proxy) {
    Say "Paketista ei loydy proxy-DLL:aa - vaara zip?" "Red"
    Say "Sisalto: $((Get-ChildItem $srcRoot | Select-Object -First 12 | ForEach-Object { $_.Name }) -join ', ')" "DarkGray"
    return
  }

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
    Say "Varmuuskopio korvattavista: $backup"
  }

  Copy-Item (Join-Path $srcRoot '*') $Win64 -Recurse -Force
  Say "UE4SS kopioitu palvelimelle." "Green"

  # ---------------------------------------------------------------- verify --

  $modsDir = Join-Path $Win64 'Mods'
  if (-not (Test-Path $modsDir)) {
    $modsDir = Join-Path (Join-Path $Win64 'ue4ss') 'Mods'
  }
  if (-not (Test-Path $modsDir)) {
    New-Item -ItemType Directory -Path $modsDir -Force | Out-Null
    Say "Mods-kansio luotiin: $modsDir" "Yellow"
  }
  $modsTxt = Join-Path $modsDir 'mods.txt'
  if (-not (Test-Path $modsTxt)) {
    Set-Content -LiteralPath $modsTxt -Value @("Keybinds : 1") -Encoding ASCII
    Say "mods.txt luotiin." "Yellow"
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
      Say "UE4SS:n omat esimerkkimodit otettiin pois kaytosta ($parked enabled.txt siirretty)." "Yellow"
      Say "Palauta ne ajamalla -KeepSampleMods, tai muokkaa mods.txt kasin."
    }
  }

  $after = Get-LoaderInfo $Win64
  Write-Host ""
  if (-not $after) {
    Say "UE4SS.dll ei loydy asennuksen jalkeen - jokin meni pieleen." "Red"
  } elseif ($before -and $before.hash -eq $after.hash) {
    Say "VAROITUS: lataaja ei muuttunut." "Yellow"
    Say ("UE4SS.dll on yha sama tiedosto ({0:N0} B, {1})." -f
         $after.size, $after.date.ToString("yyyy-MM-dd")) "Yellow"
    Say "Asensit siis saman version uudelleen. Jos ongelma oli"
    Say "yhteensopivuudessa, se ei korjaannu talla."
    Write-Host ""
    Say "Kokeile esijulkaisua: INSTALL_UE4SS.bat -Force -Experimental" "Cyan"
  } else {
    Say "VALMIS - UE4SS $tag asennettu." "Green"
    if ($before) {
      Say ("Lataaja vaihtui: {0} -> {1}" -f $before.date.ToString("yyyy-MM-dd"),
           $after.date.ToString("yyyy-MM-dd")) "Green"
    }
    Say "proxy-DLL : $($proxy.Name -join ', ')"
    Say "Mods      : $modsDir"
    Write-Host ""
    Say "Seuraavaksi: aja INSTALL.bat asentaaksesi itse modin,"
    Say "kaynnista palvelin ja aja CHECK.bat."
  }
  Write-Host ""

  Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
  if (-not $ZipFile) { Remove-Item $zip -Force -ErrorAction SilentlyContinue }
}
catch {
  Write-Host ""
  Say "VIRHE: $($_.Exception.Message)" "Red"
  if ($_.InvocationInfo) {
    Say "Rivi $($_.InvocationInfo.ScriptLineNumber): $($_.InvocationInfo.Line.Trim())" "DarkGray"
  }
  Write-Host ""
  Say "Voit myos ladata UE4SS:n kasin:" "Yellow"
  Say "  https://github.com/UE4SS-RE/RE-UE4SS/releases" "Yellow"
  Say "ja asentaa sen komennolla:" "Yellow"
  Say "  INSTALL_UE4SS.bat -ZipFile C:\polku\UE4SS.zip" "Yellow"
  Write-Host ""
}
