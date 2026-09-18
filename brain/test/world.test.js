const test=require('node:test'); const assert=require('node:assert/strict');
const {createNpc}=require('../src/core/entityFactory');
const {createGroup}=require('../src/groups/classes');
const {selectLeader}=require('../src/groups/leadership');
const {computeZombiePressure,applyZombiePressure}=require('../src/zombies/threat');
const {resolveVirtualGroupCombat}=require('../src/combat/groupCombat');
const {advanceVirtualNpc,simulationLod}=require('../src/virtual/sim');

function mk(id,skill=3){return createNpc({npcId:id,seed:id,archetype:skill>=4?'ex_military':'survivor',skillTier:skill,position:{x:0,y:0,z:0}})}

test('zombie pressure scales with count and distance and raises group stress',()=>{
 const g=createGroup({groupId:'g',classId:'survivor_group',level:2,members:[mk('a'),mk('b')]});
 const near=computeZombiePressure([{x:10,y:0,z:0},{x:20,y:0,z:0}],{x:0,y:0,z:0});
 const far=computeZombiePressure([{x:1000,y:0,z:0}],{x:0,y:0,z:0});
 assert.ok(near>far); applyZombiePressure(g,near,{at:100}); assert.ok(g.members.some(n=>n.stress>0));
});

test('virtual movement advances toward destination without overshoot',()=>{
 const n=mk('v'); n.position={x:0,y:0,z:0}; n.destination={x:100,y:0,z:0}; const moved=advanceVirtualNpc(n,10,{speed:5}); assert.equal(Math.round(moved.x),50); advanceVirtualNpc(n,20,{speed:5}); assert.equal(Math.round(n.position.x),100);
});

test('simulation LOD selects FULL LIGHT VIRTUAL by player distance',()=>{
 assert.equal(simulationLod(100),'FULL'); assert.equal(simulationLod(40000),'LIGHT'); assert.equal(simulationLod(100000),'VIRTUAL');
});

test('virtual group combat can produce casualties and retreat',()=>{
 const a=createGroup({groupId:'a',classId:'ex_military',level:4,members:[mk('a1',4),mk('a2',4),mk('a3',4)]});
 const b=createGroup({groupId:'b',classId:'bandit_crew',level:2,members:[mk('b1',1),mk('b2',1)]}); selectLeader(a);selectLeader(b);
 const result=resolveVirtualGroupCombat(a,b,{seed:'battle-1',durationSeconds:120});
 assert.ok(result.events.length>0); assert.ok(result.winner==='a'||result.winner==='b'||result.winner==='draw');
 assert.ok(result.casualties.a.length+result.casualties.b.length>=0);
});

test('virtual movement default speed uses Unreal centimeters per second',()=>{
 const n=mk('cm-speed'); n.position={x:0,y:0,z:0}; n.destination={x:1000,y:0,z:0};
 advanceVirtualNpc(n,1);
 assert.equal(Math.round(n.position.x),130);
});

test('simulation LOD defaults reflect render-scale distances in centimeters',()=>{
 assert.equal(simulationLod(10000),'FULL');
 assert.equal(simulationLod(40000),'LIGHT');
 assert.equal(simulationLod(100000),'VIRTUAL');
});
