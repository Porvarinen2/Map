'use strict';
const { archetypes }=require('../archetypes/registry');
const { generateTraits }=require('../traits/generator');
const { generateSkills }=require('../skills/generator');

// Runtime-only NPC fields. They describe the physical SCUM actor of the current
// bridge session and must never be treated as persistent truth: a save/reload
// cycle always returns the entity to a purely virtual state.
const RUNTIME_NPC_FIELDS=Object.freeze([
  'runtimeId','materialized','simulationLod','desiredSimulationLod','materializationState',
  'materializeRequestedAt','dematerializeEligibleAt','spawnRetryAt','spawnAttempts',
  'spawnBlockedReason','pendingCommandSeq','runtimeGeneration','aiIntent','lastSeenAt',
  'lastLodEvalAt','navigation','desiredAccuracyMultiplier','combatIntent'
]);

function runtimeNpcState(){
  return {
    runtimeId:null,
    materialized:false,
    simulationLod:'VIRTUAL',
    desiredSimulationLod:'VIRTUAL',
    materializationState:'VIRTUAL',
    materializeRequestedAt:null,
    dematerializeEligibleAt:null,
    spawnRetryAt:null,
    spawnAttempts:0,
    spawnBlockedReason:null,
    pendingCommandSeq:null,
    runtimeGeneration:0,
    aiIntent:null
  };
}

function createNpc({npcId,seed,archetype='survivor',skillTier=2,bodyProfile='BP_Drifter_Lvl_1',position={x:0,y:0,z:0},origin='SCUM_OBSERVED',bodyFamily=null,bodyLevel=null,homePosition=null,groupId=null,now=null}={}){
  if(!npcId) throw new Error('npcId is required');
  const archetypeDef=archetypes[archetype]||archetypes.survivor;
  const traits=generateTraits({seed,npcId,archetypeDef});
  const skills=generateSkills({seed,npcId,skillTier,archetypeDef});
  const stamp=Number.isFinite(Number(now))?Number(now):Date.now();
  return {
    npcId,
    stableKey:null,
    seed,
    origin,
    creationSeed:`${seed}|${npcId}`,
    bodyFamily,
    bodyLevel:Number.isFinite(Number(bodyLevel))?Number(bodyLevel):null,
    bodyProfile,
    archetype,
    skillTier,
    traits,
    skills,
    experience:{combatEncounters:0,kills:0,zombieEncounters:0,survivedAmbushes:0},
    stress:0,
    morale:1,
    health:1,
    injuries:[],
    traumas:[],
    memories:[],
    relationships:{},
    groupId,
    role:'member',
    homePosition:homePosition?{...homePosition}:{...position},
    position:{...position},
    destination:null,
    activity:'idle',
    alive:true,
    hasEverMaterialized:false,
    createdAt:stamp,
    lastUpdate:stamp,
    ...runtimeNpcState()
  };
}
module.exports={createNpc,runtimeNpcState,RUNTIME_NPC_FIELDS};
