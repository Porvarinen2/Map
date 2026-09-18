'use strict';
const test=require('node:test');
const assert=require('node:assert/strict');
const {bootstrapWorldPopulation,validatePopulationConfig}=require('../src/director/worldPopulation');
const {resolveBodyProfile,BLOCKED_REASON}=require('../src/director/bodyProfileResolver');
const {createNpc}=require('../src/core/entityFactory');
const cfg=require('../config/default.json');

const MAP=cfg.map;
const POP=cfg.population;
function emptyWorld(){return {version:6,npcs:{},groups:{},zombies:{},players:{},events:[],capabilities:{},meta:{seed:'tesles-scum-world'},_npcSeq:0,_groupSeq:0};}
function bootstrap(world,overrides={}){
  return bootstrapWorldPopulation(world,{seed:'tesles-scum-world',map:MAP,populationConfig:{...POP,...overrides},now:1700000000000});
}

test('a fresh world bootstraps exactly the configured number of persistent NPCs',()=>{
  const w=emptyWorld();
  const r=bootstrap(w);
  assert.equal(r.createdNpcIds.length,100);
  assert.equal(Object.keys(w.npcs).length,100);
  assert.equal(w.meta.population.initialized,true);
  assert.equal(w.meta.population.initialTarget,100);
  assert.equal(w.meta.population.replenishDead,false);
});

test('every bootstrapped NPC belongs to exactly one 1-5 member squad with a valid leader',()=>{
  const w=emptyWorld();
  bootstrap(w);
  const seen=new Set();
  for(const g of Object.values(w.groups)){
    assert.ok(g.members.length>=1&&g.members.length<=5,`group ${g.groupId} has ${g.members.length} members`);
    assert.ok(g.leaderId,`group ${g.groupId} has no leader`);
    assert.ok(g.members.some(m=>m.npcId===g.leaderId));
    for(const m of g.members){
      assert.equal(m.groupId,g.groupId);
      assert.equal(seen.has(m.npcId),false,`npc ${m.npcId} is in two groups`);
      seen.add(m.npcId);
    }
  }
  assert.equal(seen.size,100);
});

test('bootstrapped positions stay inside the configured map margin',()=>{
  const w=emptyWorld();
  bootstrap(w);
  const margin=POP.edgeMarginCm;
  for(const n of Object.values(w.npcs)){
    assert.ok(n.position.x>=MAP.minX+margin-1&&n.position.x<=MAP.maxX-margin+1,`x out of bounds: ${n.position.x}`);
    assert.ok(n.position.y>=MAP.minY+margin-1&&n.position.y<=MAP.maxY-margin+1,`y out of bounds: ${n.position.y}`);
  }
});

test('group members start close to their squad anchor',()=>{
  const w=emptyWorld();
  bootstrap(w);
  for(const g of Object.values(w.groups)){
    for(const m of g.members){
      const d=Math.hypot(m.position.x-g.homePosition.x,m.position.y-g.homePosition.y);
      assert.ok(d<=POP.groupMemberSpreadCm+1,`member ${m.npcId} is ${d} cm from its anchor`);
    }
  }
});

test('the same seed and config produce identical identities, squads and positions',()=>{
  const a=emptyWorld(),b=emptyWorld();
  bootstrap(a);bootstrap(b);
  const identity=w=>Object.values(w.npcs).map(n=>[n.npcId,n.archetype,n.skillTier,n.groupId,n.bodyFamily,n.bodyLevel,n.position.x,n.position.y,JSON.stringify(n.traits),JSON.stringify(n.skills)]);
  assert.deepEqual(identity(a),identity(b));
  assert.deepEqual(Object.values(a.groups).map(g=>[g.groupId,g.classId,g.leaderId,g.memberIds||g.members.map(m=>m.npcId)]),
                   Object.values(b.groups).map(g=>[g.groupId,g.classId,g.leaderId,g.memberIds||g.members.map(m=>m.npcId)]));
});

test('a different seed produces a different population',()=>{
  const a=emptyWorld(),b=emptyWorld();
  bootstrap(a);
  bootstrapWorldPopulation(b,{seed:'other-world',map:MAP,populationConfig:POP,now:1700000000000});
  const archetypes=w=>Object.values(w.npcs).map(n=>n.archetype).join(',');
  assert.notEqual(archetypes(a),archetypes(b));
});

test('bootstrap is idempotent and never refills after deaths',()=>{
  const w=emptyWorld();
  bootstrap(w);
  const second=bootstrap(w);
  assert.equal(second.createdNpcIds.length,0);
  assert.equal(second.mode,'already_initialized');
  for(const n of Object.values(w.npcs))n.alive=false;
  const third=bootstrap(w);
  assert.equal(third.createdNpcIds.length,0);
  assert.equal(Object.keys(w.npcs).length,100);
});

