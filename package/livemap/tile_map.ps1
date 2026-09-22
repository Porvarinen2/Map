<#
  Builds a zoom pyramid from a high-resolution SCUM map image.

  A 14336 x 14336 PNG is far too heavy for a browser canvas, so the live map
  loads 512 px tiles per zoom level instead. Drop the map into livemap\map\ as
  scum_map_hires.png (any common image extension works) and run
  SETUP_HIRES_MAP.bat.

  Each level is decoded directly at that level's width (DecodePixelWidth) and
  cut with WPF imaging, so only one level is ever in memory and there is no
  second GDI copy of it.
#>
param(
  [string]$Source = "",
  [int]$Tile = 512,
  [int]$MaxSize = 8192,
  [int]$Quality = 82
)

$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$mapDir = Join-Path $root "map"
$tileDir = Join-Path $mapDir "tiles"

function Say($t, $c = "Gray") { Write-Host "  $t" -ForegroundColor $c }

try {
  Add-Type -AssemblyName PresentationCore
  Add-Type -AssemblyName WindowsBase

  Write-Host ""
  Write-Host "  TESLES NPC OVERHAUL - kartan pilkkominen" -ForegroundColor Yellow
  Write-Host "  ----------------------------------------"

  if (-not (Test-Path $mapDir)) {
    throw "Kansiota ei loydy: $mapDir"
  }

  # Accept any image the user dropped in, whatever the extension.
  if (-not $Source) {
    $exts = @(".png", ".jpg", ".jpeg", ".bmp", ".webp", ".tif", ".tiff", "")
    foreach ($e in $exts) {
      $c = Join-Path $mapDir ("scum_map_hires" + $e)
      if (Test-Path $c -PathType Leaf) { $Source = $c; break }
    }
  }
  # Still nothing: take the biggest image in the folder that is not the
  # packaged base map, so a differently named download still works.
  if (-not $Source) {
    $cand = Get-ChildItem $mapDir -File |
      Where-Object { $_.Name -ne "scum_map.png" -and $_.Length -gt 200KB } |
      Sort-Object Length -Descending | Select-Object -First 1
    if ($cand) {
      $Source = $cand.FullName
      Say "Kaytetaan loydettya kuvaa: $($cand.Name)" "Yellow"
    }
  }

  if (-not $Source -or -not (Test-Path $Source -PathType Leaf)) {
    Write-Host ""
    Say "Tarkkaa karttakuvaa ei loytynyt." "Yellow"
    Say "Tallenna kuva nimella scum_map_hires.png tahan kansioon:"
    Say "  $mapDir"
    Write-Host ""
    Say "Kansiossa on nyt:"
    Get-ChildItem $mapDir -File | ForEach-Object {
      Say ("  {0}  ({1:N1} MB)" -f $_.Name, ($_.Length / 1MB))
    }
    Write-Host ""
    return
  }

  Say "Lahde : $Source"

  # Read the dimensions without decoding the pixels.
  $uri = New-Object System.Uri((Resolve-Path $Source).Path)
  $dec = [System.Windows.Media.Imaging.BitmapDecoder]::Create(
    $uri,
    [System.Windows.Media.Imaging.BitmapCreateOptions]::DelayCreation,
    [System.Windows.Media.Imaging.BitmapCacheOption]::None)
  $srcW = $dec.Frames[0].PixelWidth
  $srcH = $dec.Frames[0].PixelHeight
  $dec = $null
  Say "Koko  : $srcW x $srcH"

  if ($srcW -lt 2048) {
    Say "Kuva on pienempi kuin mukana tuleva kartta. Pilkkomista ei tarvita." "Yellow"
    return
  }
  if ([math]::Abs($srcW - $srcH) -gt 4) {
    Say "VAROITUS: kuva ei ole nelio. Merkit voivat osua vaarin." "Yellow"
  }

  # The live map needs a base image even when tiles exist (it is the fallback
  # while tiles load). Recreate it from the source if it went missing.
  $baseMap = Join-Path $mapDir "scum_map.png"
  if (-not (Test-Path $baseMap)) {
    Say "scum_map.png puuttuu - luodaan se lahdekuvasta." "Yellow"
    $b = New-Object System.Windows.Media.Imaging.BitmapImage
    $b.BeginInit()
    $b.UriSource = $uri
    $b.DecodePixelWidth = 2048
    $b.CacheOption = [System.Windows.Media.Imaging.BitmapCacheOption]::OnLoad
    $b.EndInit()
    $b.Freeze()
    $penc = New-Object System.Windows.Media.Imaging.PngBitmapEncoder
    $penc.Frames.Add([System.Windows.Media.Imaging.BitmapFrame]::Create($b))
    $fs = [System.IO.File]::Create($baseMap)
    try { $penc.Save($fs) } finally { $fs.Close() }
    $b = $null
    [System.GC]::Collect()
    Say "scum_map.png luotu." "Green"
  }

  $target = [math]::Min($MaxSize, $srcW)
  $levels = @()
  $w = 2048
  while ($w -le $target) { $levels += $w; $w = $w * 2 }
  if ($levels.Count -eq 0) { $levels = @($target) }
  if ($levels[-1] -ne $target) { $levels += $target }

  if (Test-Path $tileDir) { Remove-Item $tileDir -Recurse -Force }
  New-Item -ItemType Directory -Path $tileDir -Force | Out-Null

  $meta = @{ width = $srcW; height = $srcH; tile = $Tile; ext = "jpg"; levels = @() }

  for ($z = 0; $z -lt $levels.Count; $z++) {
    $lw = $levels[$z]
    Write-Host ("  Taso {0} : {1} x {1} ..." -f $z, $lw) -NoNewline

    $bmp = New-Object System.Windows.Media.Imaging.BitmapImage
    $bmp.BeginInit()
    $bmp.UriSource = $uri
    $bmp.DecodePixelWidth = $lw
    $bmp.CacheOption = [System.Windows.Media.Imaging.BitmapCacheOption]::OnLoad
    $bmp.EndInit()
    $bmp.Freeze()

    $lwActual = $bmp.PixelWidth
    $lh = $bmp.PixelHeight
    $cols = [int][math]::Ceiling($lwActual / $Tile)
    $rows = [int][math]::Ceiling($lh / $Tile)
    $levelDir = Join-Path $tileDir "$z"
    New-Item -ItemType Directory -Path $levelDir -Force | Out-Null

    for ($ty = 0; $ty -lt $rows; $ty++) {
      for ($tx = 0; $tx -lt $cols; $tx++) {
        $x = $tx * $Tile
        $y = $ty * $Tile
        $tw = [math]::Min($Tile, $lwActual - $x)
        $th = [math]::Min($Tile, $lh - $y)
        $rect = New-Object System.Windows.Int32Rect($x, $y, $tw, $th)
        $crop = New-Object System.Windows.Media.Imaging.CroppedBitmap($bmp, $rect)
        $enc = New-Object System.Windows.Media.Imaging.JpegBitmapEncoder
        $enc.QualityLevel = $Quality
        $enc.Frames.Add([System.Windows.Media.Imaging.BitmapFrame]::Create($crop))
        $out = [System.IO.File]::Create((Join-Path $levelDir "${tx}_${ty}.jpg"))
        try { $enc.Save($out) } finally { $out.Close() }
      }
    }

    $meta.levels += @{ z = $z; width = $lwActual; height = $lh
                       tile = $Tile; cols = $cols; rows = $rows }
    $bmp = $null
    [System.GC]::Collect()
    [System.GC]::WaitForPendingFinalizers()
    Write-Host (" {0} ruutua" -f ($cols * $rows))
  }

  $json = $meta | ConvertTo-Json -Depth 5 -Compress
  [System.IO.File]::WriteAllText((Join-Path $tileDir "meta.json"), $json)

  Write-Host ""
  Say "Valmis. Live map kayttaa nyt tarkkaa karttaa." "Green"
  Say "Paivita selain Ctrl+F5."
  Write-Host ""
}
catch [System.OutOfMemoryException] {
  Write-Host ""
  Say "Muisti loppui kesken." "Red"
  Say "Aja uudestaan pienemmalla tarkkuudella, esimerkiksi:" "Yellow"
  Say "  powershell -ExecutionPolicy Bypass -File livemap\tile_map.ps1 -MaxSize 4096"
  Write-Host ""
}
catch {
  Write-Host ""
  Say "VIRHE: $($_.Exception.Message)" "Red"
  if ($_.InvocationInfo) {
    Say "Rivi $($_.InvocationInfo.ScriptLineNumber): $($_.InvocationInfo.Line.Trim())" "DarkGray"
  }
  Write-Host ""
}
finally {
  Read-Host "  Enter sulkee"
}
