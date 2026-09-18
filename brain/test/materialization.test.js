'use strict';
const test=require('node:test');
const assert=require('node:assert/strict');
const mat=require('../src/virtual/materializationCoordinator');
const {selectMaterializationWork,placementCandidate,candidateOffsetsCm}=require('../src/director/spawnPolicy');
const {simulationLod}=require('../src/virtual/sim');
const {WorldDirector}=require('../src/director/worldDirector');
const cfg=require('../config/default.json');

function entity(overrides={}){
  return {npcId:'npc-00001',alive:true,position:{x:0,y:0,z:0},bodyFamily:'GUARD',bodyLevel:3,groupId:'group-0001',
    materialized:false,materializationState:'VIRTUAL',spawnAttempts:0,runtimeGeneration:0,...overrides};
}
function bootstrappedDirector(options={}){
  const d=new WorldDirector({seed:'tesles-scum-world',map:cfg.map,population:cfg.population,materialization:cfg.materialization,simulation:cfg.simulation,...options});
  d.bootstrapPopulation({map:cfg.map,populationConfig:{...cfg.population,initialNpcCount:12},now:1700000000000});
  for(const cls of ['BP_Guard_Lvl_1','BP_Guard_Lvl_2','BP_Guard_Lvl_3','BP_Guard_Lvl_4','BP_Guard_Lvl_5'])
    d.ingest({type:'NPC_CLASS_CATALOG',class:cls,family:'GUARD',level:Number(cls.slice(-1)),at:1});
  for(const cls of ['BP_Drifter_Lvl_1','BP_Drifter_Lvl_2','BP_Drifter_Lvl_3','BP_Drifter_Lvl_4','BP_Drifter_Lvl_5'])
    d.ingest({type:'NPC_CLASS_CATALOG',class:cls,family:'DRIFTER',level:Number(cls.slice(-1)),at:1});
  return d;
}

test('the 700 m boundary decides FULL, LIGHT and VIRTUAL exactly',()=>{
  assert.equal(simulationLod(0),'FULL');
  assert.equal(simulationLod(20000),'FULL');
  assert.equal(simulationLod(20001),'LIGHT');
  assert.equal(simulationLod(69999),'LIGHT');
  assert.equal(simulationLod(70000),'LIGHT');
  assert.equal(simulationLod(70001),'VIRTUAL');
  assert.equal(cfg.simulation.lightDistanceCm,70000);
});

test('a virtual entity whose player arrives queues a spawn immediately',()=>{
  const n=entity();
  const intent=mat.evaluateMaterialization(n,{desiredLod:'LIGHT',now:1000});
  assert.equal(intent.type,'SPAWN');
  assert.equal(intent.persistentNpcId,'npc-00001');
  assert.equal(n.materializationState,'SPAWN_QUEUED');
});

test('a queued spawn is cancelled when the player leaves before dispatch',()=>{
  const n=entity();
  mat.evaluateMaterialization(n,{desiredLod:'FULL',now:1000});
  assert.equal(mat.evaluateMaterialization(n,{desiredLod:'VIRTUAL',now:1100}),null);
  assert.equal(n.materializationState,'VIRTUAL');
});

test('a dispatched spawn waits for its result and times out into backoff',()=>{
  const n=entity();
  mat.evaluateMaterialization(n,{desiredLod:'FULL',now:1000});
  mat.markSpawnDispatched(n,{now:1000});
  assert.equal(n.materializationState,'SPAWNING');
  assert.equal(mat.evaluateMaterialization(n,{desiredLod:'FULL',now:1100}),null);
  mat.evaluateMaterialization(n,{desiredLod:'FULL',now:1000+cfg.materialization.spawnCommandTimeoutMs+1});
  assert.equal(n.materializationState,'SPAWN_BACKOFF');
});

