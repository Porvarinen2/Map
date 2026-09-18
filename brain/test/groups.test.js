const test=require('node:test'); const assert=require('node:assert/strict');
const {groupClasses,createGroup}=require('../src/groups/classes');
const {selectLeader,onLeaderDeath,processSuccession}=require('../src/groups/leadership');
const {setRelationState,relationState,adjustGroupRelation}=require('../src/groups/diplomacy');
const {createNpc}=require('../src/core/entityFactory');
function npc(id,lead=.5,courage=.5,discipline=.5){const n=createNpc({npcId:id,seed:id,archetype:'survivor',skillTier:3});n.traits.leadership=lead;n.traits.courage=courage;n.traits.discipline=discipline;n.skills.leadership=lead;return n;}

test('group classes enforce 1-5 members and group level 1-5',()=>{
 assert.equal(groupClasses.solo.minSize,1); assert.equal(groupClasses.solo.maxSize,1); assert.equal(groupClasses.ex_military.maxSize,5);
 assert.throws(()=>createGroup({groupId:'bad',classId:'duo',level:6,members:[]}));
 const g=createGroup({groupId:'g',classId:'hunters',level:3,members:[npc('a'),npc('b'),npc('c')]}); assert.equal(g.level,3); assert.equal(g.members.length,3);
});

test('leader selection prefers leadership, trust and discipline',()=>{
 const a=npc('a',.9,.8,.9), b=npc('b',.2,.9,.2); const g=createGroup({groupId:'g2',classId:'duo',level:3,members:[a,b]}); const leader=selectLeader(g); assert.equal(leader.npcId,'a'); assert.equal(g.leaderId,'a');
});

test('leader death causes morale shock then succession while residual shock remains',()=>{
 const a=npc('a',.9,.8,.9), b=npc('b',.7,.8,.8), c=npc('c',.6,.7,.7); const g=createGroup({groupId:'g3',classId:'ex_military',level:4,members:[a,b,c]}); selectLeader(g); const old=g.leaderId; onLeaderDeath(g,old,{at:1000,severity:1}); assert.equal(g.status,'LEADERLESS'); assert.ok(g.morale<1); processSuccession(g,{now:1000+g.successionDelayMs+1}); assert.notEqual(g.leaderId,old); assert.equal(g.status,'ACTIVE'); assert.ok(g.effects.leaderDeathShock>0);
});

test('diplomacy transitions to blood feud at extreme hostility',()=>{
 const g=createGroup({groupId:'ga',classId:'bandit_crew',level:2,members:[npc('a')]}); setRelationState(g,'gb',0); adjustGroupRelation(g,'gb',-1); assert.equal(relationState(g,'gb'),'BLOOD_FEUD');
});

test('neutral baseline is neutral and mild negative relation is suspicious',()=>{
 const g=createGroup({groupId:'rel',classId:'solo',level:1,members:[npc('rel-n')]});
 setRelationState(g,'other',0); assert.equal(relationState(g,'other'),'NEUTRAL');
 setRelationState(g,'other',-.2); assert.equal(relationState(g,'other'),'SUSPICIOUS');
});

test('two ex-military NPCs remain a duo until class minimum size is met',()=>{
 const {classForMembers}=require('../src/groups/autoGroup');
 const a=npc('xm-a'), b=npc('xm-b'); a.archetype='ex_military'; b.archetype='ex_military';
 assert.equal(classForMembers([a,b]),'duo');
});

test('peer trust contributes to leadership selection',()=>{
 const a=npc('trust-a',.6,.6,.6), b=npc('trust-b',.6,.6,.6), c=npc('trust-c',.6,.6,.6);
 a.relationships={'trust-b':.9,'trust-c':-.8};
 b.relationships={'trust-a':-.8,'trust-c':-.8};
 c.relationships={'trust-a':-.5,'trust-b':.9};
 const g=createGroup({groupId:'trust-g',classId:'ex_military',level:3,members:[a,b,c]});
 const leader=selectLeader(g); assert.equal(leader.npcId,'trust-b');
});
