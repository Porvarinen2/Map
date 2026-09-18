'use strict';
const {createNpc}=require('../core/entityFactory');
const {HealthRegistry}=require('../core/health');
const {EventBus}=require('../core/eventBus');
const {recoverStress,applyStressEvent,accuracyMultiplier}=require('../state/stress');
const {remember}=require('../memory/memory');
const {maybeAcquireTrauma,decayTraumas}=require('../state/trauma');
const {processSuccession,tickLeadership,onLeaderDeath,onLeaderInjured}=require('../groups/leadership');
const {recomputeGroupStats}=require('../groups/cohesion');
const {relationState,adjustGroupRelation}=require('../groups/diplomacy');
const {assignNpcToGroup,centroid,refreshGroup}=require('../groups/autoGroup');
const {evolveGroupRelations}=require('../relationships/relations');
const {advanceVirtualNpc,dist,simulationLod,DEFAULT_FULL_DISTANCE_CM,DEFAULT_LIGHT_DISTANCE_CM,DEFAULT_VIRTUAL_SPEED_CM_PER_SEC}=require('../virtual/sim');
const {classifyObservedNpc}=require('./classification');
const {computeZombiePressure,applyZombiePressure,chooseZombieResponse,fleeDestination}=require('../zombies/threat');
const {resolveVirtualZombieCombat}=require('../zombies/combat');
const {resolveVirtualGroupCombat}=require('../combat/groupCombat');
const {scoreActions,chooseAction}=require('../ai/utility');
const {shouldRepath,updateNavigationState,buildMovementIntent}=require('../navigation/policy');
const {tacticalDestination}=require('../navigation/tactical');
const {planGroupTravel}=require('./worldTravel');
const mat=require('../virtual/materializationCoordinator');
const {selectMaterializationWork,placementCandidate}=require('./spawnPolicy');
const {resolveBodyProfile,BLOCKED_REASON}=require('./bodyProfileResolver');
const {buildWeaponCommands}=require('../combat/physicalCombat');
const {bootstrapWorldPopulation}=require('./worldPopulation');
const {defaultPopulationMeta,WORLD_SCHEMA_VERSION}=require('../persistence/worldStore');
const {runtimeNpcState}=require('../core/entityFactory');
function eventPosition(e){const x=Number(e?.x),y=Number(e?.y),z=Number(e?.z);return Number.isFinite(x)&&Number.isFinite(y)&&Number.isFinite(z)?{x,y,z}:null;}

