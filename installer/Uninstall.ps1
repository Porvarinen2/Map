param(
  [string]$ServerRoot = 'F:\SteamLibrary\steamapps\common\SCUM Server',
  [switch]$PurgeData
)
$ErrorActionPreference='Stop'

function Say([string]$m){ Write-Host "[TeslesNPCOverhaul] $m" -ForegroundColor Cyan }
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

function Restore-SharedSettingsIfUntouched([string]$dest,[string]$ueRoot){
  if(-not $ueRoot){ return }
  $backupDir=Join-Path $dest 'runtime\install-backup'
  $orig=Join-Path $backupDir 'UE4SS-settings.original.ini'
  $hashFile=Join-Path $backupDir 'UE4SS-settings.patched.sha256'
  $settings=Join-Path $ueRoot 'UE4SS-settings.ini'
  if(-not(Test-Path -LiteralPath $orig) -or -not(Test-Path -LiteralPath $hashFile) -or -not(Test-Path -LiteralPath $settings)){ return }
  $expected=(Get-Content -LiteralPath $hashFile -Raw).Trim()
  $current=(Get-FileHash -Algorithm SHA256 -LiteralPath $settings).Hash
  if($current -eq $expected){
    Copy-Item -LiteralPath $orig -Destination $settings -Force
    Say 'Restored pre-install UE4SS-settings.ini.'
  } else {
    Say 'UE4SS-settings.ini changed after install; leaving user/shared changes untouched.'
  }
}

function Disable-UE4SSMod([string]$modsDir,[string]$name){
  $json=Join-Path $modsDir 'mods.json'
  $txt=Join-Path $modsDir 'mods.txt'
  if(Test-Path -LiteralPath $json){
    try{
      $arr=@(Get-Content -LiteralPath $json -Raw | ConvertFrom-Json)
      $arr=@($arr | Where-Object { $_.mod_name -ne $name })
      ConvertTo-Json -InputObject $arr -Depth 20 | Set-Content -LiteralPath $json -Encoding UTF8
    }catch{ Say 'mods.json could not be safely updated; mods.txt remains authoritative.' }
  }
  if(Test-Path -LiteralPath $txt){
    $lines=@(Get-Content -LiteralPath $txt | Where-Object { $_ -notmatch ('^\s*'+[regex]::Escape($name)+'\s*:') })
    Set-Content -LiteralPath $txt -Value $lines -Encoding UTF8
  }
}

$ServerRoot=[IO.Path]::GetFullPath($ServerRoot).TrimEnd('\')
$dest=Join-Path $ServerRoot 'TeslesMods\TeslesNPCOverhaul'
$win64=Join-Path $ServerRoot 'SCUM\Binaries\Win64'
$ueRoot=if(Test-Path -LiteralPath (Join-Path $win64 'ue4ss\UE4SS.dll')){ Join-Path $win64 'ue4ss' } elseif(Test-Path -LiteralPath (Join-Path $win64 'UE4SS.dll')){ $win64 } else { $null }
$scriptRoot=if(Test-Path -LiteralPath (Join-Path $dest 'server')){ Join-Path $dest 'server' } else { Join-Path (Split-Path -Parent $PSScriptRoot) 'server' }

Say 'Stopping SCUM Server and Tesles NPC Brain...'
Invoke-Batch (Join-Path $scriptRoot 'ScumStop_NoBattlEye.bat')
$stopBrain=Join-Path $scriptRoot 'StopTeslesNPCBrain.bat'
if(Test-Path -LiteralPath $stopBrain){ Invoke-Batch $stopBrain }

if($ueRoot){
  Restore-SharedSettingsIfUntouched $dest $ueRoot
  $modsDir=Join-Path $ueRoot 'Mods'
  Disable-UE4SSMod $modsDir 'TeslesNPCOverhaul'
  $ueMod=Join-Path $modsDir 'TeslesNPCOverhaul'
  if(Test-Path -LiteralPath $ueMod){
    Say 'Removing only the Tesles UE4SS mod folder...'
    Remove-Item -LiteralPath $ueMod -Recurse -Force
  }
}

Say 'Restarting SCUM Server without Tesles NPC Overhaul...'
Invoke-Batch (Join-Path $scriptRoot 'ScumStart_NoBattlEye.bat')

if($PurgeData -and (Test-Path -LiteralPath $dest)){
  Say 'PurgeData requested. Scheduling Tesles package deletion after this script exits.'
  $cmd="ping 127.0.0.1 -n 3 >nul & rmdir /s /q `"$dest`""
  Start-Process cmd.exe -ArgumentList @('/d','/c',$cmd) -WindowStyle Hidden
}else{
  Say 'World save/config/backups retained in TeslesMods. Use -PurgeData to remove package data.'
}

Say 'Uninstall complete. Tesles UE4SS settings were restored when untouched; shared UE4SS and Node.js remain installed.'
