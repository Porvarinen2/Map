const test=require('node:test');
const assert=require('node:assert/strict');
const fs=require('fs');
const path=require('path');
const root=path.resolve(__dirname,'..','..');
const read=(rel)=>fs.readFileSync(path.join(root,rel),'utf8');

test('batch wrappers do not pass a quoted trailing-backslash package root to PowerShell',()=>{
  const install=read('install.bat');
  const diagnostics=read('RunDiagnostics.bat');
  assert.doesNotMatch(install,/-SourceRoot\s+"%~dp0"/i);
  assert.doesNotMatch(diagnostics,/-PackageRoot\s+"%~dp0"/i);
  assert.match(install,/-SourceRoot\s+"%~dp0\."/i);
  assert.match(diagnostics,/-PackageRoot\s+"%~dp0\."/i);
});

test('PowerShell entrypoints defensively normalize accidental wrapping quotes on root parameters',()=>{
  const install=read('installer/Install.ps1');
  const diagnostics=read('diagnostics/CollectDiagnostics.ps1');
  assert.ok(install.includes("$SourceRoot=$SourceRoot.Trim().Trim('\"')"));
  assert.ok(diagnostics.includes("$PackageRoot=$PackageRoot.Trim().Trim('\"')"));
});
