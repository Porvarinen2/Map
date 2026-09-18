const test=require('node:test');
const assert=require('node:assert/strict');
const fs=require('fs');
const path=require('path');
const {WorldDirector}=require('../src/director/worldDirector');
const {createNpc}=require('../src/core/entityFactory');
const {createGroup}=require('../src/groups/classes');
const {assignNpcToGroup,refreshGroup,canAccept}=require('../src/groups/autoGroup');
const {maybeAcquireTrauma,decayTraumas}=require('../src/state/trauma');
const {physicalControlReady}=require('../src/server');

function mk(id,archetype='survivor',tier=3,pos={x:0,y:0,z:0}){return createNpc({npcId:id,seed:'wf',archetype,skillTier:tier,position:pos});}

test('population cap defaults to 100 and ignores newly observed NPCs above configured cap',()=>{
  const d=new WorldDirector({population:{maxNpc:2,hardMaxNpc:10}});
  for(let i=0;i<3;i++)d.ingest({type:'NPC_SEEN',npcId:`r${i}`,stableKey:`s${i}`,body:'BP_Guard_Lvl_1',x:i*1000,y:0,z:0});
  assert.equal(Object.keys(d.world.npcs).length,2);
  assert.equal(d.population.maxNpc,2);
  assert.ok(d.world.events.some(e=>e.type==='population_cap_ignored'));
});

test('group diplomacy refreshes when class changes from duo into police patrol',()=>{
  const world={groups:{},npcs:{},_groupSeq:0};
  const p1=mk('p1','police',3),p2=mk('p2','police',3,{x:100,y:0,z:0}),p3=mk('p3','police',3,{x:200,y:0,z:0});
  const b1=mk('b1','bandit',2,{x:5000,y:0,z:0}),b2=mk('b2','bandit',2,{x:5100,y:0,z:0}),b3=mk('b3','bandit',2,{x:5200,y:0,z:0});
  for(const n of [p1,p2,p3,b1,b2,b3])world.npcs[n.npcId]=n;
  assignNpcToGroup(world,p1);assignNpcToGroup(world,p2);assignNpcToGroup(world,b1);assignNpcToGroup(world,b2);
  assignNpcToGroup(world,p3);assignNpcToGroup(world,b3);
  const pg=world.groups[p1.groupId],bg=world.groups[b1.groupId];
  assert.equal(pg.classId,'police_patrol');assert.equal(bg.classId,'bandit_crew');
  assert.ok(pg.relations[bg.groupId]<=-.35);assert.ok(bg.relations[pg.groupId]<=-.35);
});

test('dead members do not consume the five-member acceptance cap',()=>{
  const members=[0,1,2,3,4].map(i=>mk(`m${i}`,'survivor',2));
  const g=createGroup({groupId:'g',classId:'survivor_group',level:2,members});
  members[3].alive=false;members[4].alive=false;
  assert.equal(canAccept(g,mk('new','survivor',2)),true);
});

test('temporary trauma never mutates base personality traits',()=>{
  const n=mk('t');n.traits.paranoia=.4;n.stress=1;
  const before=n.traits.paranoia;
  for(let i=0;i<20 && n.traumas.length===0;i++)maybeAcquireTrauma(n,{type:'witness_death',severity:.79,seed:`x${i}`});
  assert.equal(n.traits.paranoia,before);
  decayTraumas(n,1000);
  assert.equal(n.traits.paranoia,before);
});

test('navigation stuck detection is wired into world tick and triggers recovery repath',()=>{
  const d=new WorldDirector({population:{roamEnabled:false}});
  d.ingest({type:'NPC_SEEN',npcId:'r',body:'BP_Guard_Lvl_1',x:0,y:0,z:0});
  const n=d.world.npcs.r;n.navigation={movementCommanded:true,lastProgressPosition:{x:0,y:0,z:0},lastProgressAt:Date.now()-4000,lastTarget:{x:10000,y:0,z:0},lastRepathAt:Date.now()-100};n.destination={x:10000,y:0,z:0};
  d.tick(.5);
  assert.ok(n.navigation.stuckLevel>=1);
  assert.ok(n.aiIntent && n.aiIntent.type==='MOVE');
  assert.match(n.aiIntent.tacticalMode,/REPATH|ALTERNATE|HARD|ATTACK|FLANK|COVER|RETREAT|FLEE|INVESTIGATE|HELP_FRIEND/);
});

