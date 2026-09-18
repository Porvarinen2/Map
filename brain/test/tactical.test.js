const test=require('node:test'); const assert=require('node:assert/strict');
const {tacticalDestination,formationOffset}=require('../src/navigation/tactical');
const {createNpc}=require('../src/core/entityFactory');

test('skilled flanker chooses lateral point rather than direct target',()=>{
 const n=createNpc({npcId:'f',seed:1,archetype:'ex_military',skillTier:4,position:{x:0,y:0,z:0}});n.skills.tacticalMovement=.9;
 const p=tacticalDestination(n,{x:10000,y:0,z:0},'FLANK',{groupId:'g'});
 assert.notEqual(Math.round(p.y),0); assert.ok(p.x>3000&&p.x<11000);
});

test('untrained NPC direct approach stays near target line',()=>{
 const n=createNpc({npcId:'u',seed:2,archetype:'civilian',skillTier:1,position:{x:0,y:0,z:0}});n.skills.tacticalMovement=.05;
 const p=tacticalDestination(n,{x:10000,y:0,z:0},'ATTACK',{groupId:'g'}); assert.ok(Math.abs(p.y)<500);
});

test('formation offsets are deterministic and leader differs from member',()=>{
 const a=formationOffset('npc-a','leader',4),b=formationOffset('npc-b','member',4),b2=formationOffset('npc-b','member',4); assert.deepEqual(b,b2); assert.notDeepEqual(a,b);
});
