'use strict';
// audit25 contract regressions: the persistent Tesles world, the 700 m boundary and
// the honesty rules that the physical bridge must never violate.
const test=require('node:test');
const assert=require('node:assert/strict');
const fs=require('fs');
const path=require('path');
const {WorldDirector}=require('../src/director/worldDirector');
const {startMain,loadConfig}=require('../src/server');
const cfg=require('../config/default.json');

const root=path.resolve(__dirname,'..','..');
function read(rel){return fs.readFileSync(path.join(root,rel),'utf8');}

test('package metadata reports the audit25 version everywhere',()=>{
  const version=read('VERSION').trim();
  assert.equal(version,'0.1.5-audit25fix');
  assert.equal(JSON.parse(read('manifest.json')).version,version);
  assert.equal(JSON.parse(read('brain/package.json')).version,version);
  assert.match(read('ue4ss/TeslesNPCOverhaul/scripts/main.lua'),new RegExp(`version="${version}"`));
});

test('a zero-player, bridgeless server still reports a full persistent world',()=>{
  const d=new WorldDirector({seed:'tesles-scum-world',map:cfg.map,population:cfg.population,materialization:cfg.materialization,simulation:cfg.simulation});
  d.bootstrapPopulation({map:cfg.map,populationConfig:cfg.population,now:1700000000000});
  d.tick(0.5);
  const snap=d.compactSnapshot();
  assert.equal(snap.npcs.length,100);
  assert.ok(snap.groups.length>=20);
  assert.equal(snap.population.materialized,0);
  assert.equal(snap.npcs.every(n=>n.simulationLod==='VIRTUAL'),true);
  // Nothing physical has been exercised, so nothing physical may claim failure.
  const health=d.healthSnapshot();
  assert.equal(health.worldPopulation.status,'OK');
  assert.equal(health.persistence.status,'OK');
  assert.equal(health.brain.status,'OK');
  for(const key of ['scumAdapter','spawnCatalog','physicalVirtualization','takeover','physicalCombat'])
    assert.equal(health[key].status,'PENDING',`${key} must be PENDING, not a fake failure`);
});

test('the map snapshot exposes every persistent NPC and squad while all are virtual',()=>{
  const d=new WorldDirector({seed:'tesles-scum-world',map:cfg.map,population:cfg.population});
  d.bootstrapPopulation({map:cfg.map,populationConfig:{...cfg.population,initialNpcCount:25},now:1700000000000});
  const snap=d.compactSnapshot();
  for(const n of snap.npcs){
    assert.equal(n.runtimeId,null);
    assert.equal(n.materialized,false);
    assert.equal(n.materializationState,'VIRTUAL');
    assert.equal(n.desiredSimulationLod,'VIRTUAL');
    assert.ok(n.position&&Number.isFinite(n.position.x));
  }
  for(const g of snap.groups){
    assert.ok(g.memberCount>=1&&g.memberCount<=5);
    assert.equal(g.aliveMemberCount,g.memberCount);
    assert.equal(g.materializedMemberCount,0);
    assert.ok(g.leaderId);
  }
  assert.equal(snap.population.meta.initialized,true);
});

test('the shipped configuration virtualizes beyond 700 m and budgets physical churn',()=>{
  assert.equal(cfg.simulation.fullDistanceCm,20000);
  assert.equal(cfg.simulation.lightDistanceCm,70000);
  assert.equal(cfg.materialization.dematerializeGraceMs,5000);
  assert.equal(cfg.materialization.maxMaterializePerTick,2);
  assert.equal(cfg.materialization.maxDematerializePerTick,5);
  assert.equal(cfg.population.initialNpcCount,100);
  assert.equal(cfg.population.replenishDead,false);
  assert.equal(cfg.population.adoptUnmanagedNpc,false);
});

test('the shipped config documents every new population and materialization setting',()=>{
  const doc=read('brain/config/README_CONFIG.txt');
  for(const key of ['initialNpcCount','replenishDead','edgeMarginCm','groupMemberSpreadCm','adoptUnmanagedNpc','dematerializeGraceMs','maxMaterializePerTick','lightDistanceCm'])
    assert.match(doc,new RegExp(key),`${key} must be documented in README_CONFIG.txt`);
});