class WorldDirector{
  constructor({seed='tesles-world',world=null,featureFlags={},simulation={},population={},materialization={},map={}}={}){
    this.seed=seed;
    this.world=world||{version:WORLD_SCHEMA_VERSION,time:0,npcs:{},groups:{},zombies:{},players:{},events:[],capabilities:{},meta:{seed,population:defaultPopulationMeta()},_groupSeq:0,_npcSeq:0,_nextZombieEval:0,_nextGroupCombatEval:0,_nextRoamEval:0};
    this.world.players=this.world.players||{};this.world.zombies=this.world.zombies||{};this.world.groups=this.world.groups||{};this.world.npcs=this.world.npcs||{};this.world.capabilities=this.world.capabilities||{};this.world.events=this.world.events||[];
    this.world.meta=this.world.meta||{seed};
    this.world.meta.population={...defaultPopulationMeta(),...(this.world.meta.population||{})};
    this.world.version=WORLD_SCHEMA_VERSION;
    this.map=map;
    this.runtimeToNpc=new Map();this.pendingObserved=new Map();
    // A loaded world is always purely virtual: last session's actors are gone.
    for(const n of Object.values(this.world.npcs))Object.assign(n,runtimeNpcState());
    this.health=new HealthRegistry();this.bus=new EventBus();
    this.featureFlags={traits:true,stress:true,groups:true,zombies:true,virtualSimulation:true,utilityAI:true,...featureFlags};
    this.simulation={fullDistanceCm:DEFAULT_FULL_DISTANCE_CM,lightDistanceCm:DEFAULT_LIGHT_DISTANCE_CM,virtualSpeedCmPerSec:DEFAULT_VIRTUAL_SPEED_CM_PER_SEC,playerStaleMs:15000,zombieStaleMs:45000,groupCombatIntervalSeconds:10,groupHistoryLimit:200,...simulation};
    this.population={maxNpc:100,hardMaxNpc:250,ignoreUnmanagedAboveCap:true,roamEnabled:true,roamIntervalSeconds:45,roamRadiusCm:35000,adoptUnmanagedNpc:false,...population};
    this.population.maxNpc=Math.max(1,Math.min(Number(this.population.maxNpc)||100,Number(this.population.hardMaxNpc)||250));
    this.materialization={...mat.DEFAULTS,maxMaterializePerTick:2,maxDematerializePerTick:5,...materialization};
    this.classCatalog={};
    this.pendingCommands=[];
    this.materializationLog=[];
    this.roundtrip={dematerializedIds:new Set(),proven:false};
    this.health.ok('brain','initialized');
    this.health.ok('persistence','world schema v'+WORLD_SCHEMA_VERSION);
    this.health.pending('worldPopulation','population bootstrap has not run yet');
    this.health.pending('scumAdapter','waiting for first capability report from the UE4SS bridge');
    this.health.pending('spawnCatalog','no SCUM NPC class catalog reported yet');
    this.health.pending('takeover','no Tesles-owned actor has existed yet');
    this.health.pending('physicalVirtualization','no materialize/dematerialize roundtrip has been attempted yet');
    this.health.pending('physicalCombat','no materialized armed Tesles NPC has existed yet');
    this._refreshPopulationHealth();
  }
  _refreshPopulationHealth(){
    const meta=this.world.meta?.population||{};
    const total=Object.keys(this.world.npcs).length;
    const alive=Object.values(this.world.npcs).filter(n=>n.alive!==false).length;
    if(meta.initialized===true)this.health.ok('worldPopulation',`${alive} living / ${total} persistent NPCs in ${Object.keys(this.world.groups).length} squads`);
    else this.health.pending('worldPopulation','population bootstrap has not run yet');
  }
  bootstrapPopulation({map=this.map,populationConfig=this.population,now=null}={}){
    const before=Object.keys(this.world.npcs).length;
    let result;
    try{
      result=bootstrapWorldPopulation(this.world,{seed:this.seed,map,populationConfig,now});
    }catch(err){
      this.health.failed('worldPopulation',err.message);
      throw err;
    }
    for(const n of Object.values(this.world.npcs))if(n.materializationState==null)Object.assign(n,runtimeNpcState());
    this.world.events.push({type:'population_bootstrap',mode:result.mode,created:result.createdNpcIds.length,groups:result.createdGroupIds.length,before,at:Date.now()});
    this._refreshPopulationHealth();
    return result;
  }
  _logMaterialization(entry){
    this.materializationLog.push({...entry,at:entry.at||Date.now()});
    if(this.materializationLog.length>200)this.materializationLog=this.materializationLog.slice(-150);
  }
  _nextNpcId(){this.world._npcSeq=(this.world._npcSeq||0)+1;return `npc-${String(this.world._npcSeq).padStart(5,'0')}`;}
  _resolveByRuntime(runtimeId){const id=this.runtimeToNpc.get(runtimeId);return id&&this.world.npcs[id]||null;}
  _matchStable(stableKey,body,pos){
    if(!stableKey)return null;
    return Object.values(this.world.npcs).find(n=>n.stableKey===stableKey&&n.alive!==false&&!n.materialized)||null;
  }
  _registerSeen(e){
    const runtimeId=e.npcId;const body=e.body||'BP_Drifter_Lvl_1';const pos=eventPosition(e);if(!runtimeId||!pos){this.world.events.push({type:'invalid_runtime_position',runtimeId:runtimeId||null,sourceType:e.type||'NPC_SEEN',at:Date.now()});return null;}
    // A Tesles-owned actor always identifies the persistent entity it materializes.
    // It is never allowed to create a second identity for an NPC that already exists.
    const persistentId=e.persistentNpcId||null;
    if(persistentId){
      const owned=this.world.npcs[persistentId];
      if(!owned){this.world.events.push({type:'unknown_persistent_actor',persistentNpcId:persistentId,runtimeId,at:e.at||Date.now()});return null;}
      if(owned.alive===false){this.world.events.push({type:'stale_actor_for_dead_npc',persistentNpcId:persistentId,runtimeId,at:e.at||Date.now()});this._requestForceDestroy(owned,runtimeId,'entity already dead');return null;}
      if(owned.runtimeId&&owned.runtimeId!==runtimeId)this.runtimeToNpc.delete(owned.runtimeId);
      owned.runtimeId=runtimeId;owned.materialized=true;owned.position=pos;owned.lastSeenAt=e.at||Date.now();
      if(e.body)owned.bodyProfile=e.body;
      if(owned.materializationState!==mat.STATES.MATERIALIZED)mat.applyMaterialized(owned,{runtimeId,position:pos,bodyProfile:e.body||owned.bodyProfile,now:e.at||Date.now()});
      this.runtimeToNpc.set(runtimeId,persistentId);
      return owned;
    }
    let n=this._resolveByRuntime(runtimeId)||this._matchStable(e.stableKey,body,pos);
    if(!n){
      if(this.population.adoptUnmanagedNpc!==true){
        this.pendingObserved.set(runtimeId,{npcId:runtimeId,stableKey:e.stableKey||null,body,position:pos,lastSeenAt:e.at||Date.now()});
        this.world.events.push({type:'unmanaged_npc_ignored',runtimeId,body,at:e.at||Date.now()});
        return null;
      }
      const aliveManaged=Object.values(this.world.npcs).filter(x=>x.alive!==false).length;
      if(aliveManaged>=this.population.maxNpc){this.pendingObserved.set(runtimeId,{npcId:runtimeId,stableKey:e.stableKey||null,body,position:pos,lastSeenAt:e.at||Date.now()});this.world.events.push({type:'population_cap_ignored',runtimeId,body,at:e.at||Date.now()});return null;}
      const id=e.stableKey?this._nextNpcId():runtimeId;const cls=classifyObservedNpc(body,id,this.seed);n=createNpc({npcId:id,seed:this.seed,archetype:cls.archetype,skillTier:cls.skillTier,bodyProfile:body,position:pos});n.source='SCUM';n.stableKey=e.stableKey||null;n.identityStable=Boolean(e.stableKey);this.world.npcs[id]=n;if(this.featureFlags.groups)assignNpcToGroup(this.world,n);
    }
    if(n.runtimeId&&n.runtimeId!==runtimeId)this.runtimeToNpc.delete(n.runtimeId);
    this.pendingObserved.delete(runtimeId);n.runtimeId=runtimeId;n.stableKey=n.stableKey||e.stableKey||null;n.position=pos;n.materialized=true;n.simulationLod='FULL';n.desiredSimulationLod='FULL';n.lastSeenAt=e.at||Date.now();this.runtimeToNpc.set(runtimeId,n.npcId);return n;
  }
  ingest(e){
    if(!e||!e.type)return;
    switch(e.type){
      case'NPC_SEEN':this._registerSeen(e);break;
      case'NPC_POSITION':{const pos=eventPosition(e);if(!pos)break;let n=this._resolveByRuntime(e.npcId);if(!n){const pending=this.pendingObserved.get(e.npcId);if(pending){pending.position=pos;pending.lastSeenAt=e.at||Date.now();const aliveManaged=Object.values(this.world.npcs).filter(x=>x.alive!==false).length;if(aliveManaged<this.population.maxNpc)n=this._registerSeen({type:'NPC_SEEN',npcId:e.npcId,stableKey:pending.stableKey,body:pending.body,x:pending.position.x,y:pending.position.y,z:pending.position.z,at:pending.lastSeenAt});}}if(n){n.position=pos;n.materialized=true;n.lastSeenAt=e.at||Date.now();}break;}
      case'NPC_GONE':{const n=this._resolveByRuntime(e.npcId);if(n){this.runtimeToNpc.delete(e.npcId);mat.applyActorLost(n,{now:e.at||Date.now()});this._logMaterialization({type:'unexpected_actor_loss',persistentNpcId:n.npcId,runtimeId:e.npcId,at:e.at});this.world.events.push({type:'unexpected_actor_loss',persistentNpcId:n.npcId,runtimeId:e.npcId,at:e.at||Date.now()});}break;}
      case'MATERIALIZED':this._handleMaterialized(e);break;
      case'MATERIALIZE_FAILED':this._handleMaterializeFailed(e);break;
      case'DEMATERIALIZED':this._handleDematerialized(e);break;
      case'CAPTURE_FAILED':this._handleCaptureFailed(e);break;
      case'NPC_CLASS_CATALOG':this._handleClassCatalog(e);break;
      case'NPC_DAMAGE':this._handleNpcDamage({...e,npcId:e.persistentNpcId||this._resolveByRuntime(e.npcId)?.npcId||e.npcId});break;
      case'NPC_DEATH':this._handleNpcDeath({...e,npcId:e.persistentNpcId||this._resolveByRuntime(e.npcId)?.npcId||e.npcId});break;
      case'ZOMBIE_SEEN':{const pos=eventPosition(e);if(pos){const id=e.zombieId||`z-${e.at}`;this.world.zombies[id]={id,position:pos,lastSeenAt:e.at||Date.now()};}break;}
      case'GUNSHOT':{const origin=eventPosition(e);if(!origin)break;if(this.featureFlags.stress)for(const n of Object.values(this.world.npcs)){if(!n.alive)continue;const d=dist(n.position,origin);if(d<=20000)applyStressEvent(n,{type:'gunshot',intensity:Number(e.intensity)||1,distance:d/100,at:e.at});}this.world.events.push({...e});break;}
      case'PLAYER_SEEN':{const pos=eventPosition(e);if(pos){const id=e.playerId||`p-${e.at}`;this.world.players[id]={id,position:pos,lastSeenAt:e.at||Date.now()};}break;}
      case'BRIDGE_STARTED':{this.world.capabilities={};this.runtimeToNpc.clear();this.classCatalog={};this.roundtrip={dematerializedIds:new Set(),proven:false};for(const n of Object.values(this.world.npcs)){Object.assign(n,runtimeNpcState());n.navigation=n.navigation||{};n.navigation.movementCommanded=false;n.navigation.lastTarget=null;}this.health.pending('scumAdapter','bridge restarted; waiting for fresh capability probe');this.health.pending('takeover','bridge restarted; fresh takeover proof required');this.health.pending('physicalVirtualization','bridge restarted; roundtrip proof must be repeated on this session');this.health.pending('spawnCatalog','bridge restarted; waiting for a fresh NPC class catalog');this.world.events.push(e);break;}
      case'CAPABILITY':this.world.capabilities[e.name]={ok:e.ok===true||e.ok==='true',detail:e.detail||'',at:e.at};this._refreshAdapterHealth();break;
      case'COMMAND_RESULT':{this.world.events.push(e);const commandType=e.commandType||e.payloadType;const n=this._resolveByRuntime(e.npcId)||this.world.npcs[e.npcId];if(n){n.navigation=n.navigation||{};const ok=e.ok===true||e.ok==='true';const at=Number(e.at)||Date.now();if(commandType==='MOVE'){if(!ok){n.navigation.pathFailed=true;n.navigation.recoveryRequested='REPATH';n.navigation.lastCommandFailure={commandType:'MOVE',detail:e.detail||'',at,seq:e.seq??null};}else n.navigation.lastCommandAcceptedAt=at;}else if(commandType==='STOP'){if(!ok){n.navigation.movementCommanded=true;n.navigation.stopRetryAfter=at+1000;n.navigation.lastCommandFailure={commandType:'STOP',detail:e.detail||'',at,seq:e.seq??null};}else{n.navigation.movementCommanded=false;n.navigation.stopRetryAfter=null;n.navigation.lastStopAcceptedAt=at;}}}break;}
    }
    this.bus.emit(e.type,e);
  }
  _handleNpcDamage(e){const n=this.world.npcs[e.npcId];if(!n||!n.alive)return;const old=Number(n.health??1);if(!Number.isFinite(old))return;const fraction=Number(e.damageFraction);const normalized=Number(e.healthNormalized);let next=null;if(Number.isFinite(fraction)&&fraction>0)next=Math.max(0,old*(1-Math.min(1,fraction)));else if(Number.isFinite(normalized))next=Math.max(0,Math.min(1,normalized));if(next==null||!Number.isFinite(next)||next>=old)return;n.health=next;const sev=Math.max(.05,old-next);n.injuries=Array.isArray(n.injuries)?n.injuries:[];n.injuries.push({type:'combat_wound',severity:sev,at:e.at||Date.now()});if(this.featureFlags.stress)applyStressEvent(n,{type:'wound',intensity:.5+sev,at:e.at});const g=n.groupId&&this.world.groups[n.groupId];if(g&&g.leaderId===n.npcId)onLeaderInjured(g,n,{severity:Math.min(1,sev*2),at:e.at||Date.now(),stressEnabled:this.featureFlags.stress});this.world.events.push({...e,type:'npc_damage',persistentNpcId:n.npcId});}
  _handleNpcDeath(e){
    const n=this.world.npcs[e.npcId];if(!n||!n.alive)return;n.alive=false;n.health=0;if(n.runtimeId)this.runtimeToNpc.delete(n.runtimeId);
    // Death always wins over any pending materialization work for this entity.
    mat.clearMaterializationForDeath(n,{now:e.at||Date.now()});
    const g=n.groupId&&this.world.groups[n.groupId];if(g){if(g.leaderId===n.npcId)onLeaderDeath(g,n.npcId,{at:e.at||Date.now(),severity:1,stressEnabled:this.featureFlags.stress});else{for(const s of g.members.filter(x=>x.alive!==false)){if(this.featureFlags.stress)applyStressEvent(s,{type:'friend_death',intensity:1,at:e.at});remember(s,{type:'friend_death',target:n.npcId,importance:.85,at:e.at});if(this.featureFlags.stress&&s.stress>.8)maybeAcquireTrauma(s,{type:'witness_death',severity:.8,source:n.npcId,at:e.at,seed:`${g.groupId}:${n.npcId}`});}g.morale=Math.max(0,g.morale-.15);g.cohesion=Math.max(0,g.cohesion-.1);}}
    this.world.events.push(e);
  }
  _capabilityState(name){const c=this.world.capabilities?.[name];if(!c)return'PENDING';return c.ok?'OK':'DEGRADED';}
  _refreshAdapterHealth(){
    const caps=this.world.capabilities;
    const required=['bridge_scheduler','npc_discovery','location_read','controller_read','brain_stop','movement'];
    const failed=required.filter(k=>caps[k]&&!caps[k].ok);
    const untested=required.filter(k=>!caps[k]);
    if(failed.length)this.health.degraded('scumAdapter',`failed: ${failed.join(', ')}`);
    else if(untested.length)this.health.pending('scumAdapter',`not yet exercised: ${untested.join(', ')}`);
    else this.health.ok('scumAdapter','minimum takeover path green');
    const takeover=this._capabilityState('full_takeover_ready');
    if(takeover==='OK')this.health.ok('takeover','capability probe passed; takeover active on Tesles-owned actors');
    else if(takeover==='DEGRADED')this.health.degraded('takeover',caps.full_takeover_ready?.detail||'takeover proof failed');
    else this.health.pending('takeover','no Tesles-owned actor has been taken over yet');
    const weapon=this._capabilityState('weapon_use');
    if(weapon==='OK')this.health.ok('physicalCombat','weapon primitive proven on this build');
    else if(weapon==='DEGRADED')this.health.degraded('physicalCombat',caps.weapon_use?.detail||'weapon primitive attempted and failed; stress accuracy stays telemetry-only');
    else this.health.pending('physicalCombat','no materialized armed Tesles NPC has existed yet');
    const spawnCaps=['npc_class_catalog','spawn_actor','destroy_actor','tesles_identity_tag'];
    const spawnFailed=spawnCaps.filter(k=>caps[k]&&!caps[k].ok);
    const spawnUntested=spawnCaps.filter(k=>!caps[k]);
    if(spawnFailed.length)this.health.degraded('spawnCatalog',`failed: ${spawnFailed.map(k=>`${k} (${caps[k]?.detail||'no detail'})`).join('; ')}`);
    else if(spawnUntested.length)this.health.pending('spawnCatalog',`not yet exercised: ${spawnUntested.join(', ')}`);
    else this.health.ok('spawnCatalog',`${Object.keys(this.classCatalog).length} verified SCUM NPC classes`);
    this._refreshVirtualizationHealth();
  }
  _refreshVirtualizationHealth(){
    const caps=this.world.capabilities;
    if(this.world.capabilities.virtualization_roundtrip?.ok===true){this.health.ok('physicalVirtualization','materialize -> capture -> destroy -> rematerialize roundtrip proven with identity preserved');return;}
    const failed=['spawn_actor','destroy_actor'].filter(k=>caps[k]&&!caps[k].ok);
    if(failed.length){this.health.degraded('physicalVirtualization',`physical primitive failed: ${failed.join(', ')}; persistent world continues virtually`);return;}
    const attempts=this.materializationLog.filter(x=>x.type==='materialize_failed'||x.type==='capture_failed');
    if(attempts.length){this.health.degraded('physicalVirtualization',`last failure: ${attempts[attempts.length-1].reason||'unknown'}`);return;}
    this.health.pending('physicalVirtualization','no player has come within the materialization radius of a persistent NPC yet');
  }
  _requestForceDestroy(npc,runtimeId,reason){
    if(!runtimeId)return;
    this.pendingCommands.push({type:'FORCE_DESTROY',persistentNpcId:npc?.npcId||null,runtimeId,reason,issuedAt:Date.now()});
    this._logMaterialization({type:'force_destroy',persistentNpcId:npc?.npcId||null,runtimeId,reason});
  }
  _handleClassCatalog(e){
    const className=e.class||e.className;
    if(!className)return;
    this.classCatalog[className]={className,family:e.family||null,level:Number(e.level)||null,verified:e.verified!==false,at:e.at||Date.now()};
    // A class that appears in the catalog may unblock entities that were waiting for it.
    for(const n of Object.values(this.world.npcs))if(n.spawnBlockedReason&&String(n.spawnBlockedReason).startsWith(BLOCKED_REASON))n.spawnBlockedReason=null;
    this._refreshAdapterHealth();
  }
  _handleMaterialized(e){
    const id=e.persistentNpcId;
    const npc=id&&this.world.npcs[id];
    const at=e.at||Date.now();
    if(!npc){this._requestForceDestroy(null,e.runtimeId,'no such persistent entity');this.world.events.push({type:'stale_materialization',persistentNpcId:id||null,runtimeId:e.runtimeId||null,reason:'unknown entity',at});return;}
    if(npc.alive===false){this._requestForceDestroy(npc,e.runtimeId,'entity died before spawn completed');this.world.events.push({type:'stale_materialization',persistentNpcId:npc.npcId,runtimeId:e.runtimeId||null,reason:'entity dead',at});return;}
    const generation=Number(e.generation);
    if(Number.isFinite(generation)&&generation!==Number(npc.runtimeGeneration||0)){
      this._requestForceDestroy(npc,e.runtimeId,'stale spawn generation');
      this.world.events.push({type:'stale_materialization',persistentNpcId:npc.npcId,runtimeId:e.runtimeId||null,reason:'stale generation',at});
      return;
    }
    const position=eventPosition(e)||npc.position;
    if(npc.runtimeId&&npc.runtimeId!==e.runtimeId)this.runtimeToNpc.delete(npc.runtimeId);
    mat.applyMaterialized(npc,{runtimeId:e.runtimeId||null,position,bodyProfile:e.body||npc.bodyProfile,now:at});
    if(e.stableKey)npc.stableKey=e.stableKey;
    npc.lastSeenAt=at;
    if(e.runtimeId)this.runtimeToNpc.set(e.runtimeId,npc.npcId);
    this._logMaterialization({type:'materialized',persistentNpcId:npc.npcId,runtimeId:e.runtimeId||null,body:npc.bodyProfile,at});
    this.world.events.push({type:'npc_materialized',persistentNpcId:npc.npcId,runtimeId:e.runtimeId||null,at});
    if(this.roundtrip.dematerializedIds.has(npc.npcId)&&!this.roundtrip.proven){
      this.roundtrip.proven=true;
      this.world.capabilities.virtualization_roundtrip={ok:true,detail:`roundtrip proven on ${npc.npcId}`,at};
    }
    this._refreshAdapterHealth();
  }
  _handleMaterializeFailed(e){
    const npc=e.persistentNpcId&&this.world.npcs[e.persistentNpcId];
    const at=e.at||Date.now();
    const reason=e.reason||'MATERIALIZE_FAILED';
    if(!npc)return;
    const blocked=String(reason).includes(BLOCKED_REASON)||e.blocked===true;
    mat.applyMaterializeFailed(npc,{reason,now:at,blocked,...this.materialization});
    this._logMaterialization({type:'materialize_failed',persistentNpcId:npc.npcId,reason,attempt:npc.spawnAttempts,at});
    this.world.events.push({type:'npc_materialize_failed',persistentNpcId:npc.npcId,reason,position:{...npc.position},body:npc.bodyProfile||npc.bodyFamily,at});
    this._refreshVirtualizationHealth();
  }
  _handleDematerialized(e){
    const npc=e.persistentNpcId&&this.world.npcs[e.persistentNpcId];
    const at=e.at||Date.now();
    if(!npc)return;
    if(npc.runtimeId)this.runtimeToNpc.delete(npc.runtimeId);
    const position=eventPosition(e);
    const health=e.health!=null?Number(e.health):null;
    const wasAlive=npc.alive!==false;
    mat.applyDematerialized(npc,{position,health:Number.isFinite(health)?health:null,now:at});
    if(!wasAlive)npc.alive=false;
    this.roundtrip.dematerializedIds.add(npc.npcId);
    this._logMaterialization({type:'dematerialized',persistentNpcId:npc.npcId,position:position||npc.position,at});
    this.world.events.push({type:'npc_dematerialized',persistentNpcId:npc.npcId,at});
    this._refreshVirtualizationHealth();
  }
  _handleCaptureFailed(e){
    const npc=e.persistentNpcId&&this.world.npcs[e.persistentNpcId];
    const at=e.at||Date.now();
    if(!npc)return;
    // The actor is intentionally left alive: losing physical state is never an
    // acceptable fallback, so the entity stays materialized and capture retries.
    mat.applyCaptureFailed(npc,{reason:e.reason||'CAPTURE_FAILED',now:at});
    this._logMaterialization({type:'capture_failed',persistentNpcId:npc.npcId,reason:e.reason||'CAPTURE_FAILED',at});
    this.world.events.push({type:'npc_capture_failed',persistentNpcId:npc.npcId,reason:e.reason||'CAPTURE_FAILED',at});
    this._refreshVirtualizationHealth();
  }
  _materializationEval(now=Date.now()){
    const intents=[];
    const materializingGroupIds=[];
    for(const n of Object.values(this.world.npcs)){
      if(n.alive===false)continue;
      if([mat.STATES.SPAWNING,mat.STATES.MATERIALIZED].includes(n.materializationState)&&n.groupId)materializingGroupIds.push(n.groupId);
      const intent=mat.evaluateMaterialization(n,{desiredLod:n.desiredSimulationLod||'VIRTUAL',now,...this.materialization});
      if(intent){intent.nearestPlayerDistance=Number.isFinite(n.nearestPlayerDistanceCm)?n.nearestPlayerDistanceCm:Number.POSITIVE_INFINITY;intents.push(intent);}
    }
    const work=selectMaterializationWork(intents,{
      maxMaterializePerTick:this.materialization.maxMaterializePerTick,
      maxDematerializePerTick:this.materialization.maxDematerializePerTick,
      materializingGroupIds
    });
    this.materializationQueue={queuedMaterialize:work.queuedMaterialize,queuedDematerialize:work.queuedDematerialize,at:now};
    for(const intent of work.materialize){
      const npc=this.world.npcs[intent.persistentNpcId];
      if(!npc)continue;
      const resolved=resolveBodyProfile(npc,this.classCatalog);
      if(!resolved.ok){
        npc.spawnBlockedReason=resolved.reason;
        npc.materializationState=mat.STATES.VIRTUAL;
        this._logMaterialization({type:'spawn_blocked',persistentNpcId:npc.npcId,reason:resolved.reason,at:now});
        continue;
      }
      // A failed attempt never moves the persistent entity; only the spawn probe
      // position walks the candidate ring, and only within a tight radius once the
      // entity has physically existed before.
      const maxOffsets=npc.hasEverMaterialized?9:undefined;
      const candidate=placementCandidate(npc.position,maxOffsets?Math.min(npc.spawnAttempts||0,maxOffsets-1):(npc.spawnAttempts||0));
      const generation=mat.markSpawnDispatched(npc,{now});
      this.pendingCommands.push({
        type:'SPAWN',persistentNpcId:npc.npcId,npcClass:resolved.className,
        bodyFamily:npc.bodyFamily||'',bodyLevel:npc.bodyLevel||'',
        x:candidate.x,y:candidate.y,z:candidate.z,
        generation,attempt:npc.spawnAttempts,issuedAt:now
      });
      this._logMaterialization({type:'spawn_requested',persistentNpcId:npc.npcId,npcClass:resolved.className,attempt:npc.spawnAttempts,at:now});
    }
    for(const intent of work.dematerialize){
      const npc=this.world.npcs[intent.persistentNpcId];
      if(!npc||!npc.runtimeId)continue;
      mat.markCaptureDispatched(npc,{now});
      this.pendingCommands.push({type:'CAPTURE_AND_DESPAWN',persistentNpcId:npc.npcId,runtimeId:npc.runtimeId,issuedAt:now});
      this._logMaterialization({type:'capture_requested',persistentNpcId:npc.npcId,runtimeId:npc.runtimeId,at:now});
    }
  }
  drainCommands(){const out=this.pendingCommands;this.pendingCommands=[];return out;}
  _pruneTransient(now=Date.now()){for(const [id,p] of Object.entries(this.world.players))if(now-(p.lastSeenAt||0)>this.simulation.playerStaleMs)delete this.world.players[id];for(const [id,z] of Object.entries(this.world.zombies))if(now-(z.lastSeenAt||0)>this.simulation.zombieStaleMs)delete this.world.zombies[id];for(const [id,p] of this.pendingObserved)if(now-(p.lastSeenAt||0)>Math.max(this.simulation.playerStaleMs,this.simulation.zombieStaleMs))this.pendingObserved.delete(id);}
  _zombieEval(){const now=Date.now();const zombies=Object.values(this.world.zombies);for(const g of Object.values(this.world.groups)){const alive=g.members.filter(n=>n.alive!==false);if(!alive.length)continue;const c=centroid(g);const nearby=zombies.filter(z=>dist(z.position,c)<=14000);const pressure=computeZombiePressure(nearby.map(z=>z.position),c,{radius:14000});g.zombiePressure=pressure;if(pressure>0){applyZombiePressure(g,pressure,{at:now,applyStress:this.featureFlags.stress});g.zombieResponse=chooseZombieResponse(g,pressure);if(g.zombieResponse==='FLEE'){const dst=fleeDestination(c,nearby,{radius:14000,distanceOut:8000});if(dst){g.destination=dst;g.currentTask='flee_zombies';for(const n of alive)n.destination={...dst};}}else if(g.zombieResponse==='FIGHT'){g.currentTask='fight_zombies';g.destination=null;if(alive.every(n=>!n.materialized)){const r=resolveVirtualZombieCombat(g,pressure,{seed:this.seed,at:now,stressEnabled:this.featureFlags.stress});this.world.events.push({type:'virtual_zombie_combat',groupId:g.groupId,...r,at:now});for(const deadId of r.killed){const dead=this.world.npcs[deadId];if(dead){dead.pendingDeath=false;this._handleNpcDeath({npcId:dead.npcId,at:now,cause:'zombie'});}}}}else{g.currentTask='avoid_zombies';g.destination=null;}}else{g.zombieResponse='NONE';g.zombiePressure=0;if(['flee_zombies','fight_zombies','avoid_zombies'].includes(g.currentTask)){g.currentTask='idle';g.destination=null;for(const n of alive)n.destination=null;}}}}
  _applyVirtualRetreat(group,enemy){const c=centroid(group),e=centroid(enemy);let dx=c.x-e.x,dy=c.y-e.y,mag=Math.hypot(dx,dy)||1;const dst={x:c.x+dx/mag*12000,y:c.y+dy/mag*12000,z:c.z};group.destination=dst;group.currentTask='retreat_group';for(const n of group.members.filter(n=>n.alive!==false))n.destination={...dst};}
  _groupCombatEval(){const groups=Object.values(this.world.groups).filter(g=>g.members.some(n=>n.alive!==false));const active=new Map();const mark=(a,b)=>active.set(a.groupId,b.groupId);for(let i=0;i<groups.length;i++)for(let j=i+1;j<groups.length;j++){const a=groups[i],b=groups[j];if(dist(centroid(a),centroid(b))>12000)continue;const hostile=['HOSTILE','BLOOD_FEUD'];if(!hostile.includes(relationState(a,b.groupId))&&!hostile.includes(relationState(b,a.groupId)))continue;const virtualA=a.members.filter(n=>n.alive!==false).every(n=>!n.materialized),virtualB=b.members.filter(n=>n.alive!==false).every(n=>!n.materialized);if(virtualA&&virtualB){const duration=Math.max(1,this.simulation.groupCombatIntervalSeconds);const r=resolveVirtualGroupCombat(a,b,{seed:`${this.seed}:${Math.floor(this.world.time/duration)}:${a.groupId}:${b.groupId}`,durationSeconds:duration,at:Date.now(),stressEnabled:this.featureFlags.stress});for(const ev of r.events)if(ev.type==='group_retreat')this._applyVirtualRetreat(ev.groupId===a.groupId?a:b,ev.groupId===a.groupId?b:a);this.world.events.push({type:'virtual_group_combat',groupA:a.groupId,groupB:b.groupId,winner:r.winner,casualties:r.casualties,at:Date.now()});}else{mark(a,b);mark(b,a);a.combatTargetGroupId=b.groupId;b.combatTargetGroupId=a.groupId;a.currentTask='combat_group';b.currentTask='combat_group';}}for(const g of groups)if(g.combatTargetGroupId&&!active.has(g.groupId)){g.combatTargetGroupId=null;if(g.currentTask==='combat_group')g.currentTask='idle';}}
  _completeArrivedGroupTasks(){for(const g of Object.values(this.world.groups)){if(g.currentTask!=='retreat_group'||!g.destination)continue;const alive=g.members.filter(n=>n.alive!==false);if(alive.length&&alive.every(n=>dist(n.position,g.destination)<500)){g.currentTask='idle';g.destination=null;g.combatTargetGroupId=null;for(const n of alive){n.destination=null;n.activity='idle';}}}}
  _roamEval(){if(!this.population.roamEnabled)return;const bucket=Math.floor(this.world.time/Math.max(1,this.population.roamIntervalSeconds));for(const g of Object.values(this.world.groups)){const alive=g.members.filter(n=>n.alive!==false);if(!alive.length||g.combatTargetGroupId||g.zombiePressure>0||!['idle','travelling','roam'].includes(g.currentTask))continue;if(!g.destination||alive.every(n=>dist(n.position,g.destination)<500)){const dst=planGroupTravel(g,{seed:this.seed,timeBucket:bucket,radiusCm:this.population.roamRadiusCm});g.destination=dst;g.currentTask='roam';for(const n of alive){n.destination={...dst};n.activity='travelling';}}}}
  _updateLod(){const now=Date.now();const players=Object.values(this.world.players);for(const n of Object.values(this.world.npcs)){if(!n.alive)continue;let nearest=Infinity;for(const p of players)nearest=Math.min(nearest,dist(n.position,p.position));n.nearestPlayerDistanceCm=nearest;const desired=simulationLod(nearest,{full:this.simulation.fullDistanceCm,light:this.simulation.lightDistanceCm});n.desiredSimulationLod=desired;
    // The actual LOD follows the physical actor, not the wish: a still-materialized
    // NPC whose player left keeps a LIGHT actor until capture+destroy succeeds.
    if(n.materialized)n.simulationLod=desired==='VIRTUAL'?'LIGHT':desired;else n.simulationLod='VIRTUAL';n.lastLodEvalAt=now;}}
  _updateNavigation(now){for(const n of Object.values(this.world.npcs)){if(!n.alive||!n.materialized||!n.navigation?.movementCommanded)continue;n.navigation=updateNavigationState(n.navigation,n.position,{now});if(n.navigation.stuck){n.navigation.pathFailed=true;n.navigation.recoveryRequested=n.navigation.recovery;}}}
  _aiEval(){for(const n of Object.values(this.world.npcs)){if(!n.alive)continue;const g=n.groupId&&this.world.groups[n.groupId];let target=null,enemyStrength=1,ownStrength=g?.combatPower||1,leaderOrder=null;if(g?.combatTargetGroupId&&this.world.groups[g.combatTargetGroupId]){const enemy=this.world.groups[g.combatTargetGroupId];target=centroid(enemy);enemyStrength=enemy.combatPower||1;leaderOrder=g.morale<.25?'RETREAT':'ATTACK';}const scores=scoreActions(n,{enemyStrength,ownStrength,hasCover:false,leaderOrder,zombiePressure:g?.zombiePressure||0});const ai=chooseAction(n,scores,{switchMargin:.12});n.activity=ai.action.toLowerCase();n.desiredAccuracyMultiplier=accuracyMultiplier(n);if(!n.materialized||n.simulationLod==='VIRTUAL')continue;
    const weapon=buildWeaponCommands(n,{action:ai.action,target,capabilities:this.world.capabilities,now:Date.now(),accuracyMultiplier:n.desiredAccuracyMultiplier});
    if(weapon.commands.length)this.pendingCommands.push(...weapon.commands);
    n.physicalCombatBlockedReason=weapon.blockedReason;let moveTarget=null;if(target&&['ATTACK','FLANK'].includes(ai.action))moveTarget=tacticalDestination(n,target,ai.action,{groupId:g?.groupId||''});else if(target&&['RETREAT','FLEE'].includes(ai.action)){const dx=n.position.x-target.x,dy=n.position.y-target.y,mag=Math.hypot(dx,dy)||1;moveTarget={x:n.position.x+dx/mag*5000,y:n.position.y+dy/mag*5000,z:n.position.z};}else if(n.destination)moveTarget=n.destination;n.navigation=n.navigation||{};if(moveTarget){if(shouldRepath(n.navigation,moveTarget,{now:Date.now(),threshold:300,maxAgeMs:1800})){n.navigation.lastTarget={...moveTarget};n.navigation.lastRepathAt=Date.now();n.navigation.movementCommanded=true;n.aiIntent=buildMovementIntent({...n,npcId:n.runtimeId||n.npcId},moveTarget,{preferredRange:ai.action==='ATTACK'?2500:300,urgency:ai.action==='FLEE'?.95:.6,tacticalMode:n.navigation.recoveryRequested||ai.action});n.aiIntent.accuracyMultiplier=n.desiredAccuracyMultiplier;n.navigation.pathFailed=false;n.navigation.recoveryRequested=null;}}else if(n.navigation.movementCommanded&&(!n.navigation.stopRetryAfter||Date.now()>=n.navigation.stopRetryAfter)){n.navigation.movementCommanded=false;n.navigation.lastTarget=null;n.aiIntent={type:'STOP',npcId:n.runtimeId||n.npcId,issuedAt:Date.now()};}}}
  _pruneGroupHistory(){const max=Math.max(20,Number(this.simulation.groupHistoryLimit)||200);for(const g of Object.values(this.world.groups)){if(g.history?.length>max)g.history=g.history.slice(-max);}}
  tick(dtSeconds){const now=Date.now();this.world.time+=dtSeconds;this._pruneTransient(now);this._updateLod();this._updateNavigation(now);for(const n of Object.values(this.world.npcs)){if(!n.alive)continue;if(this.featureFlags.stress)recoverStress(n,dtSeconds);decayTraumas(n,dtSeconds/86400);if(this.featureFlags.virtualSimulation&&!n.materialized&&n.simulationLod==='VIRTUAL'&&n.destination)advanceVirtualNpc(n,dtSeconds,{speed:n.virtualSpeedCmPerSec||this.simulation.virtualSpeedCmPerSec});n.lastUpdate=now;}for(const g of Object.values(this.world.groups)){tickLeadership(g,dtSeconds);processSuccession(g,{now});evolveGroupRelations(g,dtSeconds);refreshGroup(g,this.world);recomputeGroupStats(g);}if(this.featureFlags.zombies&&this.world.time>=(this.world._nextZombieEval||0)){this._zombieEval();this.world._nextZombieEval=this.world.time+5;}if(this.world.time>=(this.world._nextGroupCombatEval||0)){this._groupCombatEval();this.world._nextGroupCombatEval=this.world.time+this.simulation.groupCombatIntervalSeconds;}this._completeArrivedGroupTasks();if(this.population.roamEnabled&&this.world.time>=(this.world._nextRoamEval||0)){this._roamEval();this.world._nextRoamEval=this.world.time+this.population.roamIntervalSeconds;}if(this.featureFlags.utilityAI)this._aiEval();this._materializationEval(now);this._pruneGroupHistory();if(this.world.events.length>1000)this.world.events=this.world.events.slice(-700);}
  healthSnapshot(){return this.health.snapshot();}
  compactSnapshot(){
    const npcs=Object.values(this.world.npcs);
    const groups=Object.values(this.world.groups);
    const materialized=npcs.filter(n=>n.alive&&n.materialized).length;
    return{
      version:this.world.version,time:this.world.time,
      npcs:npcs.filter(n=>n.alive).map(n=>({
        npcId:n.npcId,runtimeId:n.runtimeId,position:n.position,destination:n.destination,
        simulationLod:n.simulationLod,desiredSimulationLod:n.desiredSimulationLod,
        materializationState:n.materializationState,materialized:Boolean(n.materialized),
        spawnBlockedReason:n.spawnBlockedReason||null,
        groupId:n.groupId,role:n.role,stress:n.stress,activity:n.activity,alive:n.alive
      })),
      groups:groups.map(g=>{
        const members=(g.members||[]).filter(Boolean);
        const alive=members.filter(n=>n.alive!==false);
        return{
          groupId:g.groupId,classId:g.classId,level:g.level,leaderId:g.leaderId,
          morale:g.morale,cohesion:g.cohesion,currentTask:g.currentTask,destination:g.destination,
          combatPower:g.combatPower,
          memberCount:members.length,aliveMemberCount:alive.length,
          materializedMemberCount:alive.filter(n=>n.materialized).length
        };
      }),
      zombies:Object.values(this.world.zombies),players:Object.values(this.world.players),
      health:this.healthSnapshot(),
      population:{
        managed:npcs.filter(n=>n.alive).length,
        persistent:npcs.length,
        dead:npcs.filter(n=>n.alive===false).length,
        materialized,
        maxNpc:this.population.maxNpc,
        meta:this.world.meta?.population||null,
        queue:this.materializationQueue||{queuedMaterialize:0,queuedDematerialize:0}
      }
    };
  }
  npcDetails(id){const n=this.world.npcs[id];if(!n)return null;const g=n.groupId&&this.world.groups[n.groupId];return{npc:n,group:g||null};}
  snapshot(){const npcs=Object.values(this.world.npcs);const byLod={FULL:0,LIGHT:0,VIRTUAL:0};const byState={};for(const n of npcs){if(n.alive===false)continue;byLod[n.simulationLod]=(byLod[n.simulationLod]||0)+1;byState[n.materializationState||'VIRTUAL']=(byState[n.materializationState||'VIRTUAL']||0)+1;}
    return{version:this.world.version,time:this.world.time,npcs,groups:Object.values(this.world.groups),zombies:Object.values(this.world.zombies),players:Object.values(this.world.players),capabilities:this.world.capabilities,health:this.healthSnapshot(),featureFlags:this.featureFlags,simulation:this.simulation,population:this.population,materialization:{config:this.materialization,queue:this.materializationQueue||{queuedMaterialize:0,queuedDematerialize:0},countsByLod:byLod,countsByState:byState,log:this.materializationLog.slice(-100),classCatalog:this.classCatalog,roundtripProven:this.roundtrip.proven===true},populationMeta:this.world.meta?.population||null,events:this.world.events.slice(-100)};}
}
module.exports={WorldDirector};
