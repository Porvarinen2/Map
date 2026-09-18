'use strict';
const test=require('node:test');
const assert=require('node:assert/strict');
const fs=require('fs');
const path=require('path');
const root=path.resolve(__dirname,'..','..');
const read=p=>fs.readFileSync(path.join(root,p),'utf8');

function fnBlock(src,name,nextMarker){
  const start=src.indexOf(`local function ${name}`);
  assert.ok(start>=0,`${name} missing`);
  const end=src.indexOf(nextMarker,start+1);
  return src.slice(start,end>=0?end:src.length);
}

test('brain takeover requires a successful IsRunning read proving the brain is stopped',()=>{
  const lua=read('ue4ss/TeslesNPCOverhaul/scripts/modules/scum_adapter.lua');
  const block=fnBlock(lua,'stop_brain','local function start_capability_probe');
  assert.match(block,/local okRun[^\n]*pcall/);
  assert.match(block,/okStop\s+and\s+okRun\s+and\s+running==false/);
  assert.doesNotMatch(block,/okStop\s+and\s+running~=true/);
});

test('watchdog fail-closes takeover when BrainComponent IsRunning cannot be inspected',()=>{
  const lua=read('ue4ss/TeslesNPCOverhaul/scripts/modules/scum_adapter.lua');
  const tick=lua.slice(lua.indexOf('function M.tick'),lua.indexOf('local function move',lua.indexOf('function M.tick')));
  assert.match(tick,/if not okRun then/);
  assert.match(tick,/release_all_takeovers\([^\n]*IsRunning/i);
});

test('NPC discovery never invents world origin when actor location is unavailable',()=>{
  const lua=read('ue4ss/TeslesNPCOverhaul/scripts/modules/scum_adapter.lua');
  const reg=lua.slice(lua.indexOf('function M.register_actor'),lua.indexOf('function M.scan_existing'));
  assert.doesNotMatch(reg,/x=loc and loc\.x or 0/);
  assert.match(reg,/if loc then[\s\S]*ipc\.emit\("NPC_SEEN"/);
});

test('UE4SS timeout clock is based on wall time rather than Lua CPU time',()=>{
  const util=read('ue4ss/TeslesNPCOverhaul/scripts/modules/util.lua');
  assert.doesNotMatch(util,/=\s*os\.clock\(\)|\(os\.clock\(\)/);
  assert.match(util,/os\.time\(\)\s*\*\s*1000/);
});
