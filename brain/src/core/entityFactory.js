'use strict';
const { archetypes }=require('../archetypes/registry');
const { generateTraits }=require('../traits/generator');
const { generateSkills }=require('../skills/generator');
function createNpc({npcId,seed,archetype='survivor',skillTier=2,bodyProfile='BP_Drifter_Lvl_1',position={x:0,y:0,z:0}}){
 if(!npcId) throw new Error('npcId is required');
 const archetypeDef=archetypes[archetype]||archetypes.survivor;
 const traits=generateTraits({seed,npcId,archetypeDef}); const skills=generateSkills({seed,npcId,skillTier,archetypeDef});
 return {npcId,runtimeId:null,stableKey:null,seed,bodyProfile,archetype,skillTier,traits,skills,experience:{combatEncounters:0,kills:0,zombieEncounters:0,survivedAmbushes:0},stress:0,morale:1,health:1,injuries:[],traumas:[],memories:[],relationships:{},groupId:null,role:'member',position:{...position},destination:null,activity:'idle',simulationLod:'VIRTUAL',alive:true,createdAt:Date.now(),lastUpdate:Date.now()};
}
module.exports={createNpc};
