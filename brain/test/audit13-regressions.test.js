const test=require('node:test');
const assert=require('node:assert/strict');
const fs=require('fs');
const path=require('path');
const root=path.resolve(__dirname,'..','..');
const read=(rel)=>fs.readFileSync(path.join(root,rel),'utf8');

test('SCUM stop batch delegates process logic to a PowerShell file instead of fragile inline -Command',()=>{
  const bat=read('server/ScumStop_NoBattlEye.bat');
  assert.doesNotMatch(bat,/powershell[^\r\n]*-Command/i);
  assert.match(bat,/powershell[^\r\n]*-File\s+"%~dp0ScumStop_NoBattlEye\.ps1"/i);
  assert.ok(fs.existsSync(path.join(root,'server','ScumStop_NoBattlEye.ps1')));
});

test('SCUM stop PowerShell helper matches the configured executable by canonical full path and verifies termination',()=>{
  const ps=read('server/ScumStop_NoBattlEye.ps1');
  assert.match(ps,/SCUM\\Binaries\\Win64\\SCUMServer\.exe/i);
  assert.match(ps,/Get-CimInstance\s+Win32_Process/i);
  assert.match(ps,/ExecutablePath/i);
  assert.match(ps,/\[IO\.Path\]::GetFullPath/i);
  assert.match(ps,/Invoke-CimMethod[^\r\n]*Terminate/i);
  assert.match(ps,/still running/i);
});

test('brain stop batch also avoids inline PowerShell process-management commands',()=>{
  const bat=read('server/StopTeslesNPCBrain.bat');
  assert.doesNotMatch(bat,/powershell[^\r\n]*-Command/i);
  assert.match(bat,/powershell[^\r\n]*-File\s+"%~dp0StopTeslesNPCBrain\.ps1"/i);
  assert.ok(fs.existsSync(path.join(root,'server','StopTeslesNPCBrain.ps1')));
});
