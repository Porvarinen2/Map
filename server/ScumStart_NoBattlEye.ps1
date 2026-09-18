param(
  [string]$ServerRoot = $env:TESLES_SCUM_SERVER_ROOT,
  [string]$PidFile = $env:TESLES_SCUM_PID_FILE
)

$ErrorActionPreference = 'Stop'

function Get-CanonicalPath([string]$Path) {
  return [IO.Path]::GetFullPath($Path).TrimEnd('\')
}

if ([string]::IsNullOrWhiteSpace($ServerRoot)) {
  $modRoot = Split-Path -Parent $PSScriptRoot
  $teslesModsRoot = Split-Path -Parent $modRoot
  $ServerRoot = Split-Path -Parent $teslesModsRoot
}

$ServerRoot = Get-CanonicalPath $ServerRoot
$binDir = Get-CanonicalPath (Join-Path $ServerRoot 'SCUM\Binaries\Win64')
$exe = Get-CanonicalPath (Join-Path $binDir 'SCUMServer.exe')
if ([string]::IsNullOrWhiteSpace($PidFile)) {
  $PidFile = Join-Path $ServerRoot 'TeslesMods\TeslesNPCOverhaul\runtime\scum-server.pid'
}
$PidFile = [IO.Path]::GetFullPath($PidFile)

if (-not (Test-Path -LiteralPath $exe -PathType Leaf)) {
  Write-Error "Configured SCUMServer.exe executable is missing: $exe"
  exit 2
}

$pidDir = Split-Path -Parent $PidFile
if (-not (Test-Path -LiteralPath $pidDir)) { New-Item -ItemType Directory -Path $pidDir -Force | Out-Null }
Remove-Item -LiteralPath $PidFile -Force -ErrorAction SilentlyContinue

try {
  $process = Start-Process -FilePath $exe -ArgumentList @('-log','-MaxPlayers=64','-nobattleye') -WorkingDirectory $binDir -PassThru
} catch {
  Write-Error "Could not start SCUM Server: $($_.Exception.Message)"
  exit 3
}

Start-Sleep -Seconds 2
$process.Refresh()
if ($process.HasExited) {
  $code = $process.ExitCode
  Write-Error "SCUMServer.exe exited during startup with code $code. Executable: $exe"
  exit 4
}

[IO.File]::WriteAllText($PidFile,[string]$process.Id,[Text.Encoding]::ASCII)
Write-Host "Started SCUM Server PID $($process.Id): $exe"
exit 0
