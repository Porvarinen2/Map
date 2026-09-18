const test=require('node:test'); const assert=require('node:assert/strict');
const {createNpc}=require('../src/core/entityFactory');
const {scoreActions,chooseAction}=require('../src/ai/utility');
const {shouldRepath,updateNavigationState}=require('../src/navigation/policy');
function mk(){return createNpc({npcId:'n',seed:55,archetype:'ex_military',skillTier:4});}

test('high stress fearful NPC prefers retreat over attack',()=>{
 const n=mk();n.traits.aggression=.3;n.traits.courage=.2;n.traits.fearfulness=.95;n.traits.survivalInstinct=.95;n.stress=.95;
 const scores=scoreActions(n,{enemyStrength:1.5,ownStrength:.7,hasCover:true,leaderOrder:null,zombiePressure:0});
 assert.ok(scores.RETREAT>scores.ATTACK);
});

test('action inertia prevents tiny score oscillation',()=>{
 const n=mk(); n.ai={action:'ATTACK',actionScore:.70}; const picked=chooseAction(n,{ATTACK:.69,RETREAT:.74,COVER:.4},{switchMargin:.1}); assert.equal(picked.action,'ATTACK');
 const picked2=chooseAction(n,{ATTACK:.50,RETREAT:.80,COVER:.4},{switchMargin:.1}); assert.equal(picked2.action,'RETREAT');
});

test('repath requires movement threshold age or failure',()=>{
 const state={lastTarget:{x:0,y:0,z:0},lastRepathAt:1000,pathFailed:false};
 assert.equal(shouldRepath(state,{x:100,y:0,z:0},{now:1500,threshold:300,maxAgeMs:2000}),false);
 assert.equal(shouldRepath(state,{x:400,y:0,z:0},{now:1500,threshold:300,maxAgeMs:2000}),true);
 assert.equal(shouldRepath(state,{x:0,y:0,z:0},{now:4000,threshold:300,maxAgeMs:2000}),true);
});

test('navigation state detects lack of progress and chooses recovery',()=>{
 let s={position:{x:0,y:0,z:0},lastProgressPosition:{x:0,y:0,z:0},lastProgressAt:0,stuckLevel:0};
 s=updateNavigationState(s,{x:0,y:0,z:0},{now:4000,stuckTimeoutMs:2500,progressThreshold:50});
 assert.equal(s.stuck,true); assert.equal(s.recovery,'REPATH');
 s=updateNavigationState(s,{x:0,y:0,z:0},{now:8000,stuckTimeoutMs:2500,progressThreshold:50}); assert.ok(['ALTERNATE_WAYPOINT','HARD_RECOVERY'].includes(s.recovery));
});

test('movement intent serializes flat SCUM coordinates and acceptance radius',()=>{
 const {buildMovementIntent}=require('../src/navigation/policy');
 const intent=buildMovementIntent({npcId:'n1'},{x:100,y:-50,z:25},{preferredRange:300,urgency:.8,tacticalMode:'FLANK'});
 assert.equal(intent.type,'MOVE');
 assert.equal(intent.npcId,'n1');
 assert.equal(intent.x,100); assert.equal(intent.y,-50); assert.equal(intent.z,25);
 assert.equal(intent.acceptanceRadius,300);
 assert.equal('target' in intent,false);
});
