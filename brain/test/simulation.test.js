const test=require('node:test'); const assert=require('node:assert/strict');
const {WorldDirector}=require('../src/director/worldDirector');
const {legacyDirector}=require('./helpers/legacyDirector');

function seen(d,id,body,x,y,z=0,at=1){d.ingest({type:'NPC_SEEN',npcId:id,body,x,y,z,at});}

test('nearby observed NPCs become a 1-5 member group with leader and class',()=>{
 const d=legacyDirector({seed:'sim'}); seen(d,'a','BP_Guard_Lvl_4',0,0); seen(d,'b','BP_Guard_Lvl_4',200,100); seen(d,'c','BP_Guard_Lvl_3',300,50);
 const groups=Object.values(d.world.groups); assert.equal(groups.length,1); assert.equal(groups[0].members.length,3); assert.ok(groups[0].leaderId); assert.ok(groups[0].level>=1&&groups[0].level<=5); assert.ok(groups[0].members.length<=5);
});

test('radiation body maps to radiation specialist and radiation group class',()=>{
 const d=legacyDirector({seed:'sim'}); seen(d,'r1','BP_Guard_Lvl_5_Radiation',0,0); seen(d,'r2','BP_Guard_Lvl_4_Radiation',100,0);
 assert.equal(d.world.npcs.r1.archetype,'radiation_specialist'); assert.equal(Object.values(d.world.groups)[0].classId,'radiation_team');
});

test('leader death leaves group shock and schedules a new leader',()=>{
 const d=legacyDirector({seed:'sim'}); seen(d,'a','BP_Guard_Lvl_4',0,0); seen(d,'b','BP_Guard_Lvl_4',100,0); const g=Object.values(d.world.groups)[0], old=g.leaderId; d.ingest({type:'NPC_DEATH',npcId:old,at:1000}); assert.equal(g.status,'LEADERLESS'); assert.ok(g.effects.leaderDeathShock>0); d.tick(20); g.successionAt=Date.now()-1; d.tick(1); assert.ok(g.leaderId&&g.leaderId!==old);
});

test('nearby zombies increase group pressure and can change world order',()=>{
 const d=legacyDirector({seed:'sim'}); seen(d,'a','BP_Drifter_Lvl_1',0,0); seen(d,'b','BP_Drifter_Lvl_1',100,0); for(let i=0;i<10;i++)d.ingest({type:'ZOMBIE_SEEN',zombieId:'z'+i,x:150+i*20,y:0,z:0,at:Date.now()}); d.world._nextZombieEval=0; d.tick(1); const g=Object.values(d.world.groups)[0]; assert.ok((g.zombiePressure||0)>0); assert.ok(['FLEE','AVOID','FIGHT'].includes(g.zombieResponse));
});

test('virtual hostile groups resolve combat without requiring physical actors',()=>{
 const d=legacyDirector({seed:'sim'}); seen(d,'a1','BP_Guard_Lvl_4',0,0); seen(d,'a2','BP_Guard_Lvl_4',100,0); seen(d,'b1','BP_Drifter_Lvl_1',3000,0); seen(d,'b2','BP_Drifter_Lvl_1',3100,0);
 const gs=Object.values(d.world.groups); assert.equal(gs.length,2); gs[0].relations[gs[1].groupId]=-1;gs[1].relations[gs[0].groupId]=-1; for(const n of Object.values(d.world.npcs)){n.simulationLod='VIRTUAL';n.materialized=false;} d.world._nextGroupCombatEval=0; d.tick(1); assert.ok(d.world.events.some(e=>e.type==='virtual_group_combat'));
});

test('gunshot world event raises stress by distance without hardcoding combat action',()=>{
 const d=legacyDirector({seed:'sim'}); seen(d,'a','BP_Drifter_Lvl_1',0,0); seen(d,'b','BP_Drifter_Lvl_1',50000,0); const beforeA=d.world.npcs.a.stress,beforeB=d.world.npcs.b.stress; d.ingest({type:'GUNSHOT',x:100,y:0,z:0,intensity:1,at:Date.now()}); assert.ok(d.world.npcs.a.stress>beforeA); assert.ok(d.world.npcs.a.stress>d.world.npcs.b.stress-beforeB);
});
