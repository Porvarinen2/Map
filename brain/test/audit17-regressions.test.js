const test=require('node:test');
const assert=require('node:assert/strict');
const fs=require('node:fs');
const path=require('node:path');

const root=path.resolve(__dirname,'..','..');
const read=rel=>fs.readFileSync(path.join(root,rel),'utf8');

test('installer batch runner waits only for the wrapper cmd, not long-lived descendants',()=>{
  const s=read('installer/Install.ps1');
  const start=s.indexOf('function Invoke-Batch');
  const end=s.indexOf('function Test-ScumRunning',start);
  const fn=s.slice(start,end);
  assert.ok(start>=0 && end>start,'Invoke-Batch function must exist');
  assert.doesNotMatch(fn,/Start-Process[\s\S]*?-Wait/i,'Start-Process -Wait waits for the whole descendant process tree');
  assert.match(fn,/\$env:ComSpec/i,'batch runner should invoke cmd.exe directly');
  assert.match(fn,/\$proc\.ExitCode/i,'batch runner should still propagate the direct wrapper exit code');
});

test('uninstaller batch runner also avoids Start-Process -Wait process-tree blocking',()=>{
  const s=read('installer/Uninstall.ps1');
  const start=s.indexOf('function Invoke-Batch');
  const end=s.indexOf('function Restore-SharedSettingsIfUntouched',start);
  const fn=s.slice(start,end);
  assert.ok(start>=0 && end>start,'Uninstall Invoke-Batch function must exist');
  assert.doesNotMatch(fn,/Start-Process[\s\S]*?-Wait/i);
  assert.match(fn,/\$env:ComSpec/i);
  assert.match(fn,/\$proc\.ExitCode/i);
});
