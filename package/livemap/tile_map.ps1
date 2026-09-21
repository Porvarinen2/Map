<#
  Builds a zoom pyramid from a high-resolution SCUM map image.

  Why this exists: a 14336 x 14336 PNG is far too heavy for a browser canvas,
  so the live map loads 512 px tiles per zoom level instead. Drop the map into
  livemap\map\ as scum_map_hires.png (or .jpg) and run SETUP_HIRES_MAP.bat.

  Each level is produced by decoding the source directly at that level's width
  (DecodePixelWidth), so peak memory stays at roughly level size squared times
  four bytes rather than the full source.
#>
param(
  [string]$Source = "",
  [int]$Tile = 512,
  [int]$MaxSize = 8192,
  [int]$Quality = 82
)

$ErrorActionPreference = "Stop"
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName System.Drawing

$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$mapDir = Join-Path $root "map"
$tileDir = Join-Path $mapDir "tiles"

if (-not $Source) {
  foreach ($n in @("scum_map_hires.png", "scum_map_hires.jpg", "scum_map_hires.jpeg",
                   "scum_map_hires.webp")) {
    $c = Join-Path $mapDir $n
    if (Test-Path $c) { $Source = $c; break }
  }
}

if (-not $Source -or -not (Test-Path $Source)) {
  Write-Host ""
  Write-Host "  Tarkkaa karttakuvaa ei loytynyt." -ForegroundColor Yellow
  Write-Host "  Tallenna kuva nimella scum_map_hires.png tahan kansioon:"
  Write-Host "    $mapDir"
  Write-Host ""
  Write-Host "  Kuvan tulee olla nelio ja kattaa koko saari samalla rajauksella"
  Write-Host "  kuin mukana tuleva scum_map.png, muuten merkit osuvat vaaraan kohtaan."
  Write-Host ""
  Read-Host "  Enter sulkee"
  exit 1
}

Write-Host ""
Write-Host "  Lahde : $Source"

$fs = [System.IO.File]::OpenRead($Source)
try {
  $dec = [System.Windows.Media.Imaging.BitmapDecoder]::Create(
    $fs, [System.Windows.Media.Imaging.BitmapCreateOptions]::PreservePixelFormat,
    [System.Windows.Media.Imaging.BitmapCacheOption]::None)
  $srcW = $dec.Frames[0].PixelWidth
  $srcH = $dec.Frames[0].PixelHeight
} finally { $fs.Close() }

Write-Host "  Koko  : $srcW x $srcH"
if ([math]::Abs($srcW - $srcH) -gt 4) {
  Write-Host "  VAROITUS: kuva ei ole nelio. Merkit voivat osua vaarin." -ForegroundColor Yellow
}

$target = [math]::Min($MaxSize, $srcW)
$levels = @()
$w = 2048
while ($w -le $target) { $levels += $w; $w = $w * 2 }
if ($levels.Count -eq 0) { $levels = @($target) }
if ($levels[-1] -ne $target) { $levels += $target }

if (Test-Path $tileDir) { Remove-Item $tileDir -Recurse -Force }
New-Item -ItemType Directory -Path $tileDir -Force | Out-Null

$encParams = New-Object System.Drawing.Imaging.EncoderParameters(1)
$encParams.Param[0] = New-Object System.Drawing.Imaging.EncoderParameter(
  [System.Drawing.Imaging.Encoder]::Quality, [int]$Quality)
$jpeg = [System.Drawing.Imaging.ImageCodecInfo]::GetImageEncoders() |
  Where-Object { $_.MimeType -eq "image/jpeg" }

$meta = @{ width = $srcW; height = $srcH; tile = $Tile; ext = "jpg"; levels = @() }

for ($z = 0; $z -lt $levels.Count; $z++) {
  $lw = $levels[$z]
  Write-Host "  Taso $z : $lw x $lw ..." -NoNewline

  $fs2 = [System.IO.File]::OpenRead($Source)
  try {
    $bmp = New-Object System.Windows.Media.Imaging.BitmapImage
    $bmp.BeginInit()
    $bmp.StreamSource = $fs2
    $bmp.DecodePixelWidth = $lw
    $bmp.CacheOption = [System.Windows.Media.Imaging.BitmapCacheOption]::OnLoad
    $bmp.EndInit()
    $bmp.Freeze()

    $lh = $bmp.PixelHeight
    $stride = $bmp.PixelWidth * 4
    $conv = New-Object System.Windows.Media.Imaging.FormatConvertedBitmap(
      $bmp, [System.Windows.Media.PixelFormats]::Bgra32, $null, 0)
    $conv.Freeze()
    $pixels = New-Object byte[] ($stride * $lh)
    $conv.CopyPixels($pixels, $stride, 0)

    $gdi = New-Object System.Drawing.Bitmap($bmp.PixelWidth, $lh,
      [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $data = $gdi.LockBits(
      (New-Object System.Drawing.Rectangle(0, 0, $bmp.PixelWidth, $lh)),
      [System.Drawing.Imaging.ImageLockMode]::WriteOnly,
      [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    [System.Runtime.InteropServices.Marshal]::Copy($pixels, 0, $data.Scan0, $pixels.Length)
    $gdi.UnlockBits($data)
    $pixels = $null

    $cols = [math]::Ceiling($bmp.PixelWidth / $Tile)
    $rows = [math]::Ceiling($lh / $Tile)
    $levelDir = Join-Path $tileDir "$z"
    New-Item -ItemType Directory -Path $levelDir -Force | Out-Null

    for ($ty = 0; $ty -lt $rows; $ty++) {
      for ($tx = 0; $tx -lt $cols; $tx++) {
        $tw = [math]::Min($Tile, $bmp.PixelWidth - $tx * $Tile)
        $th = [math]::Min($Tile, $lh - $ty * $Tile)
        $tile = New-Object System.Drawing.Bitmap($Tile, $Tile,
          [System.Drawing.Imaging.PixelFormat]::Format24bppRgb)
        $g = [System.Drawing.Graphics]::FromImage($tile)
        $g.Clear([System.Drawing.Color]::FromArgb(5, 6, 10))
        $g.DrawImage($gdi,
          (New-Object System.Drawing.Rectangle(0, 0, $tw, $th)),
          (New-Object System.Drawing.Rectangle($tx * $Tile, $ty * $Tile, $tw, $th)),
          [System.Drawing.GraphicsUnit]::Pixel)
        $g.Dispose()
        $tile.Save((Join-Path $levelDir "${tx}_${ty}.jpg"), $jpeg, $encParams)
        $tile.Dispose()
      }
    }

    $meta.levels += @{ z = $z; width = $bmp.PixelWidth; height = $lh
                       tile = $Tile; cols = $cols; rows = $rows }
    $gdi.Dispose()
    $bmp = $null
    [System.GC]::Collect()
    Write-Host " $($cols * $rows) ruutua"
  } finally { $fs2.Close() }
}

$json = $meta | ConvertTo-Json -Depth 5 -Compress
[System.IO.File]::WriteAllText((Join-Path $tileDir "meta.json"), $json)

Write-Host ""
Write-Host "  Valmis. Live map kayttaa nyt tarkkaa karttaa." -ForegroundColor Green
Write-Host "  Paivita selain (Ctrl+F5)."
Write-Host ""
Read-Host "  Enter sulkee"
