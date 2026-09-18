const test=require('node:test');
const assert=require('node:assert/strict');
const fs=require('fs');
const path=require('path');
const root=path.resolve(__dirname,'..','..');
const read=(rel)=>fs.readFileSync(path.join(root,rel),'utf8');

test('installer validates and prints the exact configured SCUMServer executable path',()=>{
  const s=read('installer/Install.ps1');
  assert.match(s,/Join-Path\s+\$ServerRoot\s+'SCUM\\Binaries\\Win64\\SCUMServer\.exe'/i);
  assert.match(s,/SCUM executable:/i);
  assert.match(s,/Test-Path\s+-LiteralPath\s+\$exe\s+-PathType\s+Leaf/i);
});

test('SCUM stop distinguishes an existing but already-stopped server from a missing executable',()=>{
  const s=read('server/ScumStop_NoBattlEye.ps1');
  assert.match(s,/Test-Path\s+-LiteralPath\s+\$exe\s+-PathType\s+Leaf/i);
  assert.match(s,/already stopped/i);
  assert.match(s,/executable is missing/i);
});

test('UE4SS bootstrap does not use PowerShell Copy-Item for extracted dependency files',()=>{
  const s=read('installer/Install.ps1');
  const start=s.indexOf('function Ensure-UE4SS');
  const end=s.indexOf('function Set-IniSectionKey',start);
  const section=s.slice(start,end);
  assert.match(s,/Expand-UE4SSArchiveSafely/);
  assert.match(s,/Copy-ExtractedUE4SSTree/);
  assert.match(s,/\[IO\.File\]::Copy/);
  assert.doesNotMatch(section,/Expand-Archive/);
});

test('UE4SS pinned download strips invisible characters and verifies checksum',()=>{
  const s=read('installer/Install.ps1');
  assert.match(s,/0xFEFF/);
  assert.match(s,/UE4SS archive checksum mismatch/i);
  assert.match(s,/PinnedUE4SSSha256/);
});

test('failed install restarts SCUM only when this installer observed it running before stop',()=>{
  const s=read('installer/Install.ps1');
  assert.match(s,/\$scumWasRunning\s*=\s*Test-ScumRunning/i);
  assert.match(s,/if\(\$scumWasRunning\).*Start-Scum/is);
});