test('a materialized entity whose player leaves waits the full grace before capture',()=>{
  const n=entity({materialized:true,runtimeId:'actor-1',materializationState:'MATERIALIZED'});
  assert.equal(mat.evaluateMaterialization(n,{desiredLod:'VIRTUAL',now:5000}),null);
  assert.equal(n.materializationState,'DESPAWN_GRACE');
  assert.equal(n.dematerializeEligibleAt,10000);
  assert.equal(mat.evaluateMaterialization(n,{desiredLod:'VIRTUAL',now:9999}),null,'grace must not expire early');
  const intent=mat.evaluateMaterialization(n,{desiredLod:'VIRTUAL',now:10000});
  assert.equal(intent.type,'CAPTURE_AND_DESPAWN');
  assert.equal(n.materializationState,'DESPAWN_QUEUED');
});

test('a player returning inside the grace window cancels dematerialization',()=>{
  const n=entity({materialized:true,runtimeId:'actor-1',materializationState:'MATERIALIZED'});
  mat.evaluateMaterialization(n,{desiredLod:'VIRTUAL',now:5000});
  assert.equal(mat.evaluateMaterialization(n,{desiredLod:'LIGHT',now:7000}),null);
  assert.equal(n.materializationState,'MATERIALIZED');
  assert.equal(n.dematerializeEligibleAt,null);
  assert.equal(n.materialized,true);
});

test('a failed spawn keeps the persistent entity intact and retries with backoff',()=>{
  const n=entity({position:{x:1234,y:5678,z:90}});
  mat.evaluateMaterialization(n,{desiredLod:'FULL',now:1000});
  mat.markSpawnDispatched(n,{now:1000});
  mat.applyMaterializeFailed(n,{reason:'NO_NAVMESH',now:2000,spawnRetryMs:10000});
  assert.equal(n.materializationState,'SPAWN_BACKOFF');
  assert.equal(n.materialized,false);
  assert.equal(n.runtimeId,null);
  assert.deepEqual(n.position,{x:1234,y:5678,z:90},'a failed spawn must never move the persistent entity');
  assert.equal(n.spawnRetryAt,12000);
  assert.equal(mat.evaluateMaterialization(n,{desiredLod:'FULL',now:11999}),null);
  mat.evaluateMaterialization(n,{desiredLod:'FULL',now:12000});
  assert.equal(n.materializationState,'VIRTUAL');
});

test('repeated spawn failures back off exponentially up to the configured ceiling',()=>{
  assert.equal(mat.backoffMs(1,{spawnRetryMs:10000,spawnBackoffMaxMs:120000}),10000);
  assert.equal(mat.backoffMs(3,{spawnRetryMs:10000,spawnBackoffMaxMs:120000}),40000);
  assert.equal(mat.backoffMs(9,{spawnRetryMs:10000,spawnBackoffMaxMs:120000}),120000);
});

test('a failed capture never destroys the actor and keeps the entity materialized',()=>{
  const n=entity({materialized:true,runtimeId:'actor-1',materializationState:'CAPTURING',captureRequestedAt:1000});
  mat.applyCaptureFailed(n,{reason:'HEALTH_UNREADABLE',now:2000});
  assert.equal(n.materialized,true);
  assert.equal(n.runtimeId,'actor-1');
  assert.equal(n.materializationState,'MATERIALIZED');
  assert.equal(n.lastCaptureFailure.reason,'HEALTH_UNREADABLE');
});

test('a capture that never answers keeps the actor rather than dropping state',()=>{
  const n=entity({materialized:true,runtimeId:'actor-1',materializationState:'CAPTURING',captureRequestedAt:1000});
  mat.evaluateMaterialization(n,{desiredLod:'VIRTUAL',now:1000+cfg.materialization.captureCommandTimeoutMs+1});
  assert.equal(n.materializationState,'MATERIALIZED');
  assert.equal(n.materialized,true);
});

test('a successful capture moves the persistent entity to its final physical position',()=>{
  const n=entity({materialized:true,runtimeId:'actor-1',materializationState:'CAPTURING',health:1});
  mat.applyDematerialized(n,{position:{x:999,y:-42,z:7},health:0.4,now:3000});
  assert.deepEqual(n.position,{x:999,y:-42,z:7});
  assert.equal(n.health,0.4);
  assert.equal(n.materialized,false);
  assert.equal(n.runtimeId,null);
  assert.equal(n.materializationState,'VIRTUAL');
});

