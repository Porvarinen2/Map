const test=require('node:test');
const assert=require('node:assert/strict');
const fs=require('fs');
const path=require('path');
const root=path.resolve(__dirname,'..','..');
const read=(rel)=>fs.readFileSync(path.join(root,rel),'utf8');

test('installer copies dependency trees directory-first and skips reparse points instead of blind recursive Copy-Item',()=>{
  const s=read('installer/Install.ps1');
  const start=s.indexOf('function Copy-Tree');
  const end=s.indexOf('function Invoke-Batch',start);
  const fn=s.slice(start,end);
  assert.match(fn,/ReparsePoint/i);
  assert.match(fn,/GetRelativePath|Substring/i);
  assert.match(fn,/Ensure-Dir\s+\$target/i);
  assert.doesNotMatch(fn,/Copy-Item[^\n]+-Recurse/i);
});

test('installer can bootstrap a pinned portable Node runtime without requiring winget',()=>{
  const s=read('installer/Install.ps1');
  assert.match(s,/node-v18\.20\.8-win-x64\.zip/);
  assert.match(s,/nodejs\.org\/dist\/v18\.20\.8/i);
  assert.match(s,/TeslesMods[\\/]+_Dependencies/i);
  assert.doesNotMatch(s,/winget is unavailable/i);
});

test('brain launcher falls back to the installer-managed portable Node runtime',()=>{
  const s=read('server/StartTeslesNPCBrain.bat');
  assert.match(s,/_Dependencies\\Node\\node\.exe/i);
  assert.match(s,/NODE_EXE/i);
});

test('UE4SS bootstrap validates the extracted runtime payload before continuing',()=>{
  const s=read('installer/Install.ps1');
  assert.match(s,/dwmapi\.dll/i);
  assert.match(s,/UE4SS-settings\.ini/i);
  assert.match(s,/Mods/i);
  assert.match(s,/copy verification|payload verification|runtime payload/i);
});
