const test=require('node:test');
const assert=require('node:assert/strict');
const fs=require('fs');
const path=require('path');
const root=path.resolve(__dirname,'..','..');
const read=rel=>fs.readFileSync(path.join(root,rel),'utf8');

test('SCUM stop PowerShell never places a colon immediately after an unbraced interpolated variable',()=>{
  const stop=read('server/ScumStop_NoBattlEye.ps1');
  const hazards=[];
  for (const [index,line] of stop.split(/\r?\n/).entries()) {
    if (/"[^"\r\n]*\$[A-Za-z_][A-Za-z0-9_]*:/.test(line)) hazards.push(`${index+1}: ${line.trim()}`);
  }
  assert.deepEqual(hazards,[],`PowerShell parses $name: as a scoped/drive-qualified variable reference; brace the variable before ':'\n${hazards.join('\n')}`);
});