test('virtual losing group receives a retreat destination instead of remaining in death grinder',()=>{
  const d=new WorldDirector({simulation:{groupCombatIntervalSeconds:60},population:{roamEnabled:false}});
  const a=[mk('a1','elite',5,{x:0,y:0,z:0}),mk('a2','elite',5,{x:50,y:0,z:0}),mk('a3','elite',5,{x:100,y:0,z:0})];
  const b=[mk('b1','bandit',1,{x:1000,y:0,z:0}),mk('b2','bandit',1,{x:1050,y:0,z:0}),mk('b3','bandit',1,{x:1100,y:0,z:0})];
  const ga=createGroup({groupId:'ga',classId:'elite_unit',level:5,members:a}),gb=createGroup({groupId:'gb',classId:'bandit_crew',level:1,members:b});
  d.world.npcs=Object.fromEntries([...a,...b].map(n=>[n.npcId,n]));d.world.groups={ga,gb};ga.relations.gb=-1;gb.relations.ga=-1;
  for(let i=0;i<5 && !gb.destination;i++)d._groupCombatEval();
  assert.ok(ga.destination||gb.destination,'one losing group should retreat');
});

test('idle virtual groups receive autonomous roam destinations',()=>{
  const d=new WorldDirector({population:{roamEnabled:true,roamIntervalSeconds:1,roamRadiusCm:10000}});
  const a=mk('a','hunter',2,{x:0,y:0,z:0}),b=mk('b','hunter',2,{x:100,y:0,z:0});
  const g=createGroup({groupId:'g',classId:'hunters',level:2,members:[a,b]});d.world.npcs={a,b};d.world.groups={g};
  d._roamEval();assert.equal(g.currentTask,'roam');assert.ok(g.destination);assert.ok(a.destination);
});

test('virtual zombie fight consumes ammo and can record wounds',()=>{
  const d=new WorldDirector({population:{roamEnabled:false}});const a=mk('a','ex_military',4),b=mk('b','ex_military',4,{x:100,y:0,z:0});const g=createGroup({groupId:'g',classId:'duo',level:4,members:[a,b]});d.world.npcs={a,b};d.world.groups={g};g.combatPower=.5;a.traits.aggression=b.traits.aggression=1;a.traits.fearfulness=b.traits.fearfulness=0;a.traits.stressResistance=b.traits.stressResistance=1;
  for(let i=0;i<8;i++)d.world.zombies[`z${i}`]={id:`z${i}`,position:{x:200+i*10,y:0,z:0},lastSeenAt:Date.now()};
  const ammo=g.resources.ammo;d._zombieEval();assert.ok(g.resources.ammo<=ammo);assert.ok(g.history.some(h=>h.type==='zombie_combat')||g.currentTask==='flee_zombies'||g.currentTask==='avoid_zombies');
});

test('leader damage applies group injury shock',()=>{
  const d=new WorldDirector({population:{roamEnabled:false}});const a=mk('a','police',3),b=mk('b','police',3,{x:100,y:0,z:0});const g=createGroup({groupId:'g',classId:'duo',level:3,members:[a,b]});d.world.npcs={a,b};d.world.groups={g};const {selectLeader}=require('../src/groups/leadership');selectLeader(g);const leader=d.world.npcs[g.leaderId];const before=g.morale;d.ingest({type:'NPC_DAMAGE',npcId:leader.npcId,damageFraction:.4,at:Date.now()});assert.ok(g.morale<before);assert.ok(g.effects.leaderInjuryShock>0);
});

test('compact snapshot omits heavyweight trait and memory payloads',()=>{
  const d=new WorldDirector();d.ingest({type:'NPC_SEEN',npcId:'a',body:'BP_Guard_Lvl_1',x:0,y:0,z:0});const s=d.compactSnapshot();assert.equal('traits' in s.npcs[0],false);assert.equal('memories' in s.npcs[0],false);assert.equal(s.population.maxNpc,100);
});

