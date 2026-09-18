'use strict';
// Materialization scheduling: which queued physical transitions are allowed to run
// this tick, and where a first spawn may be attempted. Pure functions only - no
// UE4SS calls, no IPC, no mutation of persistent entity state.

// Deterministic candidate ring around the entity's virtual position, used when the
// first placement attempt is rejected by the game (no navmesh, blocked, water).
const candidateOffsetsCm=Object.freeze([
  [0,0],
  [1000,0],[-1000,0],[0,1000],[0,-1000],
  [2500,0],[-2500,0],[0,2500],[0,-2500],
  [5000,0],[-5000,0],[0,5000],[0,-5000],
  [10000,0],[-10000,0],[0,10000],[0,-10000]
].map(Object.freeze));

function placementCandidate(position,attempt=0){
  const index=Math.max(0,Math.floor(Number(attempt)||0))%candidateOffsetsCm.length;
  const [dx,dy]=candidateOffsetsCm[index];
  return {x:(position?.x??0)+dx,y:(position?.y??0)+dy,z:position?.z??0,offsetIndex:index};
}

function lodRank(lod){return lod==='FULL'?0:lod==='LIGHT'?1:2;}

/**
 * Order and budget queued materialization work.
 * Priority: nearest player first, then group cohesion with an already materializing
 * group, then FULL before LIGHT, then oldest queue entry.
 */
function selectMaterializationWork(intents=[],{
  maxMaterializePerTick=2,
  maxDematerializePerTick=5,
  materializingGroupIds=[]
}={}){
  const cohesive=new Set(materializingGroupIds||[]);
  const spawns=intents.filter(i=>i&&i.type==='SPAWN');
  const despawns=intents.filter(i=>i&&i.type==='CAPTURE_AND_DESPAWN');
  spawns.sort((a,b)=>{
    const da=Number.isFinite(a.nearestPlayerDistance)?a.nearestPlayerDistance:Number.POSITIVE_INFINITY;
    const db=Number.isFinite(b.nearestPlayerDistance)?b.nearestPlayerDistance:Number.POSITIVE_INFINITY;
    if(da!==db)return da-db;
    const ca=cohesive.has(a.groupId)?0:1,cb=cohesive.has(b.groupId)?0:1;
    if(ca!==cb)return ca-cb;
    const la=lodRank(a.desiredLod),lb=lodRank(b.desiredLod);
    if(la!==lb)return la-lb;
    const qa=Number(a.queuedAt)||0,qb=Number(b.queuedAt)||0;
    if(qa!==qb)return qa-qb;
    return String(a.persistentNpcId).localeCompare(String(b.persistentNpcId));
  });
  despawns.sort((a,b)=>{
    const qa=Number(a.queuedAt)||0,qb=Number(b.queuedAt)||0;
    if(qa!==qb)return qa-qb;
    return String(a.persistentNpcId).localeCompare(String(b.persistentNpcId));
  });
  return {
    materialize:spawns.slice(0,Math.max(0,maxMaterializePerTick)),
    dematerialize:despawns.slice(0,Math.max(0,maxDematerializePerTick)),
    queuedMaterialize:spawns.length,
    queuedDematerialize:despawns.length
  };
}
module.exports={selectMaterializationWork,placementCandidate,candidateOffsetsCm};
