param(
  [string]$SourceRoot,
  [string]$ServerRoot = 'F:\SteamLibrary\steamapps\common\SCUM Server',
  [switch]$DryRun,
  [switch]$SkipUE4SSDownload,
  [string]$UE4SSUrl = 'https://github.com/UE4SS-RE/RE-UE4SS/releases/download/experimental/UE4SS_v3.0.1-944-g0196ef29.zip',
  [string]$UE4SSSha256 = ''
)
$ErrorActionPreference='Stop'
$ProgressPreference='SilentlyContinue'
$PinnedUE4SSUrl='https://github.com/UE4SS-RE/RE-UE4SS/releases/download/experimental/UE4SS_v3.0.1-944-g0196ef29.zip'
$PinnedUE4SSSha256='b7be182458695a95d5d862d0a5f279e23fa5ef5b93566648e181191958ea45bd'

function Say([string]$m){ Write-Host "[TeslesNPCOverhaul] $m" -ForegroundColor Cyan }
function Write-Utf8NoBom([string]$path,[string]$text){
  $enc=New-Object System.Text.UTF8Encoding($false)
  [IO.File]::WriteAllText($path,$text,$enc)
}
function Ensure-Dir([string]$p){ if(-not(Test-Path -LiteralPath $p)){ New-Item -ItemType Directory -Path $p -Force | Out-Null } }
function Copy-Tree([string]$src,[string]$dst){
  if(-not(Test-Path -LiteralPath $src)){ throw "Copy source missing: $src" }
  $srcFull=[IO.Path]::GetFullPath($src).TrimEnd('\')
  $dstFull=[IO.Path]::GetFullPath($dst).TrimEnd('\')
  Ensure-Dir $dstFull
  $items=@(Get-ChildItem -LiteralPath $srcFull -Force -Recurse)
  $dirs=@($items | Where-Object { $_.PSIsContainer -and (($_.Attributes -band [IO.FileAttributes]::ReparsePoint) -eq 0) } | Sort-Object { $_.FullName.Length })
  foreach($item in $dirs){
    $rel=$item.FullName.Substring($srcFull.Length).TrimStart('\')
    if([string]::IsNullOrWhiteSpace($rel)){ continue }
    $target=Join-Path $dstFull $rel
    Ensure-Dir $target
  }
  foreach($item in @($items | Where-Object { -not $_.PSIsContainer })){
    if(($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0){ Say "Skipping reparse-point dependency entry: $($item.FullName)"; continue }
    if(-not(Test-Path -LiteralPath $item.FullName -PathType Leaf)){ Say "Skipping non-file dependency entry: $($item.FullName)"; continue }
    $rel=$item.FullName.Substring($srcFull.Length).TrimStart('\')
    $target=Join-Path $dstFull $rel
    Ensure-Dir (Split-Path -Parent $target)
    [IO.File]::Copy($item.FullName,$target,$true)
  }
}
function Invoke-DownloadWithRetry([string]$uri,[string]$outFile,[int]$attempts=3){
  $last=$null
  for($i=1;$i -le $attempts;$i++){
    try{
      if(Test-Path -LiteralPath $outFile){ Remove-Item -LiteralPath $outFile -Force -ErrorAction SilentlyContinue }
      Invoke-WebRequest -UseBasicParsing -Uri $uri -OutFile $outFile
      if(-not(Test-Path -LiteralPath $outFile -PathType Leaf) -or (Get-Item -LiteralPath $outFile).Length -le 0){ throw 'Downloaded file is empty.' }
      return
    }catch{
      $last=$_
      if($i -lt $attempts){ Say "Download attempt $i/$attempts failed; retrying..."; Start-Sleep -Seconds ([Math]::Min(2*$i,5)) }
    }
  }
  throw "Download failed after $attempts attempts: $uri :: $($last.Exception.Message)"
}
function Invoke-Batch([string]$bat,[int]$TimeoutSeconds=30){
  if(-not(Test-Path -LiteralPath $bat)){ throw "Required batch file missing: $bat" }
  $cmd=$env:ComSpec
  if([string]::IsNullOrWhiteSpace($cmd)){ $cmd=Join-Path $env:SystemRoot 'System32\cmd.exe' }
  $psi=New-Object System.Diagnostics.ProcessStartInfo
  $psi.FileName=$cmd
  $psi.Arguments='/d /c call "'+$bat+'"'
  $psi.UseShellExecute=$false
  $psi.CreateNoWindow=$false
  $proc=New-Object System.Diagnostics.Process
  $proc.StartInfo=$psi
  if(-not $proc.Start()){ $proc.Dispose(); throw "Could not start batch wrapper: $bat" }
  try{
    if(-not $proc.WaitForExit($TimeoutSeconds*1000)){
      try{ $proc.Kill() }catch{}
      throw "Batch wrapper timed out after $TimeoutSeconds seconds: $bat"
    }
    $exitCode=$proc.ExitCode
  } finally {
    $proc.Dispose()
  }
  if($exitCode -ne 0){ throw "Batch failed ($exitCode): $bat" }
}
function Get-ScumPidFile([string]$serverRoot){
  return (Join-Path $serverRoot 'TeslesMods\TeslesNPCOverhaul\runtime\scum-server.pid')
}
function Get-ManagedScumProcess([string]$serverRoot){
  $pidFile=Get-ScumPidFile $serverRoot
  if(-not(Test-Path -LiteralPath $pidFile -PathType Leaf)){ return $null }
  try{
    $managedPid=0
    if(-not([int]::TryParse((Get-Content -LiteralPath $pidFile -Raw).Trim(),[ref]$managedPid)) -or $managedPid -le 0){
      Remove-Item -LiteralPath $pidFile -Force -ErrorAction SilentlyContinue
      return $null
    }
    $proc=Get-Process -Id $managedPid -ErrorAction SilentlyContinue
    if($proc -and $proc.ProcessName -ieq 'SCUMServer'){ return $proc }
    Remove-Item -LiteralPath $pidFile -Force -ErrorAction SilentlyContinue
  }catch{}
  return $null
}
function Test-ScumRunning([string]$serverRoot){
  if(Get-ManagedScumProcess $serverRoot){ return $true }
  $targetExe=[IO.Path]::GetFullPath((Join-Path $serverRoot 'SCUM\Binaries\Win64\SCUMServer.exe'))
  $exact=@(Get-CimInstance Win32_Process -Filter "Name='SCUMServer.exe'" -ErrorAction SilentlyContinue | Where-Object { $_.ExecutablePath -and ([IO.Path]::GetFullPath($_.ExecutablePath) -ieq $targetExe) })
  if($exact.Count -gt 0){ return $true }
  $named=@(Get-Process -Name 'SCUMServer' -ErrorAction SilentlyContinue)
  if($named.Count -eq 1){ return $true }
  return $false
}
function Stop-Scum([string]$scriptsRoot,[string]$serverRoot){
  Say 'Stopping SCUM Server using packaged ScumStop_NoBattlEye.bat...'
  $oldRoot=$env:TESLES_SCUM_SERVER_ROOT
  $oldPidFile=$env:TESLES_SCUM_PID_FILE
  try{
    $env:TESLES_SCUM_SERVER_ROOT=$serverRoot
    $env:TESLES_SCUM_PID_FILE=Get-ScumPidFile $serverRoot
    Invoke-Batch (Join-Path $scriptsRoot 'ScumStop_NoBattlEye.bat')
  } finally {
    $env:TESLES_SCUM_SERVER_ROOT=$oldRoot
    $env:TESLES_SCUM_PID_FILE=$oldPidFile
  }
}
function Start-Scum([string]$scriptsRoot,[string]$serverRoot){
  Say 'Starting SCUM Server using packaged ScumStart_NoBattlEye.bat...'
  $pidFile=Get-ScumPidFile $serverRoot
  Ensure-Dir (Split-Path -Parent $pidFile)
  Remove-Item -LiteralPath $pidFile -Force -ErrorAction SilentlyContinue
  $oldRoot=$env:TESLES_SCUM_SERVER_ROOT
  $oldPidFile=$env:TESLES_SCUM_PID_FILE
  try{
    $env:TESLES_SCUM_SERVER_ROOT=$serverRoot
    $env:TESLES_SCUM_PID_FILE=$pidFile
    Invoke-Batch (Join-Path $scriptsRoot 'ScumStart_NoBattlEye.bat')
  } finally {
    $env:TESLES_SCUM_SERVER_ROOT=$oldRoot
    $env:TESLES_SCUM_PID_FILE=$oldPidFile
  }
  $exe=[IO.Path]::GetFullPath((Join-Path $serverRoot 'SCUM\Binaries\Win64\SCUMServer.exe'))
  if(-not(Test-Path -LiteralPath $pidFile -PathType Leaf)){ throw "SCUM start helper did not publish its PID: $pidFile" }
  $managedPid=0
  if(-not([int]::TryParse((Get-Content -LiteralPath $pidFile -Raw).Trim(),[ref]$managedPid)) -or $managedPid -le 0){ throw "SCUM start helper published an invalid PID: $pidFile" }
  $deadline=(Get-Date).AddSeconds(15)
  do{
    $proc=Get-Process -Id $managedPid -ErrorAction SilentlyContinue
    if($proc -and $proc.ProcessName -ieq 'SCUMServer'){
      Start-Sleep -Seconds 2
      $stable=Get-Process -Id $managedPid -ErrorAction SilentlyContinue
      if($stable -and $stable.ProcessName -ieq 'SCUMServer'){ return }
    }
    Start-Sleep -Milliseconds 500
  }while((Get-Date) -lt $deadline)
  throw "Started SCUMServer.exe PID $managedPid did not remain running: $exe"
}
function Test-BrainProcess([string]$modRoot){
  $target=[IO.Path]::GetFullPath((Join-Path $modRoot 'brain\src\server.js'))
  return [bool](Get-CimInstance Win32_Process -Filter "Name='node.exe'" -ErrorAction SilentlyContinue | Where-Object { $_.CommandLine -and $_.CommandLine.IndexOf($target,[StringComparison]::OrdinalIgnoreCase) -ge 0 } | Select-Object -First 1)
}
function Stop-Brain([string]$modRoot){
  $target=[IO.Path]::GetFullPath((Join-Path $modRoot 'brain\src\server.js'))
  $matches=@(Get-CimInstance Win32_Process -Filter "Name='node.exe'" -ErrorAction SilentlyContinue | Where-Object {
    $_.CommandLine -and $_.CommandLine.IndexOf($target,[StringComparison]::OrdinalIgnoreCase) -ge 0
  })
  foreach($process in $matches){
    Invoke-CimMethod -InputObject $process -MethodName Terminate -ErrorAction SilentlyContinue | Out-Null
  }
  if($matches.Count -gt 0){
    $deadline=(Get-Date).AddSeconds(5)
    do{
      Start-Sleep -Milliseconds 200
      $remaining=@(Get-CimInstance Win32_Process -Filter "Name='node.exe'" -ErrorAction SilentlyContinue | Where-Object {
        $_.CommandLine -and $_.CommandLine.IndexOf($target,[StringComparison]::OrdinalIgnoreCase) -ge 0
      })
      if($remaining.Count -eq 0){ break }
    }while((Get-Date) -lt $deadline)
    if($remaining.Count -gt 0){ throw "Tesles NPC Brain did not stop cleanly: $target" }
  }
  Remove-Item -LiteralPath (Join-Path $modRoot 'runtime\brain.pid') -Force -ErrorAction SilentlyContinue
}
function Ensure-Node([string]$serverRoot){
  $node=Get-Command node -ErrorAction SilentlyContinue
  if($node){
    try{
      $v=& $node.Source --version
      $major=[int](($v -replace '^v','').Split('.')[0])
      if($major -ge 18){ Say "Node.js $v found."; return $node.Source }
      Say "Node.js $v is too old; installing isolated Node.js 18 runtime automatically."
    }catch{ Say 'Existing node executable could not be validated; installing isolated Node.js 18 runtime automatically.' }
  }

  $depRoot=Join-Path $serverRoot 'TeslesMods\_Dependencies'
  $portableRoot=Join-Path $depRoot 'Node'
  $portableExe=Join-Path $portableRoot 'node.exe'
  if(Test-Path -LiteralPath $portableExe -PathType Leaf){
    try{
      $v=& $portableExe --version
      $major=[int](($v -replace '^v','').Split('.')[0])
      if($major -ge 18){ $env:Path=$portableRoot+';'+$env:Path; Say "Portable Node.js $v found."; return $portableExe }
    }catch{}
  }

  $nodeVersion='18.20.8'
  $nodeZipName='node-v18.20.8-win-x64.zip'
  $nodeBase='https://nodejs.org/dist/v18.20.8'
  Say "Node.js 18+ missing. Downloading pinned portable runtime: $nodeZipName"
  $tmp=Join-Path $env:TEMP ('TeslesNode-'+[guid]::NewGuid().ToString('N'))
  Ensure-Dir $tmp
  try{
    $zip=Join-Path $tmp $nodeZipName
    $sums=Join-Path $tmp 'SHASUMS256.txt'
    Invoke-DownloadWithRetry "$nodeBase/$nodeZipName" $zip
    Invoke-DownloadWithRetry "$nodeBase/SHASUMS256.txt" $sums
    $sumLine=Get-Content -LiteralPath $sums | Where-Object { $_ -match ('\s'+[regex]::Escape($nodeZipName)+'$') } | Select-Object -First 1
    if(-not $sumLine){ throw "Official Node.js checksum list did not contain $nodeZipName." }
    $expected=($sumLine.Trim() -split '\s+')[0].ToUpperInvariant()
    $actual=(Get-FileHash -Algorithm SHA256 -LiteralPath $zip).Hash.ToUpperInvariant()
    if($actual -ne $expected){ throw "Node.js archive checksum mismatch. Expected $expected, got $actual." }
    $extract=Join-Path $tmp 'extract'
    Expand-Archive -LiteralPath $zip -DestinationPath $extract -Force
    $payload=Join-Path $extract 'node-v18.20.8-win-x64'
    $payloadExe=Join-Path $payload 'node.exe'
    if(-not(Test-Path -LiteralPath $payloadExe -PathType Leaf)){ throw 'Downloaded Node.js archive did not contain node.exe.' }
    if(Test-Path -LiteralPath $portableRoot){ Remove-Item -LiteralPath $portableRoot -Recurse -Force }
    Ensure-Dir $depRoot
    Copy-Tree $payload $portableRoot
  } finally {
    Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
  }
  if(-not(Test-Path -LiteralPath $portableExe -PathType Leaf)){ throw 'Portable Node.js installation verification failed.' }
  $v=& $portableExe --version
  $major=[int](($v -replace '^v','').Split('.')[0])
  if($major -lt 18){ throw "Node.js 18+ required; portable install returned $v" }
  $env:Path=$portableRoot+';'+$env:Path
  Say "Portable Node.js $v installed automatically at $portableRoot"
  return $portableExe
}
function Expand-UE4SSArchiveSafely([string]$zipPath,[string]$destination){
  Add-Type -AssemblyName System.IO.Compression.FileSystem
  Ensure-Dir $destination
  $separator=[IO.Path]::DirectorySeparatorChar
  $destBase=[IO.Path]::GetFullPath($destination).TrimEnd($separator)
  $destPrefix=[string]::Concat($destBase,$separator)
  $archive=[IO.Compression.ZipFile]::OpenRead($zipPath)
  try{
    foreach($entry in $archive.Entries){
      $rel=$entry.FullName.Replace('/',[string]$separator)
      if([string]::IsNullOrWhiteSpace($rel)){ continue }
      if([IO.Path]::IsPathRooted($rel)){ throw "Unsafe absolute path in UE4SS archive: $($entry.FullName)" }
      $target=[IO.Path]::GetFullPath((Join-Path $destBase $rel))
      if(-not $target.StartsWith($destPrefix,[StringComparison]::OrdinalIgnoreCase)){ throw "Unsafe path traversal in UE4SS archive: $($entry.FullName)" }
      if([string]::IsNullOrEmpty($entry.Name) -or $entry.FullName.EndsWith('/')){ Ensure-Dir $target; continue }
      Ensure-Dir (Split-Path -Parent $target)
      $input=$entry.Open()
      $output=[IO.File]::Open($target,[IO.FileMode]::Create,[IO.FileAccess]::Write,[IO.FileShare]::None)
      try{ $input.CopyTo($output) } finally { $output.Dispose(); $input.Dispose() }
    }
  } finally { $archive.Dispose() }
}
function Copy-ExtractedUE4SSTree([string]$source,[string]$destination){
  $src=[IO.Path]::GetFullPath($source).TrimEnd('\\')
  $dst=[IO.Path]::GetFullPath($destination).TrimEnd('\\')
  Ensure-Dir $dst
  foreach($dir in @(Get-ChildItem -LiteralPath $src -Directory -Force -Recurse | Sort-Object { $_.FullName.Length })){
    $rel=$dir.FullName.Substring($src.Length).TrimStart('\\')
    if($rel){ Ensure-Dir (Join-Path $dst $rel) }
  }
  foreach($file in @(Get-ChildItem -LiteralPath $src -File -Force -Recurse)){
    $rel=$file.FullName.Substring($src.Length).TrimStart('\\')
    $target=Join-Path $dst $rel
    Ensure-Dir (Split-Path -Parent $target)
    [IO.File]::Copy($file.FullName,$target,$true)
  }
}
function Get-UE4SSRoot([string]$win64){
  if(Test-Path -LiteralPath (Join-Path $win64 'ue4ss\UE4SS.dll')){ return (Join-Path $win64 'ue4ss') }
  if(Test-Path -LiteralPath (Join-Path $win64 'UE4SS.dll')){ return $win64 }
  return $null
}
function Test-UE4SSCompatible([string]$root){
  $dll=Join-Path $root 'UE4SS.dll'
  if(-not(Test-Path -LiteralPath $dll)){ return $false }
  try{
    $v=[Diagnostics.FileVersionInfo]::GetVersionInfo($dll).FileVersion
    if($v -match '^(\d+)\.(\d+)\.(\d+)'){
      $major=[int]$matches[1];$minor=[int]$matches[2];$patch=[int]$matches[3]
      return ($major -gt 3) -or ($major -eq 3 -and (($minor -gt 0) -or ($minor -eq 0 -and $patch -ge 1)))
    }
  }catch{}
  return Test-Path -LiteralPath (Join-Path $root '.tesles-ue4ss-compatible')
}
function Ensure-UE4SS([string]$win64){
  $existing=Get-UE4SSRoot $win64
  if($existing){
    if(-not(Test-UE4SSCompatible $existing)){ throw "Existing UE4SS at $existing is too old/unknown for delayed game-thread APIs. Update/remove it, or let this installer install the pinned compatible build." }
    Say "Compatible existing UE4SS found at $existing; shared files will be patched minimally."; return $existing
  }
  if($SkipUE4SSDownload){ throw 'UE4SS is missing and -SkipUE4SSDownload was requested.' }

  $cleanUrl=$UE4SSUrl.Trim().Trim([char[]]@([char]0xFEFF,[char]0x200B))
  $expectedHash=$UE4SSSha256.Trim()
  if([string]::IsNullOrWhiteSpace($expectedHash) -and $cleanUrl -eq $PinnedUE4SSUrl){ $expectedHash=$PinnedUE4SSSha256 }
  Say "UE4SS missing. Downloading pinned SCUM-tested build: $cleanUrl"
  $tmp=Join-Path $env:TEMP ('TeslesUE4SS-'+[guid]::NewGuid().ToString('N'))
  Ensure-Dir $tmp
  try{
    $zip=Join-Path $tmp 'ue4ss.zip'
    Invoke-DownloadWithRetry $cleanUrl $zip
    if(-not([string]::IsNullOrWhiteSpace($expectedHash))){
      $actualHash=(Get-FileHash -Algorithm SHA256 -LiteralPath $zip).Hash
      if($actualHash -ine $expectedHash){ throw "UE4SS archive checksum mismatch. Expected $expectedHash, got $actualHash." }
    }
    $extract=Join-Path $tmp 'extract'
    Expand-UE4SSArchiveSafely $zip $extract
    $dll=Get-ChildItem -LiteralPath $extract -Recurse -File -Filter UE4SS.dll | Select-Object -First 1
    if(-not $dll){ throw 'Pinned UE4SS archive did not contain UE4SS.dll.' }
    $archiveRoot=$dll.Directory.FullName
    if($dll.Directory.Name -ieq 'ue4ss'){ $archiveRoot=$dll.Directory.Parent.FullName }

    $stagedRoot=if($dll.Directory.Name -ieq 'ue4ss'){ Join-Path $archiveRoot 'ue4ss' } else { $archiveRoot }
    $stagedRequired=@(
      (Join-Path $archiveRoot 'dwmapi.dll'),
      (Join-Path $stagedRoot 'UE4SS.dll'),
      (Join-Path $stagedRoot 'UE4SS-settings.ini'),
      (Join-Path $stagedRoot 'Mods')
    )
    foreach($requiredPath in $stagedRequired){
      if(-not(Test-Path -LiteralPath $requiredPath)){ throw "Downloaded UE4SS archive is incomplete; required path missing before install: $requiredPath" }
    }
    Copy-ExtractedUE4SSTree $archiveRoot $win64
  } finally {
    Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
  }
  $installed=Get-UE4SSRoot $win64
  if(-not $installed){ throw 'UE4SS runtime payload verification failed: UE4SS.dll is missing after copy.' }
  $required=@(
    (Join-Path $win64 'dwmapi.dll'),
    (Join-Path $installed 'UE4SS.dll'),
    (Join-Path $installed 'UE4SS-settings.ini'),
    (Join-Path $installed 'Mods')
  )
  foreach($requiredPath in $required){
    if(-not(Test-Path -LiteralPath $requiredPath)){ throw "UE4SS runtime payload verification failed; required path missing: $requiredPath" }
  }
  Set-Content -LiteralPath (Join-Path $installed '.tesles-ue4ss-compatible') -Value $cleanUrl -Encoding UTF8
  Say "UE4SS runtime payload installed and verified at $installed"
  return $installed
}
function Set-IniSectionKey([string]$text,[string]$section,[string]$key,[string]$value){
  $lines=[System.Collections.Generic.List[string]]::new()
  foreach($line in ($text -split "\r?\n")){ [void]$lines.Add($line) }
  $sectionIndex=-1
  for($i=0;$i -lt $lines.Count;$i++){
    if($lines[$i] -match ('^\s*\['+[regex]::Escape($section)+'\]\s*$')){ $sectionIndex=$i; break }
  }
  if($sectionIndex -lt 0){
    if($lines.Count -gt 0 -and $lines[$lines.Count-1] -ne ''){ [void]$lines.Add('') }
    [void]$lines.Add("[$section]")
    [void]$lines.Add("$key = $value")
    return ($lines -join "`r`n")
  }
  $end=$lines.Count
  for($i=$sectionIndex+1;$i -lt $lines.Count;$i++){
    if($lines[$i] -match '^\s*\[[^\]]+\]\s*$'){ $end=$i; break }
  }
  for($i=$sectionIndex+1;$i -lt $end;$i++){
    if($lines[$i] -match ('^\s*'+[regex]::Escape($key)+'\s*=')){
      $lines[$i]="$key = $value"
      return ($lines -join "`r`n")
    }
  }
  $lines.Insert($end,"$key = $value")
  return ($lines -join "`r`n")
}
function Patch-UE4SSSettings([string]$settings){
  if(-not(Test-Path -LiteralPath $settings)){ throw "UE4SS-settings.ini missing: $settings" }
  $t=Get-Content -LiteralPath $settings -Raw
  $t=Set-IniSectionKey $t 'EngineVersionOverride' 'MajorVersion' '4'
  $t=Set-IniSectionKey $t 'EngineVersionOverride' 'MinorVersion' '27'
  $t=Set-IniSectionKey $t 'General' 'bUseUObjectArrayCache' 'false'
  $t=Set-IniSectionKey $t 'General' 'DefaultExecuteInGameThreadMethod' 'EngineTick'
  $t=Set-IniSectionKey $t 'Hooks' 'HookProcessInternal' '1'
  $t=Set-IniSectionKey $t 'Hooks' 'HookProcessLocalScriptFunction' '1'
  $t=Set-IniSectionKey $t 'Hooks' 'HookEngineTick' '1'
  Set-Content -LiteralPath $settings -Value $t -Encoding UTF8
}
function Enable-UE4SSMod([string]$modsDir,[string]$name){
  $json=Join-Path $modsDir 'mods.json'
  $txt=Join-Path $modsDir 'mods.txt'
  $lines=@()
  if(Test-Path -LiteralPath $txt){ $lines=@(Get-Content -LiteralPath $txt) }
  $lines=@($lines | Where-Object { $_ -notmatch ('^\s*'+[regex]::Escape($name)+'\s*:') })
  $lines+=($name+' : 1')
  Set-Content -LiteralPath $txt -Value $lines -Encoding UTF8
  if(Test-Path -LiteralPath $json){
    try{
      $arr=@(Get-Content -LiteralPath $json -Raw | ConvertFrom-Json)
      $arr=@($arr | Where-Object { $_.mod_name -ne $name })
      $arr+=@([pscustomobject]@{mod_name=$name;mod_enabled=$true})
      ConvertTo-Json -InputObject $arr -Depth 20 | Set-Content -LiteralPath $json -Encoding UTF8
    }catch{ Say 'mods.json exists but could not be safely updated; mods.txt remains authoritative.' }
  }
  return $txt
}
function Escape-LuaLong([string]$s){ return $s -replace '\]\]','] ]' }
function Write-RuntimeConfig([string]$template,[string]$out,[string]$eventFile,[string]$commandFile,[string]$stateFile,[string]$probeFile,[string]$compatProfileFile,[bool]$takeoverRequested,[string]$takeoverMode,[bool]$adoptUnmanaged,[string]$scumBuild){
  if($takeoverMode -notin @('auto','probe','full','observe')){ throw "Invalid takeover mode: $takeoverMode" }
  $t=Get-Content -LiteralPath $template -Raw
  $t=$t.Replace('__EVENT_FILE__',(Escape-LuaLong $eventFile)).
        Replace('__COMMAND_FILE__',(Escape-LuaLong $commandFile)).
        Replace('__STATE_FILE__',(Escape-LuaLong $stateFile)).
        Replace('__PROBE_FILE__',(Escape-LuaLong $probeFile)).
        Replace('__COMPAT_PROFILE_FILE__',(Escape-LuaLong $compatProfileFile)).
        Replace('__TAKEOVER_REQUESTED__',($(if($takeoverRequested){'true'}else{'false'}))).
        Replace('__TAKEOVER_MODE__',$takeoverMode).
        Replace('__ADOPT_UNMANAGED__',($(if($adoptUnmanaged){'true'}else{'false'}))).
        Replace('__SCUM_BUILD__',$scumBuild)
  Set-Content -LiteralPath $out -Value $t -Encoding UTF8
}
function Assert-PackageComplete([string]$dest){
  # Fail before touching the server if the package is missing a runtime component.
  $required=@(
    'brain\config\default.json','brain\config\population.json','brain\config\body-profiles.json',
    'brain\src\director\worldPopulation.js','brain\src\virtual\materializationCoordinator.js',
    'brain\src\bridge\commandBroker.js','brain\src\director\spawnPolicy.js',
    'ue4ss\TeslesNPCOverhaul\scripts\modules\spawn_adapter.lua',
    'ue4ss\TeslesNPCOverhaul\scripts\modules\weapon_adapter.lua',
    'ue4ss\TeslesNPCOverhaul\scripts\modules\compat_profile.lua'
  )
  $missing=@($required | Where-Object { -not (Test-Path -LiteralPath (Join-Path $dest $_)) })
  if($missing.Count -gt 0){ throw "Incomplete TeslesNPCOverhaul package; missing: $($missing -join ', ')" }
}
function Get-ScumBuild([string]$ServerRoot){
  $exe=Join-Path $ServerRoot 'SCUM\Binaries\Win64\SCUMServer.exe'
  if(Test-Path -LiteralPath $exe){
    try{ return [string](Get-Item -LiteralPath $exe).VersionInfo.ProductVersion }catch{ return 'unknown' }
  }
  return 'unknown'
}
function Get-BrainEndpoint([string]$modRoot){
  $installed=Get-Content -LiteralPath (Join-Path $modRoot 'brain\config\installed.json') -Raw | ConvertFrom-Json
  $userPath=Join-Path $modRoot 'brain\config\user.json'
  $user=$null
  if(Test-Path -LiteralPath $userPath){ $user=Get-Content -LiteralPath $userPath -Raw | ConvertFrom-Json }
  $listenHost=if($user -and $user.server -and $user.server.host){ [string]$user.server.host } else { [string]$installed.server.host }
  $port=if($user -and $user.server -and $user.server.port){ [int]$user.server.port } else { [int]$installed.server.port }
  if($port -lt 1 -or $port -gt 65535){ throw "Invalid brain server.port: $port" }
  $probeHost=if($listenHost -in @('0.0.0.0','::','[::]','*')){ '127.0.0.1' } else { $listenHost }
  $baseUri="http://$probeHost`:$port"
  return [pscustomobject]@{ BaseUri=$baseUri; HealthUri=($baseUri+'/api/health'); SnapshotUri=($baseUri+'/api/snapshot'); Host=$listenHost; Port=$port }
}
function Start-Brain([string]$modRoot,[string]$nodeExe){
  Say 'Starting Tesles NPC Brain + map viewer...'
  $brainEndpoint=Get-BrainEndpoint $modRoot
  $launcher=Join-Path $modRoot 'brain\tools\launchDetached.js'
  if(-not(Test-Path -LiteralPath $launcher -PathType Leaf)){ throw "Brain detached launcher missing: $launcher" }
  if([string]::IsNullOrWhiteSpace($nodeExe) -or -not(Test-Path -LiteralPath $nodeExe -PathType Leaf)){ throw "Validated Node.js executable missing: $nodeExe" }
  & $nodeExe $launcher
  $launcherExit=$LASTEXITCODE
  if($launcherExit -ne 0){ throw "Brain detached launcher failed with code $launcherExit. Check runtime\brain.log." }
  $deadline=(Get-Date).AddSeconds(15)
  do{
    Start-Sleep -Milliseconds 500
    try{
      $h=Invoke-RestMethod -Uri $brainEndpoint.HealthUri -TimeoutSec 2
      if($h.brain -and (Test-BrainProcess $modRoot)){ return $brainEndpoint }
    }catch{}
  }while((Get-Date) -lt $deadline)
  $log=Join-Path $modRoot 'runtime\brain.log'
  $tail=''
  if(Test-Path -LiteralPath $log){
    try{ $tail=((Get-Content -LiteralPath $log -Tail 12 -ErrorAction Stop) -join ' | ') }catch{}
  }
  if($tail){ throw "Brain/map viewer did not become healthy within 15 seconds at $($brainEndpoint.HealthUri). brain.log tail: $tail" }
  throw "Brain/map viewer did not become healthy within 15 seconds at $($brainEndpoint.HealthUri)."
}

function Wait-BridgeCompatibility($brainEndpoint){
  Say 'Waiting for UE4SS bridge scheduler capability...'
  $deadline=(Get-Date).AddSeconds(35)
  do{
    Start-Sleep -Milliseconds 750
    try{
      $s=Invoke-RestMethod -Uri $brainEndpoint.SnapshotUri -TimeoutSec 2
      if($s.capabilities.bridge_scheduler.ok -eq $true){ Say 'UE4SS bridge scheduler capability verified.'; return }
      if($s.capabilities.bridge_scheduler -and $s.capabilities.bridge_scheduler.ok -eq $false){ throw "UE4SS bridge reported incompatible scheduler: $($s.capabilities.bridge_scheduler.detail)" }
    }catch{
      if($_.Exception.Message -like 'UE4SS bridge reported*'){ throw }
    }
  }while((Get-Date) -lt $deadline)
  throw 'UE4SS bridge did not report scheduler compatibility within 35 seconds. Check UE4SS.log/probe diagnostics.'
}

function Refresh-SharedSettingsBaseline([string]$settings,[string]$sharedBackup){
  if(-not(Test-Path -LiteralPath $settings)){ return }
  Ensure-Dir $sharedBackup
  $origSettings=Join-Path $sharedBackup 'UE4SS-settings.original.ini'
  $patchedHashFile=Join-Path $sharedBackup 'UE4SS-settings.patched.sha256'
  $refresh=-not(Test-Path -LiteralPath $origSettings)
  if(-not $refresh){
    if(Test-Path -LiteralPath $patchedHashFile){
      try{
        $previousPatched=(Get-Content -LiteralPath $patchedHashFile -Raw).Trim()
        $currentHash=(Get-FileHash -Algorithm SHA256 -LiteralPath $settings).Hash
        if($previousPatched -and $currentHash -ne $previousPatched){
          Say 'UE4SS-settings.ini changed since last install; preserving current shared settings as the new uninstall baseline.'
          $refresh=$true
        }
      }catch{ $refresh=$true }
    } else { $refresh=$true }
  }
  if($refresh){ Copy-Item -LiteralPath $settings -Destination $origSettings -Force }
}
function Backup-File([string]$file,[string]$txn,[string]$name){
  if(Test-Path -LiteralPath $file){ Copy-Item -LiteralPath $file -Destination (Join-Path $txn $name) -Force; return $true }
  return $false
}
function Restore-File([string]$file,[string]$txn,[string]$name,[bool]$existed){
  $b=Join-Path $txn $name
  if($existed -and (Test-Path -LiteralPath $b)){
    Ensure-Dir (Split-Path -Parent $file)
    Copy-Item -LiteralPath $b -Destination $file -Force
  } elseif(-not $existed -and (Test-Path -LiteralPath $file)){
    Remove-Item -LiteralPath $file -Force
  }
}

if([string]::IsNullOrWhiteSpace($SourceRoot)){ throw '-SourceRoot is required. Run install.bat from the extracted package.' }
$SourceRoot=$SourceRoot.Trim().Trim('"')
$SourceRoot=(Resolve-Path -LiteralPath $SourceRoot).Path.TrimEnd('\')
$ServerRoot=[IO.Path]::GetFullPath($ServerRoot).TrimEnd('\')
$exe=Join-Path $ServerRoot 'SCUM\Binaries\Win64\SCUMServer.exe'
if(-not(Test-Path -LiteralPath $exe -PathType Leaf)){ throw "Invalid server root; SCUMServer.exe missing: $exe" }

$dest=Join-Path $ServerRoot 'TeslesMods\TeslesNPCOverhaul'
$win64=Join-Path $ServerRoot 'SCUM\Binaries\Win64'
$sourceScripts=Join-Path $SourceRoot 'server'
$backupRoot=Join-Path $ServerRoot 'TeslesMods\TeslesNPCOverhaul_Backups'
$txn=Join-Path $env:TEMP ('TeslesNPC-txn-'+[guid]::NewGuid().ToString('N'))
Ensure-Dir $txn

Say "Source: $SourceRoot"
Say "Server: $ServerRoot"
Say "SCUM executable: $exe"
if($DryRun){ Say 'DRY RUN: paths validated; no changes.'; exit 0 }

$backup=$null
$ueRoot=$null
$ueMod=$null
$settings=$null
$modsJson=$null
$modsTxt=$null
$settingsExisted=$false
$modsJsonExisted=$false
$modsTxtExisted=$false
$previousUeMod=$false
$installSucceeded=$false
$scumWasRunning=Test-ScumRunning $ServerRoot

try{
  Stop-Scum $sourceScripts $ServerRoot
  if(Test-Path -LiteralPath $dest){ Stop-Brain $dest } else { Stop-Brain $SourceRoot }
  $nodeExe=Ensure-Node $ServerRoot

  if(Test-Path -LiteralPath $dest){
    Ensure-Dir $backupRoot
    $stamp=Get-Date -Format 'yyyyMMdd-HHmmss'
    $backup=Join-Path $backupRoot $stamp
    Say "Backing up previous mod to $backup"
    Copy-Tree $dest $backup
  }

  if($SourceRoot -ne $dest){
    if(Test-Path -LiteralPath $dest){ Remove-Item -LiteralPath $dest -Recurse -Force }
    Copy-Tree $SourceRoot $dest
  }

  Assert-PackageComplete $dest

  if($backup -and (Test-Path -LiteralPath (Join-Path $backup 'runtime'))){
    # world.json carries persistent NPC identities, squads and deaths: it is restored,
    # never overwritten. Schema migration happens at runtime, not by deleting the save.
    Say 'Restoring persistent runtime/world data from previous installation.'
    Copy-Tree (Join-Path $backup 'runtime') (Join-Path $dest 'runtime')
  }
  $userCfg=Join-Path $dest 'brain\config\user.json'
  if($backup -and (Test-Path -LiteralPath (Join-Path $backup 'brain\config\user.json'))){
    Say 'Restoring user.json configuration overrides from previous installation.'
    Copy-Item -LiteralPath (Join-Path $backup 'brain\config\user.json') -Destination $userCfg -Force
  } elseif($backup -and (Test-Path -LiteralPath (Join-Path $backup 'brain\config\installed.json'))){
    Say 'Migrating previous installed.json user-editable settings into user.json.'
    $oldCfg=Get-Content -LiteralPath (Join-Path $backup 'brain\config\installed.json') -Raw | ConvertFrom-Json
    $override=[ordered]@{}
    foreach($name in @('server','world','map','features','simulation','population')){ if($oldCfg.PSObject.Properties.Name -contains $name){ $override[$name]=$oldCfg.$name } }
    Write-Utf8NoBom $userCfg ($override | ConvertTo-Json -Depth 30)
  } elseif(-not(Test-Path -LiteralPath $userCfg)){
    Write-Utf8NoBom $userCfg '{}'
  }

  $runtime=Join-Path $dest 'runtime'
  Ensure-Dir $runtime
  $ueRoot=Ensure-UE4SS $win64
  Ensure-Dir (Join-Path $ueRoot 'Mods')
  $ueMod=Join-Path $ueRoot 'Mods\TeslesNPCOverhaul'
  if(Test-Path -LiteralPath $ueMod){
    $previousUeMod=$true
    Copy-Tree $ueMod (Join-Path $txn 'old-ue-mod')
  }

  $settings=Join-Path $ueRoot 'UE4SS-settings.ini'
  $modsJson=Join-Path $ueRoot 'Mods\mods.json'
  $modsTxt=Join-Path $ueRoot 'Mods\mods.txt'
  $settingsExisted=Backup-File $settings $txn 'UE4SS-settings.ini'
  $modsJsonExisted=Backup-File $modsJson $txn 'mods.json'
  $modsTxtExisted=Backup-File $modsTxt $txn 'mods.txt'

  $sharedBackup=Join-Path $dest 'runtime\install-backup'
  Refresh-SharedSettingsBaseline $settings $sharedBackup
  Patch-UE4SSSettings $settings
  if(Test-Path -LiteralPath $settings){ (Get-FileHash -Algorithm SHA256 -LiteralPath $settings).Hash | Set-Content -LiteralPath (Join-Path $sharedBackup 'UE4SS-settings.patched.sha256') -Encoding ASCII }

  if(Test-Path -LiteralPath $ueMod){ Remove-Item -LiteralPath $ueMod -Recurse -Force }
  Copy-Tree (Join-Path $dest 'ue4ss\TeslesNPCOverhaul') $ueMod
  Get-ChildItem -LiteralPath $ueMod -Recurse -Filter enabled.txt -ErrorAction SilentlyContinue | Remove-Item -Force
  [void](Enable-UE4SSMod (Join-Path $ueRoot 'Mods') 'TeslesNPCOverhaul')

  $eventFile=Join-Path $runtime 'scum-events.log'
  $commandFile=Join-Path $runtime 'scum-commands.log'
  $stateFile=Join-Path $runtime 'scum-state.log'
  $probeFile=Join-Path $runtime 'probe-report.log'
  $compatProfileFile=Join-Path $runtime 'compat-profile.json'
  foreach($f in @($eventFile,$commandFile,$stateFile,$probeFile)){
    if(-not(Test-Path -LiteralPath $f)){ New-Item -ItemType File -Path $f -Force | Out-Null }
  }

  $defaultCfg=Get-Content -LiteralPath (Join-Path $dest 'brain\config\default.json') -Raw | ConvertFrom-Json
  $defaultCfg.ipc.eventsFile=$eventFile
  $defaultCfg.ipc.commandsFile=$commandFile
  $defaultCfg.ipc.stateFile=$stateFile
  $defaultCfg.ipc.offsetFile=(Join-Path $runtime 'ipc-offset.json')
  Write-Utf8NoBom (Join-Path $dest 'brain\config\installed.json') ($defaultCfg | ConvertTo-Json -Depth 30)
  $userCfgObj=@{}
  if(Test-Path -LiteralPath $userCfg){ $userCfgObj=Get-Content -LiteralPath $userCfg -Raw | ConvertFrom-Json }
  $takeoverRequested=if($userCfgObj.features -and $null -ne $userCfgObj.features.takeoverRequested){ [bool]$userCfgObj.features.takeoverRequested } else { [bool]$defaultCfg.features.takeoverRequested }
  $takeoverMode=if($userCfgObj.features -and $userCfgObj.features.takeoverMode){ [string]$userCfgObj.features.takeoverMode } else { [string]$defaultCfg.features.takeoverMode }
  $adoptUnmanaged=if($userCfgObj.population -and $null -ne $userCfgObj.population.adoptUnmanagedNpc){ [bool]$userCfgObj.population.adoptUnmanagedNpc } else { [bool]$defaultCfg.population.adoptUnmanagedNpc }
  Write-RuntimeConfig (Join-Path $ueMod 'scripts\runtime_config.lua.template') (Join-Path $ueMod 'scripts\runtime_config.lua') $eventFile $commandFile $stateFile $probeFile $compatProfileFile $takeoverRequested $takeoverMode $adoptUnmanaged (Get-ScumBuild $ServerRoot)
  Set-Content -LiteralPath (Join-Path $runtime 'installed-server-root.txt') -Value $ServerRoot -Encoding UTF8

  $brainEndpoint=Start-Brain $dest $nodeExe
  Start-Scum (Join-Path $dest 'server') $ServerRoot
  Wait-BridgeCompatibility $brainEndpoint
  $installSucceeded=$true
  try{ Start-Process $brainEndpoint.BaseUri }catch{}
  Say 'INSTALL COMPLETE.'
  Say "Map viewer: $($brainEndpoint.BaseUri)"
}
catch{
  Write-Host "[TeslesNPCOverhaul] ERROR: $($_.Exception.Message)" -ForegroundColor Red
  Write-Host '[TeslesNPCOverhaul] Rolling back every owned/shared change made by this attempt...' -ForegroundColor Yellow
  try{ Stop-Brain $dest }catch{}
  try{
    if($ueMod){
      if(Test-Path -LiteralPath $ueMod){ Remove-Item -LiteralPath $ueMod -Recurse -Force }
      if($previousUeMod -and (Test-Path -LiteralPath (Join-Path $txn 'old-ue-mod'))){ Copy-Tree (Join-Path $txn 'old-ue-mod') $ueMod }
    }
  }catch{}
  try{
    if($settings){ Restore-File $settings $txn 'UE4SS-settings.ini' $settingsExisted }
    if($modsJson){ Restore-File $modsJson $txn 'mods.json' $modsJsonExisted }
    if($modsTxt){ Restore-File $modsTxt $txn 'mods.txt' $modsTxtExisted }
  }catch{}
  try{
    if($backup){
      if(Test-Path -LiteralPath $dest){ Remove-Item -LiteralPath $dest -Recurse -Force }
      Copy-Tree $backup $dest
    } elseif($SourceRoot -ne $dest -and (Test-Path -LiteralPath $dest)){
      Remove-Item -LiteralPath $dest -Recurse -Force
    }
  }catch{}
  if($scumWasRunning){ try{ Start-Scum $sourceScripts $ServerRoot }catch{} }
  throw
}
finally{
  Remove-Item -LiteralPath $txn -Recurse -Force -ErrorAction SilentlyContinue
}
if($installSucceeded){ exit 0 }
exit 1
