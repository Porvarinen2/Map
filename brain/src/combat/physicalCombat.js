'use strict';
// Translates high-level Tesles combat intent into weapon commands for the bridge.
// Node never names a SCUM function here: it emits AIM / FIRE_START / FIRE_STOP /
// RELOAD and the UE4SS weapon adapter owns the build-specific calls. Commands are
// only produced while the weapon primitive is proven on the running build.
const WEAPON_ACTIONS=Object.freeze(['AIM','FIRE_START','FIRE_STOP','RELOAD']);

function weaponCapabilityReady(capabilities={}){
  return capabilities?.weapon_use?.ok===true;
}

function releaseTrigger(npc,{now=Date.now()}={}){
  if(!npc.combatIntent||npc.combatIntent.firing!==true)return null;
  npc.combatIntent={...npc.combatIntent,firing:false};
  return {type:'FIRE_STOP',persistentNpcId:npc.npcId,npcId:npc.runtimeId||npc.npcId,issuedAt:now};
}

/**
 * Build the weapon commands this entity needs right now.
 * Returns {commands:[], blockedReason:null|string}. A blocked capability never
 * silently drops a live trigger: firing entities still get their FIRE_STOP.
 */
function buildWeaponCommands(npc,{
  action='IDLE',
  target=null,
  capabilities={},
  now=Date.now(),
  accuracyMultiplier=null
}={}){
  if(!npc||npc.alive===false||!npc.materialized){
    const stop=npc?releaseTrigger(npc,{now}):null;
    return {commands:stop&&npc?.materialized?[stop]:[],blockedReason:'NOT_MATERIALIZED'};
  }
  if(!weaponCapabilityReady(capabilities)){
    const stop=releaseTrigger(npc,{now});
    return {commands:stop?[stop]:[],blockedReason:'WEAPON_CAPABILITY_UNPROVEN'};
  }
  const commands=[];
  const runtimeId=npc.runtimeId||npc.npcId;
  const shooting=['ATTACK','SUPPRESS'].includes(action)&&target&&Number.isFinite(Number(target.x));
  if(shooting){
    commands.push({
      type:'AIM',persistentNpcId:npc.npcId,npcId:runtimeId,
      x:Number(target.x),y:Number(target.y),z:Number(target.z||0),
      accuracyMultiplier:Number.isFinite(Number(accuracyMultiplier))?Number(accuracyMultiplier):(Number(npc.desiredAccuracyMultiplier)||1),
      suppress:action==='SUPPRESS'?'true':'false',
      issuedAt:now
    });
    if(npc.combatIntent?.firing!==true){
      commands.push({type:'FIRE_START',persistentNpcId:npc.npcId,npcId:runtimeId,issuedAt:now});
      npc.combatIntent={firing:true,action,since:now};
    }else npc.combatIntent={...npc.combatIntent,action};
  }else{
    const stop=releaseTrigger(npc,{now});
    if(stop)commands.push(stop);
  }
  return {commands,blockedReason:null};
}
module.exports={buildWeaponCommands,releaseTrigger,weaponCapabilityReady,WEAPON_ACTIONS};
