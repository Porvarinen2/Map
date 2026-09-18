'use strict';
const test=require('node:test');
const assert=require('node:assert/strict');
const fs=require('fs');
const os=require('os');
const path=require('path');
const {saveWorld,loadWorld,migrateWorld,stripRuntimeNpcState,WORLD_SCHEMA_VERSION}=require('../src/persistence/worldStore');
const {WorldDirector}=require('../src/director/worldDirector');
const {persistentChecksum,runSoak}=require('../tools/restart-soak');
const cfg=require('../config/default.json');

function tmpWorldFile(){return path.join(fs.mkdtempSync(path.join(os.tmpdir(),'tesles-restart-')),'world.json');}
function freshDirector(world=null){
  return new WorldDirector({seed:'tesles-scum-world',world,map:cfg.map,population:cfg.population,materialization:cfg.materialization,simulation:cfg.simulation});
}

test('a v5 world migrates to v6 without regenerating identities',()=>{
  const world={version:5,npcs:{'npc-00001':{npcId:'npc-00001',seed:'s',archetype:'police',skillTier:3,traits:{courage:0.6},skills:{rifle:0.5},groupId:'group-0001',position:{x:1,y:2,z:3},traumas:[{type:'ZombieTrauma',severity:0.4}],relationships:{'npc-00002':0.5},alive:true}},groups:{'group-0001':{groupId:'group-0001',classId:'police_patrol',level:3,memberIds:['npc-00001'],leaderId:'npc-00001'}},meta:{seed:'s'}};
  const migrated=migrateWorld(JSON.parse(JSON.stringify(world)));
  assert.equal(migrated.version,WORLD_SCHEMA_VERSION);
  const npc=migrated.npcs['npc-00001'];
  assert.equal(npc.archetype,'police');
  assert.equal(npc.skillTier,3);
  assert.deepEqual(npc.traits,{courage:0.6});
  assert.deepEqual(npc.position,{x:1,y:2,z:3});
  assert.deepEqual(npc.traumas,[{type:'ZombieTrauma',severity:0.4}]);
  assert.deepEqual(npc.relationships,{'npc-00002':0.5});
  assert.equal(npc.groupId,'group-0001');
  assert.equal(migrated.meta.population.initialized,false);
  assert.equal(migrated._npcSeq,1,'id sequence must stay ahead of stored identities');
});

test('runtime actor state is never written to disk and never loaded back',()=>{
  const file=tmpWorldFile();
  const d=freshDirector();
  d.bootstrapPopulation({map:cfg.map,populationConfig:{...cfg.population,initialNpcCount:8},now:1700000000000});
  const npc=Object.values(d.world.npcs)[0];
  npc.runtimeId='actor-999';
  npc.materialized=true;
  npc.materializationState='MATERIALIZED';
  npc.aiIntent={type:'MOVE'};
  npc.spawnAttempts=3;
  saveWorld(file,d.world);
  const raw=fs.readFileSync(file,'utf8');
  for(const field of ['runtimeId','materialized','materializationState','aiIntent','spawnAttempts'])
    assert.doesNotMatch(raw,new RegExp(`"${field}"`),`${field} must not be persisted`);
  const reloaded=loadWorld(file);
  const back=reloaded.npcs[npc.npcId];
  assert.equal(back.runtimeId,null);
  assert.equal(back.materialized,false);
  assert.equal(back.materializationState,'VIRTUAL');
  assert.equal(stripRuntimeNpcState(back).runtimeId,undefined);
});

test('a corrupt primary save still falls back to its backup',()=>{
  const file=tmpWorldFile();
  const d=freshDirector();
  d.bootstrapPopulation({map:cfg.map,populationConfig:{...cfg.population,initialNpcCount:5},now:1700000000000});
  saveWorld(file,d.world);
  saveWorld(file,d.world); // creates .bak
  fs.writeFileSync(file,'{ this is not json');
  const recovered=loadWorld(file);
  assert.equal(Object.keys(recovered.npcs).length,5);
});

test('identities, squads, deaths and psychology survive fifty restarts unchanged',()=>{
  const file=tmpWorldFile();
  const result=runSoak({file,cycles:50,npcCount:40,seed:'tesles-scum-world'});
  assert.equal(result.cycles,50);
  assert.equal(result.checksumStable,true,`checksum drifted at cycle ${result.driftAtCycle}`);
  assert.equal(result.npcCountStable,true);
  assert.equal(result.deadStayDead,true);
  assert.equal(result.leadersStable,true);
  assert.equal(result.runtimeStateAlwaysClear,true);
  assert.equal(result.mutationsPreserved,true);
});

test('a reloaded initialized world never regenerates population',()=>{
  const file=tmpWorldFile();
  const first=freshDirector();
  first.bootstrapPopulation({map:cfg.map,populationConfig:{...cfg.population,initialNpcCount:30},now:1700000000000});
  const ids=Object.keys(first.world.npcs).sort();
  saveWorld(file,first.world);
  const second=freshDirector(loadWorld(file));
  const r=second.bootstrapPopulation({map:cfg.map,populationConfig:{...cfg.population,initialNpcCount:30}});
  assert.equal(r.createdNpcIds.length,0);
  assert.deepEqual(Object.keys(second.world.npcs).sort(),ids);
  for(const n of Object.values(second.world.npcs))n.alive=false;
  saveWorld(file,second.world);
  const third=freshDirector(loadWorld(file));
  third.bootstrapPopulation({map:cfg.map,populationConfig:{...cfg.population,initialNpcCount:30}});
  assert.equal(Object.keys(third.world.npcs).length,30,'an extinct world must not be repopulated');
  assert.equal(Object.values(third.world.npcs).every(n=>n.alive===false),true);
});

test('persistent checksum ignores volatile simulation fields but catches identity drift',()=>{
  const d=freshDirector();
  d.bootstrapPopulation({map:cfg.map,populationConfig:{...cfg.population,initialNpcCount:6},now:1700000000000});
  const before=persistentChecksum(d.world);
  d.world.time+=120;
  for(const n of Object.values(d.world.npcs)){n.lastUpdate=Date.now();n.lastLodEvalAt=Date.now();n.runtimeId='actor-x';}
  assert.equal(persistentChecksum(d.world),before);
  Object.values(d.world.npcs)[0].archetype='bandit';
  assert.notEqual(persistentChecksum(d.world),before);
});
