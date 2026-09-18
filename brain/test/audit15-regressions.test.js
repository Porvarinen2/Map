const test=require('node:test');
const assert=require('node:assert/strict');
const fs=require('node:fs');
const path=require('node:path');

const root=path.resolve(__dirname,'..','..');
const read=rel=>fs.readFileSync(path.join(root,rel),'utf8');

test('installer does not assign PowerShell automatic $Host when resolving brain endpoint',()=>{
  const s=read('installer/Install.ps1');
  assert.doesNotMatch(s,/\$host\s*=/i);
  assert.match(s,/\$listenHost\s*=\s*if\(/i);
  assert.match(s,/Host\s*=\s*\$listenHost/i);
});

test('diagnostics does not assign PowerShell automatic $Host when resolving snapshot endpoint',()=>{
  const s=read('diagnostics/CollectDiagnostics.ps1');
  assert.doesNotMatch(s,/\$host\s*=/i);
  assert.match(s,/\$listenHost\s*=\s*'127\.0\.0\.1'/i);
  assert.match(s,/http:\/\/\$probeHost`:\$port\/api\/snapshot/i);
});
