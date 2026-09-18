const test=require('node:test');
const assert=require('node:assert/strict');
const fs=require('fs');
const path=require('path');
const root=path.resolve(__dirname,'..','..');
const read=rel=>fs.readFileSync(path.join(root,rel),'utf8');

test('SCUM start uses PID handshake instead of relying on CIM ExecutablePath visibility',()=>{
  const installer=read('installer/Install.ps1');
  const helper=read('server/ScumStart_NoBattlEye.ps1');
  assert.match(helper,/TESLES_SCUM_PID_FILE/i);
  assert.match(helper,/WriteAllText|Set-Content/i);
  const start=installer.indexOf('function Start-Scum');
  const end=installer.indexOf('function Test-BrainProcess',start);
  const fn=installer.slice(start,end);
  assert.match(fn,/TESLES_SCUM_PID_FILE/i);
  assert.match(fn,/Get-Process\s+-Id/i);
  assert.doesNotMatch(fn,/Test-ScumRunning\s+\$serverRoot/i);
});

test('SCUM stop prefers the managed PID file so the next install can stop the same server reliably',()=>{
  const stop=read('server/ScumStop_NoBattlEye.ps1');
  assert.match(stop,/scum-server\.pid/i);
  assert.match(stop,/Get-Process\s+-Id/i);
  assert.match(stop,/Stop-Process\s+-Id/i);
});

test('SCUM detection has a safe unique-name fallback when Windows hides ExecutablePath',()=>{
  const installer=read('installer/Install.ps1');
  const stop=read('server/ScumStop_NoBattlEye.ps1');
  assert.match(installer,/Get-Process\s+-Name\s+['"]?SCUMServer['"]?/i);
  assert.match(installer,/\.Count\s+-eq\s+1/i);
  assert.match(stop,/Get-Process\s+-Name\s+['"]?SCUMServer['"]?/i);
  assert.match(stop,/\.Count\s+-eq\s+1/i);
  assert.match(stop,/multiple|more than one|Count\s+-gt\s+1/i);
});

test('SCUM detection block keeps its PowerShell grouping parentheses balanced',()=>{
  const installer=read('installer/Install.ps1');
  const start=installer.indexOf('function Test-ScumRunning');
  const end=installer.indexOf('function Stop-Scum',start);
  const block=installer.slice(start,end).replace(/'[^']*'|"[^"]*"/g,'');
  const opens=(block.match(/\(/g)||[]).length;
  const closes=(block.match(/\)/g)||[]).length;
  assert.equal(opens,closes);
});
