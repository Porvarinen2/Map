'use strict';
const test=require('node:test');
const assert=require('node:assert/strict');
const {legacyDirector}=require('./helpers/legacyDirector');
const fs=require('fs');
const path=require('path');
const root=path.resolve(__dirname,'..','..');
const read=p=>fs.readFileSync(path.join(root,p),'utf8');

function fnBlock(src,name,nextMarker){
  const start=src.indexOf(`local function ${name}`);
  assert.ok(start>=0,`${name} missing`);
  const end=nextMarker?src.indexOf(nextMarker,start+1):-1;
  return src.slice(start,end>=0?end:src.length);
}

test('full takeover is not advertised ready before every live actor brain stop succeeds',()=>{
  const lua=read('ue4ss/TeslesNPCOverhaul/scripts/modules/scum_adapter.lua');
  const block=fnBlock(lua,'activate_full_takeover','function M.register_actor');
  const firstStop=block.indexOf('stop_brain(');
  const ready=block.indexOf('full_mode_active=true');
  assert.ok(firstStop>=0&&ready>firstStop,'full takeover must only become active after stop verification');
  assert.match(block,/if not stopped then/);
  assert.match(block,/release_all_takeovers/);
});

test('unsuppressed vanilla brain reclaim releases other taken-over NPCs instead of freezing them',()=>{
  const lua=read('ue4ss/TeslesNPCOverhaul/scripts/modules/scum_adapter.lua');
  const tick=lua.slice(lua.indexOf('function M.tick'),lua.indexOf('local function move',lua.indexOf('function M.tick')));
  assert.match(tick,/release_all_takeovers\(/);
});

test('a newly spawned NPC that cannot be taken over fail-closes and releases existing takeovers',()=>{
  const lua=read('ue4ss/TeslesNPCOverhaul/scripts/modules/scum_adapter.lua');
  const reg=lua.slice(lua.indexOf('function M.register_actor'),lua.indexOf('function M.scan_existing'));
  assert.match(reg,/if full_mode_active/);
  assert.match(reg,/release_all_takeovers\(/);
});

test('non-finite IPC timestamps and coordinates cannot poison persistent world state',()=>{
  const {parseEventLine}=require('../src/bridge/protocol');
  const {WorldDirector}=require('../src/director/worldDirector');
const {legacyDirector}=require('./helpers/legacyDirector');
  const parsed=parseEventLine('Infinity|NPC_SEEN|npcId=bad|body=BP_Guard_Lvl_1|x=Infinity|y=0|z=0');
  assert.ok(Number.isFinite(parsed.at),'event timestamp must be finite');
  const d=legacyDirector({featureFlags:{groups:false}});
  d.ingest(parsed);
  assert.equal(d.world.npcs.bad,undefined,'invalid position must not create a poisoned NPC');
  d.ingest({type:'NPC_SEEN',npcId:'good',body:'BP_Guard_Lvl_1',x:1,y:2,z:3,at:Date.now()});
  d.ingest({type:'NPC_POSITION',npcId:'good',x:Infinity,y:4,z:5,at:Date.now()});
  assert.deepEqual(d.world.npcs.good.position,{x:1,y:2,z:3},'invalid position update must be ignored');
});

test('world persistence recovers from a corrupt primary save using the last valid backup',()=>{
  const os=require('os');
  const {loadWorld}=require('../src/persistence/worldStore');
  const dir=fs.mkdtempSync(path.join(os.tmpdir(),'tesles-world-recovery-'));
  const file=path.join(dir,'world.json');
  fs.writeFileSync(file,'{"broken":');
  fs.writeFileSync(file+'.bak',JSON.stringify({version:5,time:42,npcs:{},groups:{}}));
  const world=loadWorld(file);
  assert.equal(world.time,42);
});

test('saving after recovery never overwrites a valid backup with a corrupt primary',()=>{
  const os=require('os');
  const {saveWorld}=require('../src/persistence/worldStore');
  const dir=fs.mkdtempSync(path.join(os.tmpdir(),'tesles-world-backup-'));
  const file=path.join(dir,'world.json');
  const backup={version:5,time:10,npcs:{},groups:{}};
  fs.writeFileSync(file,'not-json');
  fs.writeFileSync(file+'.bak',JSON.stringify(backup));
  saveWorld(file,{version:5,time:11,npcs:{},groups:{}});
  assert.equal(JSON.parse(fs.readFileSync(file+'.bak','utf8')).time,10);
  assert.equal(JSON.parse(fs.readFileSync(file,'utf8')).time,11);
});

test('bridge restart invalidates stale materialized actor bindings before fresh discovery',()=>{
  const {WorldDirector}=require('../src/director/worldDirector');
  const d=legacyDirector({featureFlags:{groups:false}});
  d.ingest({type:'NPC_SEEN',npcId:'runtime-old',body:'BP_Guard_Lvl_1',x:1,y:2,z:3,at:1});
  const n=d._resolveByRuntime('runtime-old');
  assert.ok(n&&n.materialized);
  d.ingest({type:'BRIDGE_STARTED',at:2});
  assert.equal(d._resolveByRuntime('runtime-old'),null);
  assert.equal(n.runtimeId,null);
  assert.equal(n.materialized,false);
  assert.equal(n.simulationLod,'VIRTUAL');
});
