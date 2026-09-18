const test=require('node:test');
const assert=require('node:assert/strict');
const fs=require('node:fs');
const path=require('node:path');

const root=path.resolve(__dirname,'..','..');
const read=(p)=>fs.readFileSync(path.join(root,p),'utf8');

test('UE4SS safe extractor uses platform separator without doubled PowerShell backslashes',()=>{
  const s=read('installer/Install.ps1');
  const start=s.indexOf('function Expand-UE4SSArchiveSafely');
  const end=s.indexOf('function Copy-ExtractedUE4SSTree',start);
  const section=s.slice(start,end);
  assert.match(section,/\[IO\.Path\]::DirectorySeparatorChar/);
  assert.doesNotMatch(section,/\$destPrefix\s*=\s*\$destBase\s*\+\s*'\\\\'/);
  assert.doesNotMatch(section,/\.Replace\('\/'\s*,\s*'\\\\'\)/);
});

test('UE4SS safe extractor checks rooted archive paths before containment normalization',()=>{
  const s=read('installer/Install.ps1');
  const start=s.indexOf('function Expand-UE4SSArchiveSafely');
  const end=s.indexOf('function Copy-ExtractedUE4SSTree',start);
  const section=s.slice(start,end);
  assert.match(section,/IsPathRooted\(\$rel\)/);
  assert.doesNotMatch(section,/TrimStart\('\\\\'\)/);
  assert.match(section,/StartsWith\(\$destPrefix,\[StringComparison\]::OrdinalIgnoreCase\)/);
});
