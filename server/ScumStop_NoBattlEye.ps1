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
$exe = Get-CanonicalPath (Join-Path $ServerRoot 'SCUM\Binaries\Win64\SCUMServer.exe')
if ([string]::IsNullOrWhiteSpace($PidFile)) {
  $PidFile = Join-Path $ServerRoot 'TeslesMods\TeslesNPCOverhaul\runtime\scum-server.pid'
}
$PidFile = [IO.Path]::GetFullPath($PidFile)

if (-not (Test-Path -LiteralPath $exe -PathType Leaf)) {
  Write-Error "Configured SCUMServer.exe executable is missing: $exe"
  exit 2
}

if (Test-Path -LiteralPath $PidFile -PathType Leaf) {
  $managedPid=0
  if ([int]::TryParse((Get-Content -LiteralPath $PidFile -Raw).Trim(),[ref]$managedPid) -and $managedPid -gt 0) {
    $managed=Get-Process -Id $managedPid -ErrorAction SilentlyContinue
    if ($managed -and $managed.ProcessName -ieq 'SCUMServer') {
      Stop-Process -Id $managedPid -Force -ErrorAction Stop
      $deadline=(Get-Date).AddSeconds(10)
      do {
        Start-Sleep -Milliseconds 250
        if (-not(Get-Process -Id $managedPid -ErrorAction SilentlyContinue)) {
          Remove-Item -LiteralPath $PidFile -Force -ErrorAction SilentlyContinue
          Write-Host "Stopped managed SCUM Server PID ${managedPid}: $exe"
          exit 0
        }
      } while ((Get-Date) -lt $deadline)
      Write-Error "Managed SCUM Server PID $managedPid is still running after termination request: $exe"
      exit 1
    }
  }
  Remove-Item -LiteralPath $PidFile -Force -ErrorAction SilentlyContinue
}

function Get-MatchingScumProcess {
  $all = @(Get-CimInstance Win32_Process -Filter "Name='SCUMServer.exe'" -ErrorAction SilentlyContinue)
  return @($all | Where-Object {
    if ([string]::IsNullOrWhiteSpace($_.ExecutablePath)) { return $false }
    try {
      (Get-CanonicalPath $_.ExecutablePath) -ieq $exe
    } catch {
      $false
    }
  })
}

$targets = @(Get-MatchingScumProcess)
if ($targets.Count -eq 0) {
  $named = @(Get-Process -Name 'SCUMServer' -ErrorAction SilentlyContinue)
  if ($named.Count -eq 1) {
    $fallbackPid = $named[0].Id
    Write-Host "SCUMServer.exe path is not visible through CIM; stopping the only SCUMServer process by PID $fallbackPid."
    Stop-Process -Id $fallbackPid -Force -ErrorAction Stop
    $deadline = (Get-Date).AddSeconds(10)
    do {
      Start-Sleep -Milliseconds 250
      if (-not (Get-Process -Id $fallbackPid -ErrorAction SilentlyContinue)) {
        Remove-Item -LiteralPath $PidFile -Force -ErrorAction SilentlyContinue
        Write-Host "Stopped SCUM Server PID ${fallbackPid}: $exe"
        exit 0
      }
    } while ((Get-Date) -lt $deadline)
    Write-Error "SCUM Server PID $fallbackPid is still running after termination request: $exe"
    exit 1
  }
  if ($named.Count -gt 1) {
    $ids = ($named | ForEach-Object { $_.Id }) -join ', '
    Write-Error "Cannot safely choose between multiple SCUMServer.exe processes because Windows did not expose their executable paths. PIDs: $ids"
    exit 5
  }
  Write-Host "SCUM Server already stopped: $exe"
  exit 0
}

foreach ($target in $targets) {
  Invoke-CimMethod -InputObject $target -MethodName Terminate -ErrorAction Stop | Out-Null
}

$deadline = (Get-Date).AddSeconds(10)
do {
  Start-Sleep -Milliseconds 250
  $left = @(Get-MatchingScumProcess)
  if ($left.Count -eq 0) {
    Remove-Item -LiteralPath $PidFile -Force -ErrorAction SilentlyContinue
    Write-Host "Stopped SCUM Server: $exe"
    exit 0
  }
} while ((Get-Date) -lt $deadline)

Write-Error "Matching SCUM server is still running after termination request: $exe"
exit 1
