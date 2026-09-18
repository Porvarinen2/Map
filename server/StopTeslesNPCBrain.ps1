param(
  [string]$Target = $env:TESLES_BRAIN_TARGET
)

$ErrorActionPreference = 'Stop'

$modRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
if ([string]::IsNullOrWhiteSpace($Target)) {
  $Target = Join-Path $modRoot 'brain\src\server.js'
}

$Target = [IO.Path]::GetFullPath($Target)
$matches = @(Get-CimInstance Win32_Process -Filter "Name='node.exe'" -ErrorAction SilentlyContinue | Where-Object {
  $_.CommandLine -and $_.CommandLine.IndexOf($Target,[StringComparison]::OrdinalIgnoreCase) -ge 0
})

foreach ($process in $matches) {
  Invoke-CimMethod -InputObject $process -MethodName Terminate -ErrorAction SilentlyContinue | Out-Null
}

Remove-Item -LiteralPath (Join-Path $modRoot 'runtime\brain.pid') -Force -ErrorAction SilentlyContinue
exit 0
