param([string]$PackageRoot)
$ErrorActionPreference='Stop'
if([string]::IsNullOrWhiteSpace($PackageRoot)){ throw '-PackageRoot is required.' }
$PackageRoot=$PackageRoot.Trim().Trim('"')
$PackageRoot=[IO.Path]::GetFullPath($PackageRoot).TrimEnd('\')
$runtime=Join-Path $PackageRoot 'runtime'
if(-not(Test-Path $runtime)){New-Item -ItemType Directory -Path $runtime -Force|Out-Null}
$stamp=Get-Date -Format 'yyyyMMdd-HHmmss'
$tmp=Join-Path $env:TEMP ('TeslesNPCDiag-'+$stamp+'-'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tmp -Force|Out-Null
function Copy-Tail([string]$src,[string]$name,[int]$lines=3000){if(Test-Path $src){Get-Content -LiteralPath $src -Tail $lines -ErrorAction SilentlyContinue|Set-Content -LiteralPath (Join-Path $tmp $name) -Encoding UTF8}}
function Get-BrainSnapshotUri([string]$root){
  $installedPath=Join-Path $root 'brain\config\installed.json'
  $userPath=Join-Path $root 'brain\config\user.json'
  $listenHost='127.0.0.1';$port=17381
  if(Test-Path -LiteralPath $installedPath){$installed=Get-Content -LiteralPath $installedPath -Raw|ConvertFrom-Json;if($installed.server.host){$listenHost=[string]$installed.server.host};if($installed.server.port){$port=[int]$installed.server.port}}
  if(Test-Path -LiteralPath $userPath){$user=Get-Content -LiteralPath $userPath -Raw|ConvertFrom-Json;if($user.server -and $user.server.host){$listenHost=[string]$user.server.host};if($user.server -and $user.server.port){$port=[int]$user.server.port}}
  $probeHost=if($listenHost -in @('0.0.0.0','::','[::]','*')){'127.0.0.1'}else{$listenHost}
  return "http://$probeHost`:$port/api/snapshot"
}
Copy-Tail (Join-Path $runtime 'probe-report.log') 'probe-report.log' 10000
Copy-Tail (Join-Path $runtime 'scum-events.log') 'scum-events-tail.log' 5000
Copy-Tail (Join-Path $runtime 'scum-commands.log') 'scum-commands-tail.log' 5000
Copy-Tail (Join-Path $runtime 'scum-state.log') 'scum-state.log' 10000
Copy-Tail (Join-Path $runtime 'brain.log') 'brain-tail.log' 5000
if(Test-Path (Join-Path $runtime 'world.json')){Copy-Item (Join-Path $runtime 'world.json') (Join-Path $tmp 'world.json') -Force}
try{$snapshotUri=Get-BrainSnapshotUri $PackageRoot;Invoke-RestMethod -Uri $snapshotUri -TimeoutSec 5|ConvertTo-Json -Depth 30|Set-Content (Join-Path $tmp 'api-snapshot.json') -Encoding UTF8}catch{Set-Content (Join-Path $tmp 'api-error.txt') $_.Exception.Message}
$serverRootFile=Join-Path $runtime 'installed-server-root.txt'
if(Test-Path $serverRootFile){$serverRoot=(Get-Content $serverRootFile -Raw).Trim();$win64=Join-Path $serverRoot 'SCUM\Binaries\Win64';$logs=@((Join-Path $win64 'UE4SS.log'),(Join-Path $win64 'ue4ss\UE4SS.log'));foreach($l in $logs){if(Test-Path $l){Copy-Tail $l 'UE4SS-tail.log' 5000;break}}}
Get-CimInstance Win32_Process -ErrorAction SilentlyContinue|Where-Object{$_.Name -in @('SCUMServer.exe','node.exe')}|Select-Object Name,ProcessId,ExecutablePath,CommandLine|Format-List|Out-String|Set-Content (Join-Path $tmp 'processes.txt') -Encoding UTF8
$zip=Join-Path $runtime ('TeslesNPC_Diagnostics_'+$stamp+'.zip')
if(Test-Path $zip){Remove-Item $zip -Force}
Compress-Archive -Path (Join-Path $tmp '*') -DestinationPath $zip -Force
Remove-Item $tmp -Recurse -Force
Write-Host "Diagnostics created: $zip" -ForegroundColor Green
Start-Process explorer.exe -ArgumentList @('/select,',('"'+$zip+'"')) -ErrorAction SilentlyContinue
