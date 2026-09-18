const test=require('node:test');
const assert=require('node:assert/strict');
const fs=require('fs');
const path=require('path');
const {WorldDirector}=require('../src/director/worldDirector');
const {legacyDirector}=require('./helpers/legacyDirector');
const {physicalControlReady}=require('../src/server');
const root=path.resolve(__dirname,'..','..');
const read=rel=>fs.readFileSync(path.join(root,rel),'utf8');

test('full mode remains gated until bridge explicitly reports full_takeover_ready',()=>{
  const cfg={features:{takeoverRequested:true,takeoverMode:'full'}};
  const director={world:{capabilities:{bridge_scheduler:{ok:true},brain_stop:{ok:true},movement:{ok:true},full_takeover_ready:{ok:false}}}};
  assert.equal(physicalControlReady(cfg,director),false);
  director.world.capabilities.full_takeover_ready.ok=true;
  assert.equal(physicalControlReady(cfg,director),true);
});

test('full mode Lua performs capability probe before activating persistent brain takeover',()=>{
  const lua=read('ue4ss/TeslesNPCOverhaul/scripts/modules/scum_adapter.lua');
  assert.doesNotMatch(lua,/if cfg\.takeover_mode=="full" or \(cfg\.takeover_mode=="auto" and full_mode_active\)/);
  assert.match(lua,/cfg\.takeover_mode=="full" and movement_verified/);
  assert.match(lua,/activate_full_takeover\(\)/);
});

test('successful probe releases probe slot so another NPC can be tested if needed',()=>{
  const lua=read('ue4ss/TeslesNPCOverhaul/scripts/modules/scum_adapter.lua');
  assert.match(lua,/retry_probe_if_needed/);
  assert.match(lua,/probe_retry_after/);
  assert.match(lua,/last_probe_at/);
});

test('MoveTo return value is validated instead of treating pcall success as path success',()=>{
  const lua=read('ue4ss/TeslesNPCOverhaul/scripts/modules/scum_adapter.lua');
  assert.match(lua,/move_request_accepted/);
  assert.match(lua,/RequestSuccessful/);
  assert.match(lua,/AlreadyAtGoal/);
  assert.match(lua,/return false,"MoveToLocation returned/);
});

test('installer always enables Tesles in mods.txt and does not rely on mods.json',()=>{
  const install=read('installer/Install.ps1');
  assert.match(install,/Set-Content -LiteralPath \$txt/);
  assert.match(install,/TeslesNPCOverhaul/);
  assert.doesNotMatch(install,/if\(Test-Path -LiteralPath \$json\)[\s\S]{0,800}return \$json/);
});

test('server stop script targets configured executable path only',()=>{
  const ps=read('server/ScumStop_NoBattlEye.ps1');
  assert.doesNotMatch(ps,/taskkill\s+\/F\s+\/T\s+\/IM/i);
  assert.match(ps,/ExecutablePath[\s\S]*Get-CanonicalPath[\s\S]*-ieq\s+\$exe/i);
});

test('unstable identity never spatially rebinds to a nearby persistent NPC',()=>{
  const d=legacyDirector({population:{roamEnabled:false}});
  d.ingest({type:'NPC_SEEN',npcId:'runtime-a',body:'BP_Guard_Lvl_1',x:0,y:0,z:0});
  const first=Object.values(d.world.npcs)[0];
  d.ingest({type:'NPC_GONE',npcId:'runtime-a'});
  d.ingest({type:'NPC_SEEN',npcId:'runtime-b',body:'BP_Guard_Lvl_1',x:50,y:0,z:0});
  const alive=Object.values(d.world.npcs).filter(n=>n.alive!==false);
  assert.equal(alive.length,2);
  assert.notEqual(alive.find(n=>n.runtimeId==='runtime-b')?.npcId,first.npcId);
});

test('event IPC has bounded rotation before append logging can grow forever',()=>{
  const ipc=read('ue4ss/TeslesNPCOverhaul/scripts/modules/ipc.lua');
  const tpl=read('ue4ss/TeslesNPCOverhaul/scripts/runtime_config.lua.template');
  assert.match(ipc,/event_max_bytes/);
  assert.match(ipc,/\.1/);
  assert.match(ipc,/seek\("end"\)/);
  assert.match(tpl,/event_max_bytes\s*=\s*5242880/);
});