test('a capture snapshot can never heal or resurrect an entity',()=>{
  const n=entity({materialized:true,runtimeId:'actor-1',materializationState:'CAPTURING',health:0.2,alive:true});
  mat.applyDematerialized(n,{health:1,now:3000});
  assert.equal(n.health,0.2);
});

test('a dead entity never receives a materialization command',()=>{
  const n=entity({alive:false});
  assert.equal(mat.evaluateMaterialization(n,{desiredLod:'FULL',now:1000}),null);
  assert.equal(n.materializationState,'VIRTUAL');
});

test('spawn work is prioritised by player distance, squad cohesion, LOD then queue age',()=>{
  const intents=[
    {type:'SPAWN',persistentNpcId:'far',nearestPlayerDistance:60000,desiredLod:'LIGHT',queuedAt:1,groupId:'g2'},
    {type:'SPAWN',persistentNpcId:'near',nearestPlayerDistance:1000,desiredLod:'FULL',queuedAt:5,groupId:'g1'},
    {type:'SPAWN',persistentNpcId:'mid',nearestPlayerDistance:30000,desiredLod:'LIGHT',queuedAt:2,groupId:'g1'},
    {type:'CAPTURE_AND_DESPAWN',persistentNpcId:'old',queuedAt:1},
    {type:'CAPTURE_AND_DESPAWN',persistentNpcId:'new',queuedAt:9}
  ];
  const work=selectMaterializationWork(intents,{maxMaterializePerTick:2,maxDematerializePerTick:1});
  assert.deepEqual(work.materialize.map(i=>i.persistentNpcId),['near','mid']);
  assert.deepEqual(work.dematerialize.map(i=>i.persistentNpcId),['old']);
  assert.equal(work.queuedMaterialize,3);
  assert.equal(work.queuedDematerialize,2);
});

test('same-distance spawns prefer a squad that is already materializing',()=>{
  const intents=[
    {type:'SPAWN',persistentNpcId:'lonely',nearestPlayerDistance:5000,desiredLod:'FULL',queuedAt:1,groupId:'g9'},
    {type:'SPAWN',persistentNpcId:'squadmate',nearestPlayerDistance:5000,desiredLod:'FULL',queuedAt:2,groupId:'g1'}
  ];
  const work=selectMaterializationWork(intents,{maxMaterializePerTick:1,materializingGroupIds:['g1']});
  assert.deepEqual(work.materialize.map(i=>i.persistentNpcId),['squadmate']);
});

test('placement candidates are deterministic and start at the entity position',()=>{
  assert.deepEqual(placementCandidate({x:100,y:200,z:300},0),{x:100,y:200,z:300,offsetIndex:0});
  assert.deepEqual(placementCandidate({x:0,y:0,z:0},1),{x:1000,y:0,z:0,offsetIndex:1});
  assert.equal(candidateOffsetsCm.length,17);
  assert.deepEqual(placementCandidate({x:0,y:0,z:0},candidateOffsetsCm.length),placementCandidate({x:0,y:0,z:0},0));
});

