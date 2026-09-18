const test=require('node:test');
const assert=require('node:assert/strict');
const fs=require('fs');
const os=require('os');
const path=require('path');
const {WorldDirector}=require('../src/director/worldDirector');
const {legacyDirector}=require('./helpers/legacyDirector');
const {createNpc}=require('../src/core/entityFactory');
const {createGroup}=require('../src/groups/classes');
const {classForMembers}=require('../src/groups/autoGroup');
const {saveWorld,loadWorld}=require('../src/persistence/worldStore');

function seen(d,id,body,x,y,z=0,at=Date.now()) { d.ingest({type:'NPC_SEEN',npcId:id,body,x,y,z,at}); }
function mk(id,archetype='survivor',skillTier=3,pos={x:0,y:0,z:0}) { return createNpc({npcId:id,seed:'robust',archetype,skillTier,position:pos}); }

test('persistence rehydrates group members to canonical world NPC objects',()=>{
  const dir=fs.mkdtempSync(path.join(os.tmpdir(),'tesles-canon-'));
  const file=path.join(dir,'world.json');
  const a=mk('a'), b=mk('b');
  const g=createGroup({groupId:'g',classId:'duo',level:2,members:[a,b]});
  const world={version:3,time:0,npcs:{a,b},groups:{g},zombies:{},players:{},events:[],capabilities:{},meta:{seed:'x'}};
  saveWorld(file,world);
  const raw=JSON.parse(fs.readFileSync(file,'utf8'));
  assert.deepEqual(raw.groups.g.memberIds,['a','b']);
  assert.equal('members' in raw.groups.g,false);
  const loaded=loadWorld(file);
  assert.equal(loaded.groups.g.members[0],loaded.npcs.a);
  loaded.groups.g.members[0].stress=.77;
  assert.equal(loaded.npcs.a.stress,.77);
});

test('legacy saves with embedded group members are canonicalized on load',()=>{
  const dir=fs.mkdtempSync(path.join(os.tmpdir(),'tesles-legacy-'));
  const file=path.join(dir,'world.json');
  const a=mk('legacy-a'), embedded=JSON.parse(JSON.stringify(a));
  fs.writeFileSync(file,JSON.stringify({version:2,npcs:{'legacy-a':a},groups:{g:{groupId:'g',members:[embedded],leaderId:'legacy-a'}},zombies:{},players:{}}));
  const loaded=loadWorld(file);
  assert.equal(loaded.groups.g.members[0],loaded.npcs['legacy-a']);
});

test('stress feature flag prevents zombie and gunshot stress mutations',()=>{
  const d=legacyDirector({seed:'no-stress',featureFlags:{stress:false}});
  seen(d,'a','BP_Drifter_Lvl_1',0,0);
  seen(d,'b','BP_Drifter_Lvl_1',100,0);
  const beforeA=d.world.npcs.a.stress;
  d.ingest({type:'GUNSHOT',x:0,y:0,z:0,intensity:1,at:Date.now()});
  for(let i=0;i<12;i++) d.ingest({type:'ZOMBIE_SEEN',zombieId:`z${i}`,x:100+i*5,y:0,z:0,at:Date.now()});
  d.world._nextZombieEval=0; d.tick(1);
  assert.equal(d.world.npcs.a.stress,beforeA);
  assert.equal(d.world.npcs.b.stress,0);
});

test('hostile social families do not auto-merge solely due to proximity',()=>{
  const d=legacyDirector({seed:'factions'});
  const police=mk('police','police',3,{x:0,y:0,z:0}); police.bodyProfile='BP_Guard_Lvl_3'; police.source='SCUM'; d.world.npcs[police.npcId]=police;
  const bandit=mk('bandit','bandit',2,{x:100,y:0,z:0}); bandit.bodyProfile='BP_Drifter_Lvl_2'; bandit.source='SCUM'; d.world.npcs[bandit.npcId]=bandit;
  const {assignNpcToGroup}=require('../src/groups/autoGroup');
  assignNpcToGroup(d.world,police); assignNpcToGroup(d.world,bandit);
  assert.notEqual(police.groupId,bandit.groupId);
});

test('three elite NPCs classify as elite_unit',()=>{
  const members=[mk('e1','elite',5),mk('e2','elite',5),mk('e3','elite',5)];
  assert.equal(classForMembers(members),'elite_unit');
});

