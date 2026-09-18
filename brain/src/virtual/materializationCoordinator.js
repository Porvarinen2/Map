'use strict';
// Pure materialization state machine. It owns the decision of *when* a persistent
// TeslesNPCEntity needs a physical SCUM actor and when that actor may be removed.
// It never performs IPC, never touches files and never destroys state: every
// failure path keeps the persistent entity (and, on capture failure, the actor)
// exactly as it was.
const STATES=Object.freeze({
  VIRTUAL:'VIRTUAL',
  SPAWN_QUEUED:'SPAWN_QUEUED',
  SPAWNING:'SPAWNING',
  MATERIALIZED:'MATERIALIZED',
  DESPAWN_GRACE:'DESPAWN_GRACE',
  DESPAWN_QUEUED:'DESPAWN_QUEUED',
  CAPTURING:'CAPTURING',
  SPAWN_BACKOFF:'SPAWN_BACKOFF'
});

const DEFAULTS=Object.freeze({
  dematerializeGraceMs:5000,
  spawnRetryMs:10000,
  spawnBackoffMaxMs:120000,
  spawnCommandTimeoutMs:15000,
  captureCommandTimeoutMs:15000
});

function state(npc){return npc.materializationState||STATES.VIRTUAL;}
function setState(npc,next,now){
  if(npc.materializationState!==next){npc.materializationState=next;npc.materializationStateAt=now;}
  return next;
}
function backoffMs(attempts,{spawnRetryMs,spawnBackoffMaxMs}){
  const n=Math.max(1,Number(attempts)||1);
  return Math.min(spawnBackoffMaxMs,spawnRetryMs*Math.pow(2,n-1));
}
function spawnIntent(npc,desiredLod,now){
  return {
    type:'SPAWN',
    persistentNpcId:npc.npcId,
    bodyFamily:npc.bodyFamily||null,
    bodyLevel:npc.bodyLevel||null,
    bodyProfile:npc.bodyProfile||null,
    groupId:npc.groupId||null,
    desiredLod,
    x:npc.position?.x??0,
    y:npc.position?.y??0,
    z:npc.position?.z??0,
    queuedAt:npc.materializeRequestedAt||now,
    attempt:(npc.spawnAttempts||0)+1
  };
}
function captureIntent(npc,now){
  return {
    type:'CAPTURE_AND_DESPAWN',
    persistentNpcId:npc.npcId,
    runtimeId:npc.runtimeId||null,
    groupId:npc.groupId||null,
    queuedAt:npc.dematerializeEligibleAt||now
  };
}

/**
 * Advance one entity's materialization state machine.
 * Returns the command intent the bridge should be asked to perform, or null.
 * The caller (spawn policy) decides how many intents are actually dispatched.
 */
function evaluateMaterialization(npc,{desiredLod='VIRTUAL',now=Date.now(),...options}={}){
  const opts={...DEFAULTS,...options};
  if(!npc||npc.alive===false){
    if(npc&&state(npc)!==STATES.VIRTUAL&&!npc.materialized)setState(npc,STATES.VIRTUAL,now);
    return null;
  }
  switch(state(npc)){
    case STATES.VIRTUAL:{
      if(desiredLod==='VIRTUAL')return null;
      if(npc.spawnBlockedReason)return null;
      npc.materializeRequestedAt=now;
      setState(npc,STATES.SPAWN_QUEUED,now);
      return spawnIntent(npc,desiredLod,now);
    }
    case STATES.SPAWN_QUEUED:{
      if(desiredLod==='VIRTUAL'){npc.materializeRequestedAt=null;setState(npc,STATES.VIRTUAL,now);return null;}
      if(npc.spawnBlockedReason){setState(npc,STATES.VIRTUAL,now);return null;}
      return spawnIntent(npc,desiredLod,now);
    }
    case STATES.SPAWNING:{
      const startedAt=Number(npc.materializeRequestedAt)||now;
      if(now-startedAt>opts.spawnCommandTimeoutMs){
        npc.spawnRetryAt=now+backoffMs(npc.spawnAttempts,opts);
        npc.lastSpawnFailure={reason:'SPAWN_TIMEOUT',at:now};
        setState(npc,STATES.SPAWN_BACKOFF,now);
      }
      return null;
    }
    case STATES.MATERIALIZED:{
      if(desiredLod!=='VIRTUAL')return null;
      npc.dematerializeEligibleAt=now+opts.dematerializeGraceMs;
      setState(npc,STATES.DESPAWN_GRACE,now);
      return null;
    }
    case STATES.DESPAWN_GRACE:{
      if(desiredLod!=='VIRTUAL'){npc.dematerializeEligibleAt=null;setState(npc,STATES.MATERIALIZED,now);return null;}
      if(now<Number(npc.dematerializeEligibleAt||0))return null;
      setState(npc,STATES.DESPAWN_QUEUED,now);
      return captureIntent(npc,now);
    }
    case STATES.DESPAWN_QUEUED:{
      if(desiredLod!=='VIRTUAL'){npc.dematerializeEligibleAt=null;setState(npc,STATES.MATERIALIZED,now);return null;}
      return captureIntent(npc,now);
    }
    case STATES.CAPTURING:{
      const startedAt=Number(npc.captureRequestedAt)||now;
      if(now-startedAt>opts.captureCommandTimeoutMs){
        // Never destroy blindly: the actor stays and the entity stays materialized.
        npc.lastCaptureFailure={reason:'CAPTURE_TIMEOUT',at:now};
        setState(npc,STATES.MATERIALIZED,now);
      }
      return null;
    }
    case STATES.SPAWN_BACKOFF:{
      if(now>=Number(npc.spawnRetryAt||0)){npc.spawnRetryAt=null;setState(npc,STATES.VIRTUAL,now);}
      return null;
    }
    default:
      setState(npc,STATES.VIRTUAL,now);
      return null;
  }
}