test('a player crossing 700 m makes the director request a spawn and later a capture',()=>{
  const d=bootstrappedDirector();
  const npc=Object.values(d.world.npcs)[0];
  npc.position={x:0,y:0,z:0};
  d.ingest({type:'PLAYER_SEEN',playerId:'p1',x:1000,y:0,z:0,at:Date.now()});
  d.tick(0.5);
  const spawn=d.drainCommands().find(c=>c.type==='SPAWN'&&c.persistentNpcId===npc.npcId);
  assert.ok(spawn,'expected a SPAWN command for the nearby NPC');
  assert.ok(spawn.npcClass,'spawn must name a verified runtime class');
  assert.equal(npc.materializationState,'SPAWNING');
  d.ingest({type:'MATERIALIZED',persistentNpcId:npc.npcId,runtimeId:'actor-77',generation:spawn.generation,x:10,y:0,z:0,body:spawn.npcClass,at:Date.now()});
  assert.equal(npc.materialized,true);
  assert.equal(npc.runtimeId,'actor-77');
  assert.equal(Object.keys(d.world.npcs).length,12,'binding an actor must never create a new entity');
  d.world.players={};
  d.tick(0.5);
  assert.equal(npc.materializationState,'DESPAWN_GRACE');
  npc.dematerializeEligibleAt=Date.now()-1;
  d.tick(0.5);
  const capture=d.drainCommands().find(c=>c.type==='CAPTURE_AND_DESPAWN');
  assert.ok(capture);
  assert.equal(capture.runtimeId,'actor-77');
  d.ingest({type:'DEMATERIALIZED',persistentNpcId:npc.npcId,x:123,y:456,z:7,health:0.8,at:Date.now()});
  assert.equal(npc.materialized,false);
  assert.deepEqual(npc.position,{x:123,y:456,z:7});
  assert.equal(npc.health,0.8);
});

test('a dense region cannot burst more spawns per tick than the configured budget',()=>{
  const d=bootstrappedDirector();
  for(const n of Object.values(d.world.npcs))n.position={x:0,y:0,z:0};
  d.ingest({type:'PLAYER_SEEN',playerId:'p1',x:0,y:0,z:0,at:Date.now()});
  d.tick(0.5);
  const spawns=d.drainCommands().filter(c=>c.type==='SPAWN');
  assert.equal(spawns.length,cfg.materialization.maxMaterializePerTick);
  assert.ok(d.snapshot().materialization.queue.queuedMaterialize>spawns.length);
});

test('an entity whose body family has no verified class stays virtual with a reason',()=>{
  const d=bootstrappedDirector();
  const npc=Object.values(d.world.npcs)[0];
  npc.bodyFamily='RADIATION';
  npc.position={x:0,y:0,z:0};
  d.ingest({type:'PLAYER_SEEN',playerId:'p1',x:0,y:0,z:0,at:Date.now()});
  d.tick(0.5);
  assert.match(String(npc.spawnBlockedReason),/BODY_PROFILE_UNAVAILABLE/);
  assert.equal(npc.materialized,false);
  assert.equal(d.drainCommands().some(c=>c.persistentNpcId===npc.npcId&&c.type==='SPAWN'),false);
});

test('physical virtualization only turns green after a proven roundtrip',()=>{
  const d=bootstrappedDirector();
  assert.equal(d.healthSnapshot().physicalVirtualization.status,'PENDING');
  const npc=Object.values(d.world.npcs)[0];
  npc.position={x:0,y:0,z:0};
  d.ingest({type:'PLAYER_SEEN',playerId:'p1',x:100,y:0,z:0,at:Date.now()});
  d.tick(0.5);
  const spawn=d.drainCommands().find(c=>c.type==='SPAWN'&&c.persistentNpcId===npc.npcId);
  d.ingest({type:'MATERIALIZED',persistentNpcId:npc.npcId,runtimeId:'actor-1',generation:spawn.generation,x:0,y:0,z:0,at:Date.now()});
  assert.equal(d.healthSnapshot().physicalVirtualization.status,'PENDING','a single spawn is not a roundtrip');
  d.ingest({type:'DEMATERIALIZED',persistentNpcId:npc.npcId,x:0,y:0,z:0,health:1,at:Date.now()});
  assert.equal(d.healthSnapshot().physicalVirtualization.status,'PENDING');
  npc.runtimeGeneration+=1;
  d.ingest({type:'MATERIALIZED',persistentNpcId:npc.npcId,runtimeId:'actor-2',generation:npc.runtimeGeneration,x:0,y:0,z:0,at:Date.now()});
  assert.equal(d.healthSnapshot().physicalVirtualization.status,'OK');
  assert.equal(d.world.capabilities.virtualization_roundtrip.ok,true);
});