test('bootstrapped NPCs start virtual, unbound and body-unresolved',()=>{
  const w=emptyWorld();
  bootstrap(w);
  for(const n of Object.values(w.npcs)){
    assert.equal(n.origin,'TESLES_GENERATED');
    assert.equal(n.runtimeId,null);
    assert.equal(n.materialized,false);
    assert.equal(n.simulationLod,'VIRTUAL');
    assert.equal(n.materializationState,'VIRTUAL');
    assert.equal(n.bodyProfile,null,'exact SCUM class must stay unproven until runtime confirms it');
    assert.ok(['DRIFTER','GUARD','RADIATION','BUNKER'].includes(n.bodyFamily));
    assert.ok(n.bodyLevel>=1&&n.bodyLevel<=5);
    assert.equal(n.hasEverMaterialized,false);
  }
});

test('a legacy world keeps its NPCs and is only topped up to the target once',()=>{
  const w=emptyWorld();
  w.npcs['legacy-1']=createNpc({npcId:'legacy-1',seed:'legacy',position:{x:0,y:0,z:0}});
  w.npcs['legacy-2']=createNpc({npcId:'legacy-2',seed:'legacy',position:{x:0,y:0,z:0}});
  const r=bootstrap(w,{initialNpcCount:20});
  assert.equal(r.mode,'migrate');
  assert.equal(Object.keys(w.npcs).length,20);
  assert.ok(w.npcs['legacy-1']&&w.npcs['legacy-2']);
  assert.equal(bootstrap(w,{initialNpcCount:20}).createdNpcIds.length,0);
});

test('a legacy world at or above target is preserved without deletion',()=>{
  const w=emptyWorld();
  for(let i=0;i<7;i++)w.npcs[`legacy-${i}`]=createNpc({npcId:`legacy-${i}`,seed:'legacy',position:{x:0,y:0,z:0}});
  const r=bootstrap(w,{initialNpcCount:5});
  assert.equal(r.createdNpcIds.length,0);
  assert.equal(Object.keys(w.npcs).length,7);
  assert.equal(w.meta.population.initialized,true);
});

test('invalid population configuration fails loudly with a precise message',()=>{
  assert.throws(()=>validatePopulationConfig({...POP,initialNpcCount:-4},MAP),/initialNpcCount must be a non-negative integer/);
  assert.throws(()=>validatePopulationConfig({...POP,groupClassWeights:{solo:-1}},MAP),/groupClassWeights\.solo must be a non-negative number/);
  assert.throws(()=>validatePopulationConfig({...POP,groupMemberSpreadCm:99999999},MAP),/groupMemberSpreadCm .* is larger than the map/);
  assert.throws(()=>validatePopulationConfig({...POP,edgeMarginCm:800000},MAP),/leaves no usable area/);
});

test('body profile resolves to verified runtime classes only',()=>{
  const catalog={
    'BP_Guard_Lvl_3':{className:'BP_Guard_Lvl_3',family:'GUARD',level:3,verified:true},
    'BP_Guard_Lvl_5':{className:'BP_Guard_Lvl_5',family:'GUARD',level:5,verified:true},
    'BP_Drifter_Lvl_1':{className:'BP_Drifter_Lvl_1',family:'DRIFTER',level:1,verified:true}
  };
  assert.deepEqual(resolveBodyProfile({bodyFamily:'GUARD',bodyLevel:3},catalog),{ok:true,className:'BP_Guard_Lvl_3',match:'exact_level'});
  const nearest=resolveBodyProfile({bodyFamily:'GUARD',bodyLevel:4},catalog);
  assert.equal(nearest.ok,true);
  assert.equal(nearest.match,'nearest_level');
  assert.equal(nearest.className,'BP_Guard_Lvl_3');
  const radiation=resolveBodyProfile({bodyFamily:'RADIATION',bodyLevel:3},catalog);
  assert.equal(radiation.ok,false);
  assert.match(radiation.reason,new RegExp(BLOCKED_REASON));
  assert.equal(resolveBodyProfile({bodyFamily:'GUARD',bodyLevel:3},{}).ok,false,'an empty catalog can never resolve a body');
  const remembered=resolveBodyProfile({bodyFamily:'GUARD',bodyLevel:1,bodyProfile:'BP_Guard_Lvl_5',hasEverMaterialized:true},catalog);
  assert.equal(remembered.className,'BP_Guard_Lvl_5');
  assert.equal(remembered.match,'previous_materialization');
});

test('body family is never crossed silently',()=>{
  const catalog={'BP_Drifter_Lvl_2':{className:'BP_Drifter_Lvl_2',family:'DRIFTER',level:2,verified:true}};
  assert.equal(resolveBodyProfile({bodyFamily:'GUARD',bodyLevel:2},catalog).ok,false);
});

test('unverified catalog entries are ignored',()=>{
  const catalog={'BP_Guard_Lvl_1':{className:'BP_Guard_Lvl_1',family:'GUARD',level:1,verified:false}};
  assert.equal(resolveBodyProfile({bodyFamily:'GUARD',bodyLevel:1},catalog).ok,false);
});