test('the brain boots a fresh world, saves it and serves it before any bridge exists',()=>{
  const os=require('os');
  const dir=fs.mkdtempSync(path.join(os.tmpdir(),'tesles-boot-'));
  const worldFile=path.join(dir,'world.json');
  const env={...process.env};
  process.env.TESLES_NPC_WORLD=worldFile;
  process.env.TESLES_NPC_CONFIG=path.join(dir,'installed.json');
  const runtimeCfg=JSON.parse(JSON.stringify(cfg));
  runtimeCfg.server.port=0;
  runtimeCfg.population.initialNpcCount=15;
  for(const key of ['eventsFile','commandsFile','offsetFile','stateFile'])runtimeCfg.ipc[key]=path.join(dir,`${key}.log`);
  fs.writeFileSync(process.env.TESLES_NPC_CONFIG,JSON.stringify(runtimeCfg));
  process.env.TESLES_NPC_USER_CONFIG=path.join(dir,'missing-user.json');
  try{
    const {director,server}=startMain();
    assert.equal(Object.keys(director.world.npcs).length,15);
    // The world must already be on disk before the HTTP server accepted anything.
    const saved=JSON.parse(fs.readFileSync(worldFile,'utf8'));
    assert.equal(Object.keys(saved.npcs).length,15);
    assert.equal(saved.meta.population.initialized,true);
    assert.equal(saved.version,6);
    server.close();
  }finally{
    process.env.TESLES_NPC_WORLD=env.TESLES_NPC_WORLD||'';
    if(!env.TESLES_NPC_WORLD)delete process.env.TESLES_NPC_WORLD;
    if(!env.TESLES_NPC_CONFIG)delete process.env.TESLES_NPC_CONFIG;else process.env.TESLES_NPC_CONFIG=env.TESLES_NPC_CONFIG;
    if(!env.TESLES_NPC_USER_CONFIG)delete process.env.TESLES_NPC_USER_CONFIG;else process.env.TESLES_NPC_USER_CONFIG=env.TESLES_NPC_USER_CONFIG;
  }
});

test('takeover health stays PENDING until a Tesles-owned actor is actually taken over',()=>{
  const d=new WorldDirector({seed:'takeover',map:cfg.map,population:cfg.population});
  assert.equal(d.healthSnapshot().takeover.status,'PENDING');
  d.ingest({type:'CAPABILITY',name:'full_takeover_ready',ok:false,detail:'BrainComponent not found on BP_Guard_Lvl_3',at:1});
  const degraded=d.healthSnapshot().takeover;
  assert.equal(degraded.status,'DEGRADED');
  assert.match(degraded.detail,/BrainComponent not found/);
  d.ingest({type:'CAPABILITY',name:'full_takeover_ready',ok:true,detail:'stopped',at:2});
  assert.equal(d.healthSnapshot().takeover.status,'OK');
});

test('the UE4SS bridge only takes over actors Tesles owns',()=>{
  const lua=read('ue4ss/TeslesNPCOverhaul/scripts/modules/scum_adapter.lua');
  assert.match(lua,/function takeover_candidate/);
  assert.match(lua,/return rec\.tesles_owned==true/);
  assert.match(lua,/adopt_unmanaged/);
  assert.match(lua,/persistentNpcId/);
});

test('the installer deploys the audit25 runtime files and preserves the world save',()=>{
  const install=read('installer/Install.ps1');
  assert.match(install,/spawn_adapter\.lua/);
  assert.match(install,/weapon_adapter\.lua/);
  assert.match(install,/compat_profile\.lua/);
  assert.match(install,/population\.json/);
  assert.match(install,/body-profiles\.json/);
  assert.match(install,/__COMPAT_PROFILE_FILE__/);
  assert.match(install,/__ADOPT_UNMANAGED__/);
  assert.match(install,/Restoring persistent runtime\/world data/i);
});

test('diagnostics capture the persistent world, materialization queue and compat profile',()=>{
  const diag=read('diagnostics/CollectDiagnostics.ps1');
  assert.match(diag,/population/i);
  assert.match(diag,/materialization/i);
  assert.match(diag,/compat-profile\.json/);
});

test('the 700 m live acceptance scenario is documented for the operator',()=>{
  const doc=read('docs/testing/700m-materialization-scenario.md');
  assert.match(doc,/700/);
  assert.match(doc,/5 s|5 second|five second/i);
  assert.match(doc,/rematerial/i);
  assert.match(doc,/same npcIds|identity/i);
});
