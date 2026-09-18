'use strict';
// Restart soak: prove that persistent NPC identity, squads, deaths and psychology
// survive repeated save/load cycles byte-for-byte semantically. Volatile simulation
// fields (world clock, lastUpdate stamps, per-session runtime state) are excluded
// from the checksum on purpose; everything that defines *who* an NPC is, is not.
const crypto=require('crypto');
const fs=require('fs');
const os=require('os');
const path=require('path');
const {saveWorld,loadWorld}=require('../src/persistence/worldStore');
const {WorldDirector}=require('../src/director/worldDirector');
const {RUNTIME_NPC_FIELDS}=require('../src/core/entityFactory');
const cfg=require('../config/default.json');

const VOLATILE_NPC_FIELDS=new Set([...RUNTIME_NPC_FIELDS,'lastUpdate','nearestPlayerDistanceCm','materializationStateAt','physicalCombatBlockedReason','captureRequestedAt','lastSpawnFailure','lastCaptureFailure']);

function persistentNpcView(npc){
  const out={};
  for(const key of Object.keys(npc).sort()){
    if(VOLATILE_NPC_FIELDS.has(key))continue;
    out[key]=npc[key];
  }
  return out;
}
function persistentChecksum(world){
  const npcs=Object.keys(world.npcs).sort().map(id=>persistentNpcView(world.npcs[id]));
  const groups=Object.keys(world.groups).sort().map(id=>{
    const g=world.groups[id];
    return {groupId:g.groupId,classId:g.classId,level:g.level,leaderId:g.leaderId,status:g.status,
      memberIds:(g.members||[]).map(m=>typeof m==='string'?m:m.npcId).sort(),
      relations:g.relations||{}};
  });
  return crypto.createHash('sha256').update(JSON.stringify({npcs,groups,population:world.meta?.population||null})).digest('hex');
}

function director(world=null,seed='tesles-scum-world'){
  return new WorldDirector({seed,world,map:cfg.map,population:cfg.population,materialization:cfg.materialization,simulation:cfg.simulation});
}

function runSoak({file=null,cycles=50,npcCount=40,seed='tesles-scum-world'}={}){
  const target=file||path.join(fs.mkdtempSync(path.join(os.tmpdir(),'tesles-soak-')),'world.json');
  const d=director(null,seed);
  d.bootstrapPopulation({map:cfg.map,populationConfig:{...cfg.population,initialNpcCount:npcCount},now:1700000000000});
  const all=Object.values(d.world.npcs);

  // Mutate psychology, kill members and force three successions before saving.
  const mutated=[];
  for(const npc of all.slice(0,Math.min(20,all.length))){
    npc.experience.combatEncounters=7;
    npc.memories.push({type:'ambush_survived',importance:0.9,at:1700000000000});
    mutated.push(npc.npcId);
  }
  const killed=[];
  const multiMemberGroups=Object.values(d.world.groups).filter(g=>g.members.length>1);
  for(const g of multiMemberGroups.slice(0,3)){
    const leader=g.members.find(m=>m.npcId===g.leaderId)||g.members[0];
    d._handleNpcDeath({npcId:leader.npcId,at:1700000000000});
    killed.push(leader.npcId);
  }
  for(const npc of all.filter(n=>n.alive&&!killed.includes(n.npcId)).slice(0,2)){
    d._handleNpcDeath({npcId:npc.npcId,at:1700000000000});
    killed.push(npc.npcId);
  }
  d.tick(6); // let succession, morale and stress settle before the baseline is taken
  const expectedStress={};
  for(const id of mutated)expectedStress[id]=d.world.npcs[id].stress;
  saveWorld(target,d.world);

  const baseline=persistentChecksum(d.world);
  const baselineIds=Object.keys(d.world.npcs).sort().join(',');
  const baselineLeaders=Object.values(d.world.groups).map(g=>`${g.groupId}:${g.leaderId}`).sort().join(',');
  const result={cycles:0,checksumStable:true,npcCountStable:true,deadStayDead:true,leadersStable:true,runtimeStateAlwaysClear:true,mutationsPreserved:true,driftAtCycle:null,checksum:baseline};

  for(let i=1;i<=cycles;i++){
    const world=loadWorld(target);
    const reloaded=director(world,seed);
    reloaded.bootstrapPopulation({map:cfg.map,populationConfig:{...cfg.population,initialNpcCount:npcCount}});
    const npcs=reloaded.world.npcs;
    if(Object.keys(npcs).sort().join(',')!==baselineIds)result.npcCountStable=false;
    if(!killed.every(id=>npcs[id]&&npcs[id].alive===false))result.deadStayDead=false;
    if(!mutated.every(id=>npcs[id]&&npcs[id].stress===expectedStress[id]&&npcs[id].experience.combatEncounters===7&&npcs[id].memories.some(m=>m.type==='ambush_survived')))result.mutationsPreserved=false;
    if(!Object.values(npcs).every(n=>n.runtimeId===null&&n.materialized===false&&n.materializationState==='VIRTUAL'))result.runtimeStateAlwaysClear=false;
    const leaders=Object.values(reloaded.world.groups).map(g=>`${g.groupId}:${g.leaderId}`).sort().join(',');
    if(leaders!==baselineLeaders)result.leadersStable=false;
    const checksum=persistentChecksum(reloaded.world);
    if(checksum!==baseline&&result.checksumStable){result.checksumStable=false;result.driftAtCycle=i;}
    saveWorld(target,reloaded.world);
    result.cycles=i;
  }
  return result;
}

if(require.main===module){
  const cycles=Number(process.argv[2])||50;
  const result=runSoak({cycles});
  console.log(JSON.stringify(result,null,2));
  const ok=result.checksumStable&&result.npcCountStable&&result.deadStayDead&&result.leadersStable&&result.runtimeStateAlwaysClear&&result.mutationsPreserved;
  console.log(ok?`[TeslesNPC] restart soak passed ${result.cycles} cycles`:'[TeslesNPC] restart soak FAILED');
  process.exitCode=ok?0:1;
}
module.exports={runSoak,persistentChecksum,persistentNpcView};