function markSpawnDispatched(npc,{now=Date.now(),seq=null}={}){
  npc.spawnAttempts=(npc.spawnAttempts||0)+1;
  npc.materializeRequestedAt=now;
  npc.pendingCommandSeq=seq;
  npc.runtimeGeneration=(npc.runtimeGeneration||0)+1;
  setState(npc,STATES.SPAWNING,now);
  return npc.runtimeGeneration;
}
function markCaptureDispatched(npc,{now=Date.now(),seq=null}={}){
  npc.captureRequestedAt=now;
  npc.pendingCommandSeq=seq;
  setState(npc,STATES.CAPTURING,now);
}
function applyMaterialized(npc,{runtimeId=null,position=null,bodyProfile=null,now=Date.now()}={}){
  npc.runtimeId=runtimeId;
  npc.materialized=true;
  npc.hasEverMaterialized=true;
  npc.spawnAttempts=0;
  npc.spawnRetryAt=null;
  npc.spawnBlockedReason=null;
  npc.pendingCommandSeq=null;
  npc.lastSpawnFailure=null;
  if(position)npc.position={...position};
  if(bodyProfile)npc.bodyProfile=bodyProfile;
  npc.dematerializeEligibleAt=null;
  setState(npc,STATES.MATERIALIZED,now);
  return npc;
}
function applyMaterializeFailed(npc,{reason='UNKNOWN',now=Date.now(),blocked=false,...options}={}){
  const opts={...DEFAULTS,...options};
  npc.materialized=false;
  npc.runtimeId=null;
  npc.pendingCommandSeq=null;
  npc.lastSpawnFailure={reason,at:now};
  if(blocked){
    npc.spawnBlockedReason=reason;
    setState(npc,STATES.VIRTUAL,now);
    return npc;
  }
  npc.spawnRetryAt=now+backoffMs(npc.spawnAttempts,opts);
  setState(npc,STATES.SPAWN_BACKOFF,now);
  return npc;
}
function applyDematerialized(npc,{position=null,health=null,now=Date.now()}={}){
  if(position)npc.position={...position};
  const captured=Number(health);
  // A capture snapshot may confirm damage but can never resurrect or heal an entity.
  if(Number.isFinite(captured))npc.health=Math.max(0,Math.min(Number(npc.health??1),captured));
  npc.materialized=false;
  npc.runtimeId=null;
  npc.combatIntent=null;
  npc.pendingCommandSeq=null;
  npc.captureRequestedAt=null;
  npc.dematerializeEligibleAt=null;
  npc.simulationLod='VIRTUAL';
  npc.lastCaptureFailure=null;
  setState(npc,STATES.VIRTUAL,now);
  return npc;
}
function applyCaptureFailed(npc,{reason='CAPTURE_FAILED',now=Date.now()}={}){
  npc.lastCaptureFailure={reason,at:now};
  npc.captureRequestedAt=null;
  npc.pendingCommandSeq=null;
  if(npc.materialized)setState(npc,STATES.MATERIALIZED,now);
  else setState(npc,STATES.VIRTUAL,now);
  return npc;
}
function applyActorLost(npc,{now=Date.now()}={}){
  npc.materialized=false;
  npc.runtimeId=null;
  npc.combatIntent=null;
  npc.pendingCommandSeq=null;
  npc.captureRequestedAt=null;
  npc.dematerializeEligibleAt=null;
  npc.simulationLod='VIRTUAL';
  setState(npc,STATES.VIRTUAL,now);
  return npc;
}
function clearMaterializationForDeath(npc,{now=Date.now()}={}){
  npc.materialized=false;
  npc.runtimeId=null;
  npc.combatIntent=null;
  npc.pendingCommandSeq=null;
  npc.captureRequestedAt=null;
  npc.dematerializeEligibleAt=null;
  npc.spawnRetryAt=null;
  npc.aiIntent=null;
  npc.simulationLod='VIRTUAL';
  npc.desiredSimulationLod='VIRTUAL';
  npc.runtimeGeneration=(npc.runtimeGeneration||0)+1;
  setState(npc,STATES.VIRTUAL,now);
  return npc;
}
module.exports={
  STATES,DEFAULTS,evaluateMaterialization,markSpawnDispatched,markCaptureDispatched,
  applyMaterialized,applyMaterializeFailed,applyDematerialized,applyCaptureFailed,
  applyActorLost,clearMaterializationForDeath,backoffMs
};
