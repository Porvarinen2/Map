const test=require('node:test'); const assert=require('node:assert/strict');
const {applyStressEvent,recoverStress,stressState}=require('../src/state/stress');
const {maybeAcquireTrauma}=require('../src/state/trauma');
const {remember,pruneMemories}=require('../src/memory/memory');
const {adjustRelation}=require('../src/relationships/relations');
const {createNpc}=require('../src/core/entityFactory');

test('fearful low-resistance NPC gains more gunshot stress',()=>{
 const a=createNpc({npcId:'a',seed:1,archetype:'civilian',skillTier:1}); const b=createNpc({npcId:'b',seed:1,archetype:'ex_military',skillTier:4});
 a.traits.fearfulness=.9; a.traits.courage=.2; a.traits.stressResistance=.1;
 b.traits.fearfulness=.2; b.traits.courage=.8; b.traits.stressResistance=.9;
 applyStressEvent(a,{type:'gunshot',intensity:1,distance:10}); applyStressEvent(b,{type:'gunshot',intensity:1,distance:10});
 assert.ok(a.stress>b.stress); assert.ok(a.stress>0);
});

test('stress recovers and state bands are stable',()=>{
 const n=createNpc({npcId:'x',seed:2}); n.stress=.9; recoverStress(n,60); assert.ok(n.stress<.9); assert.equal(stressState(.95),'PANIC'); assert.equal(stressState(.1),'CALM');
});

test('severe witnessed death can create persistent trauma',()=>{
 const n=createNpc({npcId:'t',seed:3}); n.traits.fearfulness=.95; n.traits.stressResistance=.05; n.stress=.95;
 const trauma=maybeAcquireTrauma(n,{type:'witness_death',severity:1,source:'leader',seed:'forced'});
 assert.ok(trauma); assert.ok(n.traumas.length>=1);
});

test('memory pruning keeps important recent events and relation changes clamp',()=>{
 const n=createNpc({npcId:'m',seed:4}); remember(n,{type:'leader_death',importance:1,at:100}); remember(n,{type:'noise',importance:.1,at:1}); pruneMemories(n,{now:1000,max:1});
 assert.equal(n.memories.length,1); assert.equal(n.memories[0].type,'leader_death');
 adjustRelation(n,'npc-2',2); assert.equal(n.relationships['npc-2'],1); adjustRelation(n,'npc-2',-3); assert.equal(n.relationships['npc-2'],-1);
});