test('a failed materialization degrades virtualization health with the exact reason',()=>{
  const d=bootstrappedDirector();
  const npc=Object.values(d.world.npcs)[0];
  npc.position={x:0,y:0,z:0};
  d.ingest({type:'PLAYER_SEEN',playerId:'p1',x:100,y:0,z:0,at:Date.now()});
  d.tick(0.5);
  d.drainCommands();
  d.ingest({type:'MATERIALIZE_FAILED',persistentNpcId:npc.npcId,reason:'SPAWN_REJECTED',at:Date.now()});
  const health=d.healthSnapshot().physicalVirtualization;
  assert.equal(health.status,'DEGRADED');
  assert.match(health.detail,/SPAWN_REJECTED/);
});

test('death wins over a pending dematerialization and over late spawn results',()=>{
  const d=bootstrappedDirector();
  const npc=Object.values(d.world.npcs)[0];
  npc.position={x:0,y:0,z:0};
  d.ingest({type:'PLAYER_SEEN',playerId:'p1',x:100,y:0,z:0,at:Date.now()});
  d.tick(0.5);
  const spawn=d.drainCommands().find(c=>c.type==='SPAWN'&&c.persistentNpcId===npc.npcId);
  d.ingest({type:'MATERIALIZED',persistentNpcId:npc.npcId,runtimeId:'actor-1',generation:spawn.generation,x:0,y:0,z:0,at:Date.now()});
  d.ingest({type:'NPC_DEATH',npcId:'actor-1',at:Date.now()});
  assert.equal(npc.alive,false);
  assert.equal(npc.materialized,false);
  assert.equal(npc.runtimeId,null);
  // A delayed success for a now-dead entity must be destroyed, not resurrected.
  d.ingest({type:'MATERIALIZED',persistentNpcId:npc.npcId,runtimeId:'actor-2',generation:spawn.generation,x:0,y:0,z:0,at:Date.now()});
  assert.equal(npc.alive,false);
  assert.equal(npc.materialized,false);
  assert.ok(d.drainCommands().some(c=>c.type==='FORCE_DESTROY'&&c.runtimeId==='actor-2'));
});

test('a stale spawn generation is destroyed instead of bound',()=>{
  const d=bootstrappedDirector();
  const npc=Object.values(d.world.npcs)[0];
  npc.runtimeGeneration=4;
  d.ingest({type:'MATERIALIZED',persistentNpcId:npc.npcId,runtimeId:'actor-old',generation:2,x:0,y:0,z:0,at:Date.now()});
  assert.equal(npc.materialized,false);
  assert.ok(d.drainCommands().some(c=>c.type==='FORCE_DESTROY'&&c.runtimeId==='actor-old'));
});

test('an unexpectedly lost actor keeps persistent state and returns to virtual',()=>{
  const d=bootstrappedDirector();
  const npc=Object.values(d.world.npcs)[0];
  npc.position={x:0,y:0,z:0};
  d.ingest({type:'PLAYER_SEEN',playerId:'p1',x:100,y:0,z:0,at:Date.now()});
  d.tick(0.5);
  const spawn=d.drainCommands().find(c=>c.type==='SPAWN'&&c.persistentNpcId===npc.npcId);
  d.ingest({type:'MATERIALIZED',persistentNpcId:npc.npcId,runtimeId:'actor-1',generation:spawn.generation,x:500,y:0,z:0,at:Date.now()});
  d.ingest({type:'NPC_GONE',npcId:'actor-1',at:Date.now()});
  assert.equal(npc.alive,true);
  assert.equal(npc.materialized,false);
  assert.deepEqual(npc.position,{x:500,y:0,z:0});
  assert.ok(d.world.events.some(e=>e.type==='unexpected_actor_loss'));
});

test('an unmanaged SCUM NPC never grows the Tesles population by default',()=>{
  const d=bootstrappedDirector();
  const before=Object.keys(d.world.npcs).length;
  d.ingest({type:'NPC_SEEN',npcId:'wild-actor',body:'BP_Drifter_Lvl_1',x:0,y:0,z:0,at:Date.now()});
  assert.equal(Object.keys(d.world.npcs).length,before);
  assert.ok(d.world.events.some(e=>e.type==='unmanaged_npc_ignored'));
});
