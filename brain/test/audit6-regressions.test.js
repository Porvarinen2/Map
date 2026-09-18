const test=require('node:test');
const assert=require('node:assert/strict');
const fs=require('fs');
const path=require('path');
const {parseEventLine}=require('../src/bridge/protocol');
const {WorldDirector}=require('../src/director/worldDirector');

const root=path.resolve(__dirname,'..','..');
function read(rel){return fs.readFileSync(path.join(root,rel),'utf8');}

test('IPC payload cannot overwrite reserved event type or timestamp',()=>{
  const e=parseEventLine('123|COMMAND_RESULT|at=999|type=MOVE|npcId=runtime-1|ok=false|detail=path%20failed');
  assert.equal(e.type,'COMMAND_RESULT');
  assert.equal(e.at,123);
  assert.equal(e.commandType,'MOVE');
  assert.equal(e.payloadAt,999);
  assert.equal(e.ok,false);
});

test('failed MOVE command result requests navigation recovery instead of disabling the global movement capability',()=>{
  const d=new WorldDirector({featureFlags:{groups:false}});
  d.ingest({type:'NPC_SEEN',npcId:'runtime-1',body:'BP_Drifter_Lvl_1',x:0,y:0,z:0,at:1});
  const n=d.world.npcs['runtime-1'];
  n.navigation={movementCommanded:true,pathFailed:false,recoveryRequested:null,lastTarget:{x:1000,y:0,z:0},lastRepathAt:1};
  d.world.capabilities.movement={ok:true,detail:'probe passed',at:1};
  const e=parseEventLine('2|COMMAND_RESULT|commandType=MOVE|npcId=runtime-1|ok=false|detail=MoveToLocation%20failed');
  d.ingest(e);
  assert.equal(d.world.capabilities.movement.ok,true);
  assert.equal(n.navigation.pathFailed,true);
  assert.equal(n.navigation.recoveryRequested,'REPATH');
});

test('runtime MOVE command handling does not rewrite the global movement capability',()=>{
  const lua=read('ue4ss/TeslesNPCOverhaul/scripts/modules/scum_adapter.lua');
  const start=lua.indexOf('function M.handle_command');
  const end=lua.indexOf('function M.configure',start);
  const block=lua.slice(start,end);
  assert.doesNotMatch(block,/probe\.cap\("movement"/);
  assert.match(block,/COMMAND_RESULT/);
});

test('UE4SS capability clock follows wall time rather than synthetic call-count or CPU time',()=>{
  const util=read('ue4ss/TeslesNPCOverhaul/scripts/modules/util.lua');
  assert.match(util,/os\.time\(\)\s*\*\s*1000/);
  assert.doesNotMatch(util,/=\s*os\.clock\(\)|\(os\.clock\(\)/);
  assert.doesNotMatch(util,/if now <= _last_ms then now = _last_ms \+ 1/);
});

test('new bridge session invalidates stale persisted runtime capabilities before accepting fresh probe results',()=>{
  const world={version:5,time:0,npcs:{},groups:{},zombies:{},players:{},events:[],capabilities:{movement:{ok:true},brain_stop:{ok:true},bridge_scheduler:{ok:true},full_takeover_ready:{ok:true}},meta:{seed:'x'},_groupSeq:0,_npcSeq:0};
  const d=new WorldDirector({world});
  d.ingest({type:'BRIDGE_STARTED',version:'0.1.5-audit9fix',at:100});
  assert.deepEqual(d.world.capabilities,{});
  assert.equal(d.healthSnapshot().scumAdapter.status,'DEGRADED');
});
