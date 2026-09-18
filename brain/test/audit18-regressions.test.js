const test=require('node:test');
const assert=require('node:assert/strict');
const fs=require('fs');
const path=require('path');

const root=path.resolve(__dirname,'..','..');
const read=rel=>fs.readFileSync(path.join(root,rel),'utf8');

test('brain launcher is a short-lived detached Node bootstrap instead of cmd START nesting',()=>{
  const bat=read('server/StartTeslesNPCBrain.bat');
  const launcher=read('brain/tools/launchDetached.js');
  assert.doesNotMatch(bat,/^\s*start\s+/im,'manual/installer launcher must not depend on cmd START detachment');
  assert.match(bat,/launchDetached\.js/i);
  assert.match(launcher,/spawn\(process\.execPath/);
  assert.match(launcher,/detached\s*:\s*true/);
  assert.match(launcher,/windowsHide\s*:\s*true/);
  assert.match(launcher,/child\.unref\(\)/);
  assert.match(launcher,/brain\.log/);
  assert.match(launcher,/brain\.pid/);
});

test('installer starts the detached brain launcher directly and passes validated Node executable',()=>{
  const s=read('installer/Install.ps1');
  const start=s.indexOf('function Start-Brain');
  const end=s.indexOf('function Wait-BridgeCompatibility',start);
  const fn=s.slice(start,end);
  assert.match(fn,/launchDetached\.js/);
  assert.match(fn,/\&\s+\$nodeExe\s+\$launcher/);
  assert.doesNotMatch(fn,/StartTeslesNPCBrain\.bat/);
  assert.match(s,/\$nodeExe=Ensure-Node\s+\$ServerRoot/);
  assert.match(s,/Start-Brain\s+\$dest\s+\$nodeExe/);
});

test('batch wrappers have a hard timeout and wait only for direct cmd process',()=>{
  for(const rel of ['installer/Install.ps1','installer/Uninstall.ps1']){
    const s=read(rel);
    const start=s.indexOf('function Invoke-Batch');
    const end=rel.includes('Install.ps1') ? s.indexOf('function Test-ScumRunning',start) : s.indexOf('function Restore-SharedSettingsIfUntouched',start);
    const fn=s.slice(start,end);
    assert.match(fn,/ProcessStartInfo/);
    assert.match(fn,/WaitForExit\(\$TimeoutSeconds\*1000\)/);
    assert.match(fn,/timed out after \$TimeoutSeconds seconds/i);
    assert.doesNotMatch(fn,/Start-Process[\s\S]*?-Wait/i);
  }
});

test('installer stops its own brain directly rather than re-entering another batch wrapper',()=>{
  const s=read('installer/Install.ps1');
  const start=s.indexOf('function Stop-Brain');
  const end=s.indexOf('function Ensure-Node',start);
  const fn=s.slice(start,end);
  assert.match(fn,/brain\\src\\server\.js/);
  assert.match(fn,/Invoke-CimMethod/);
  assert.doesNotMatch(fn,/StopTeslesNPCBrain\.bat/);
});