test('zombie flee destination points away from proximity-weighted local threat',()=>{
  const d=legacyDirector({seed:'z-flee'});
  const a=mk('a','civilian',1,{x:0,y:0,z:0}); a.traits.fearfulness=1;a.traits.stressResistance=0;a.traits.courage=0;
  const b=mk('b','civilian',1,{x:100,y:0,z:0}); b.traits.fearfulness=1;b.traits.stressResistance=0;b.traits.courage=0;
  d.world.npcs={a,b}; const g=createGroup({groupId:'g',classId:'duo',level:1,members:[a,b]}); d.world.groups={g};
  // Immediate threat to east; weaker distant threat to west must not pull flee target east.
  d.world.zombies={near:{id:'near',position:{x:200,y:0,z:0},lastSeenAt:Date.now()},far:{id:'far',position:{x:-12000,y:0,z:0},lastSeenAt:Date.now()}};
  d._zombieEval();
  assert.equal(g.currentTask,'flee_zombies');
  assert.ok(g.destination.x<0,`expected westward flee, got x=${g.destination.x}`);
});

test('zombie flee task and destination clear after threat disappears',()=>{
  const d=legacyDirector({seed:'z-clear'});
  const a=mk('a','civilian',1),b=mk('b','civilian',1,{x:100,y:0,z:0});a.traits.fearfulness=1;b.traits.fearfulness=1;a.traits.stressResistance=0;b.traits.stressResistance=0;
  d.world.npcs={a,b};const g=createGroup({groupId:'g',classId:'duo',level:1,members:[a,b]});d.world.groups={g};
  d.world.zombies={z:{id:'z',position:{x:100,y:0,z:0},lastSeenAt:Date.now()}};d._zombieEval();assert.equal(g.currentTask,'flee_zombies');
  d.world.zombies={};d._zombieEval();
  assert.equal(g.zombieResponse,'NONE');
  assert.equal(g.currentTask,'idle');
  assert.equal(g.destination,null);
  assert.equal(a.destination,null);
});

test('group combat target is cleared when opponent is no longer nearby or hostile',()=>{
  const d=legacyDirector({seed:'combat-clear'});
  const a1=mk('a1','police',3,{x:0,y:0,z:0}),a2=mk('a2','police',3,{x:100,y:0,z:0});
  const b1=mk('b1','bandit',2,{x:2000,y:0,z:0}),b2=mk('b2','bandit',2,{x:2100,y:0,z:0});
  d.world.npcs={a1,a2,b1,b2};const ga=createGroup({groupId:'ga',classId:'police_patrol',level:3,members:[a1,a2]});const gb=createGroup({groupId:'gb',classId:'bandit_crew',level:2,members:[b1,b2]});d.world.groups={ga,gb};ga.relations.gb=-1;gb.relations.ga=-1;
  // Materialized forces physical combat target rather than virtual resolution.
  a1.materialized=a2.materialized=b1.materialized=b2.materialized=true;
  d._groupCombatEval();assert.equal(ga.combatTargetGroupId,'gb');
  b1.position.x=b2.position.x=50000;d._groupCombatEval();
  assert.equal(ga.combatTargetGroupId,null);assert.notEqual(ga.currentTask,'combat_group');
});

test('nonpersistent trauma decays during world ticks',()=>{
  const d=legacyDirector({seed:'trauma-decay'});seen(d,'a','BP_Drifter_Lvl_1',0,0);
  d.world.npcs.a.traumas=[{id:'t',type:'hypervigilance',trigger:'witness_death',severity:.5,persistent:false}];
  d.tick(86400);
  assert.ok(d.world.npcs.a.traumas[0].severity<.5);
});

test('group relationships evolve over shared time instead of remaining permanently zero',()=>{
  const d=legacyDirector({seed:'rels'});seen(d,'a','BP_Guard_Lvl_3',0,0);seen(d,'b','BP_Guard_Lvl_3',100,0);
  const a=d.world.npcs.a,b=d.world.npcs.b;a.relationships[b.npcId]=0;b.relationships[a.npcId]=0;
  d.tick(120);
  assert.ok(a.relationships[b.npcId]>0);
  assert.ok(b.relationships[a.npcId]>0);
});