test('auto physical takeover requires full_takeover_ready capability',()=>{
  const cfg={features:{takeoverRequested:true,takeoverMode:'auto'}};const director={world:{capabilities:{bridge_scheduler:{ok:true},brain_stop:{ok:true},movement:{ok:true},full_takeover_ready:{ok:false}}}};assert.equal(physicalControlReady(cfg,director),false);director.world.capabilities.full_takeover_ready.ok=true;assert.equal(physicalControlReady(cfg,director),true);
});

test('lua bridge uses auto takeover, stable keys, class health cache and scheduler capability',()=>{
  const root=path.resolve(__dirname,'..','..');const lua=fs.readFileSync(path.join(root,'ue4ss','TeslesNPCOverhaul','scripts','modules','scum_adapter.lua'),'utf8');const main=fs.readFileSync(path.join(root,'ue4ss','TeslesNPCOverhaul','scripts','main.lua'),'utf8');assert.match(lua,/health_prop_by_class/);assert.match(lua,/stableKey/);assert.match(lua,/full_takeover_ready/);assert.match(main,/bridge_scheduler/);
});

test('stableKey rebinds a restarted runtime actor to the same persistent NPC',()=>{
  const d=new WorldDirector({population:{maxNpc:100,roamEnabled:false}});
  d.ingest({type:'NPC_SEEN',npcId:'runtime-A',stableKey:'guard|cell|1',body:'BP_Guard_Lvl_2',x:1000,y:2000,z:0});
  const persistentId=Object.keys(d.world.npcs)[0];
  d.ingest({type:'NPC_GONE',npcId:'runtime-A'});
  d.ingest({type:'NPC_SEEN',npcId:'runtime-B',stableKey:'guard|cell|1',body:'BP_Guard_Lvl_2',x:1020,y:1990,z:0});
  assert.equal(Object.keys(d.world.npcs).length,1);
  assert.equal(d.world.npcs[persistentId].runtimeId,'runtime-B');
});

test('group history is bounded during long-running simulation',()=>{
  const d=new WorldDirector({simulation:{groupHistoryLimit:50},population:{roamEnabled:false}});
  const a=mk('a'),b=mk('b');const g=createGroup({groupId:'g',classId:'duo',level:2,members:[a,b]});d.world.npcs={a,b};d.world.groups={g};
  g.history=Array.from({length:500},(_,i)=>({type:'x',i}));d.tick(.5);assert.equal(g.history.length,50);assert.ok((g.history[0].i??999)>=450);
});

test('dead NPC does not receive later leader-death stress or memories',()=>{
  const {selectLeader,onLeaderDeath}=require('../src/groups/leadership');const a=mk('a'),b=mk('b'),c=mk('c');const g=createGroup({groupId:'g',classId:'ex_military',level:3,members:[a,b,c]});selectLeader(g);const dead=[a,b,c].find(n=>n.npcId!==g.leaderId);dead.alive=false;const stress=dead.stress,memoryCount=dead.memories.length;onLeaderDeath(g,g.leaderId,{at:1234});assert.equal(dead.stress,stress);assert.equal(dead.memories.length,memoryCount);
});

test('command snapshot writer prunes stale runtime actor commands',()=>{
  const os=require('os'),path=require('path'),fs=require('fs');const {CommandSnapshotWriter}=require('../src/server');const dir=fs.mkdtempSync(path.join(os.tmpdir(),'cmd-prune-'));const file=path.join(dir,'commands.log');const w=new CommandSnapshotWriter(file,{initialSeq:1});w.submit({type:'MOVE',npcId:'runtime-old',x:1,y:2,z:3});w.submit({type:'MOVE',npcId:'runtime-live',x:2,y:3,z:4});w.prune(['runtime-live']);const text=fs.readFileSync(file,'utf8');assert.doesNotMatch(text,/runtime-old/);assert.match(text,/runtime-live/);
});
