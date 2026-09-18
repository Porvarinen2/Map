const test=require('node:test');
const assert=require('node:assert/strict');
const fs=require('fs');
const path=require('path');
const root=path.resolve(__dirname,'..','..');
const read=rel=>fs.readFileSync(path.join(root,rel),'utf8');

test('SCUM startup uses a PowerShell helper with the executable directory as WorkingDirectory',()=>{
  const bat=read('server/ScumStart_NoBattlEye.bat');
  const ps=read('server/ScumStart_NoBattlEye.ps1');
  assert.match(bat,/ScumStart_NoBattlEye\.ps1/i);
  assert.doesNotMatch(bat,/^\s*start\s+/im);
  assert.match(ps,/SCUM\\Binaries\\Win64/);
  assert.match(ps,/Start-Process[\s\S]*-WorkingDirectory\s+\$binDir/i);
  assert.match(ps,/-log/);
  assert.match(ps,/-MaxPlayers=64/);
  assert.match(ps,/-nobattleye/);
});

test('SCUM startup helper detects an immediate child exit and reports its exit code',()=>{
  const ps=read('server/ScumStart_NoBattlEye.ps1');
  assert.match(ps,/Start-Process[\s\S]*-PassThru/i);
  assert.match(ps,/\.HasExited/);
  assert.match(ps,/ExitCode/);
});

test('installer performs bounded stabilization of the exact PID returned by the SCUM start helper',()=>{
  const s=read('installer/Install.ps1');
  const start=s.indexOf('function Start-Scum');
  const end=s.indexOf('function Test-BrainProcess',start);
  const fn=s.slice(start,end);
  assert.match(fn,/Get-ScumPidFile/);
  assert.match(fn,/Get-Process\s+-Id\s+\$managedPid/i);
  assert.match(fn,/AddSeconds\(/);
  assert.match(fn,/Start-Sleep/);
  assert.doesNotMatch(fn,/Get-CimInstance/);
});
