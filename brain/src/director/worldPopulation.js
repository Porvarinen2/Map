'use strict';
const path=require('path');
const {createRng}=require('../core/prng');
const {createNpc}=require('../core/entityFactory');
const {createGroup,groupClasses:defaultGroupClasses}=require('../groups/classes');
const {archetypes:defaultArchetypes}=require('../archetypes/registry');
const {selectLeader}=require('../groups/leadership');
const {setRelationState}=require('../groups/diplomacy');
const {relationDefault}=require('../groups/autoGroup');
const {defaultPopulationMeta}=require('../persistence/worldStore');

const defaultBodyProfiles=require(process.env.TESLES_NPC_BODY_PROFILES||path.join(__dirname,'..','..','config','body-profiles.json'));

const MAX_GROUP_SIZE=5;

function clampInt(v,lo,hi){const n=Math.round(Number(v));return Math.max(lo,Math.min(hi,Number.isFinite(n)?n:lo));}

function validatePopulationConfig(cfg={},map={}){
  const errors=[];
  const target=Number(cfg.initialNpcCount);
  if(!Number.isFinite(target)||target<0||Math.round(target)!==target)errors.push(`population.initialNpcCount must be a non-negative integer, got ${JSON.stringify(cfg.initialNpcCount)}`);
  const margin=Number(cfg.edgeMarginCm);
  if(!Number.isFinite(margin)||margin<0)errors.push(`population.edgeMarginCm must be a non-negative number, got ${JSON.stringify(cfg.edgeMarginCm)}`);
  const spread=Number(cfg.groupMemberSpreadCm);
  if(!Number.isFinite(spread)||spread<0)errors.push(`population.groupMemberSpreadCm must be a non-negative number, got ${JSON.stringify(cfg.groupMemberSpreadCm)}`);
  const weights=cfg.groupClassWeights||{};
  if(typeof weights!=='object'||Array.isArray(weights))errors.push('population.groupClassWeights must be an object of classId -> weight');
  else{
    let total=0;
    for(const [classId,weight] of Object.entries(weights)){
      const w=Number(weight);
      if(!Number.isFinite(w)||w<0){errors.push(`population.groupClassWeights.${classId} must be a non-negative number, got ${JSON.stringify(weight)}`);continue;}
      total+=w;
    }
    if(total<=0&&Number(cfg.initialNpcCount)>0)errors.push('population.groupClassWeights must contain at least one positive weight');
  }
  const width=Number(map.maxX)-Number(map.minX),height=Number(map.maxY)-Number(map.minY);
  if(Number.isFinite(width)&&Number.isFinite(height)){
    if(width<=0||height<=0)errors.push(`map bounds must describe a positive area, got ${width} x ${height}`);
    else{
      if(Number.isFinite(margin)&&(margin*2>=width||margin*2>=height))errors.push(`population.edgeMarginCm ${margin} leaves no usable area inside map bounds ${width} x ${height}`);
      if(Number.isFinite(spread)&&(spread>width||spread>height))errors.push(`population.groupMemberSpreadCm ${spread} is larger than the map ${width} x ${height}`);
    }
  }
  if(errors.length)throw new Error(`Invalid population configuration:\n - ${errors.join('\n - ')}`);
  return true;
}

function weightedPick(rng,entries){
  const usable=entries.filter(e=>Number(e.weight)>0);
  if(!usable.length)return null;
  const total=usable.reduce((s,e)=>s+Number(e.weight),0);
  let roll=rng()*total;
  for(const e of usable){roll-=Number(e.weight);if(roll<=0)return e.value;}
  return usable[usable.length-1].value;
}

function classCandidates(weights,groupClasses,size){
  return Object.entries(weights)
    .filter(([classId])=>groupClasses[classId])
    .filter(([classId])=>size==null||(groupClasses[classId].minSize<=size&&groupClasses[classId].maxSize>=size))
    .map(([classId,weight])=>({value:classId,weight}));
}

function pickArchetype(rng,classDef,archetypes){
  const allowed=(classDef.archetypes||[]).filter(a=>archetypes[a]);
  if(!allowed.length)return 'survivor';
  return allowed[Math.min(allowed.length-1,Math.floor(rng()*allowed.length))];
}

function pickSkillTier(rng,archetype,archetypes){
  const range=archetypes[archetype]?.tier;
  const lo=clampInt(Array.isArray(range)?range[0]:2,1,5);
  const hi=clampInt(Array.isArray(range)?range[1]:lo,lo,5);
  return lo+Math.min(hi-lo,Math.floor(rng()*(hi-lo+1)));
}

function familyForArchetype(archetype,bodyProfiles){
  const map=bodyProfiles?.archetypeFamily||{};
  return map[archetype]||bodyProfiles?.fallbackFamily||'DRIFTER';
}

function anchorPosition(rng,map,margin){
  const minX=Number(map.minX)+margin,maxX=Number(map.maxX)-margin;
  const minY=Number(map.minY)+margin,maxY=Number(map.maxY)-margin;
  return {
    x:minX+rng()*(maxX-minX),
    y:minY+rng()*(maxY-minY),
    z:Number(map.defaultZ)||0
  };
}

function memberPosition(rng,anchor,spread,map,margin){
  const angle=rng()*Math.PI*2;
  const radius=rng()*spread;
  const minX=Number(map.minX)+margin,maxX=Number(map.maxX)-margin;
  const minY=Number(map.minY)+margin,maxY=Number(map.maxY)-margin;
  return {
    x:Math.max(minX,Math.min(maxX,anchor.x+Math.cos(angle)*radius)),
    y:Math.max(minY,Math.min(maxY,anchor.y+Math.sin(angle)*radius)),
    z:anchor.z
  };
}

function nextNpcId(world){world._npcSeq=(world._npcSeq||0)+1;return `npc-${String(world._npcSeq).padStart(5,'0')}`;}
function nextGroupId(world){world._groupSeq=(world._groupSeq||0)+1;return `group-${String(world._groupSeq).padStart(4,'0')}`;}

/**
 * Generate the persistent Tesles population for a world that has never been
 * populated. Existing entities are always preserved: a legacy world only gets
 * topped up to the target, an initialized world is never touched again - not even
 * when every generated NPC has since died.
 */
function bootstrapWorldPopulation(world,{
  seed='tesles-scum-world',
  targetCount=null,
  map={},
  populationConfig={},
  groupClasses=defaultGroupClasses,
  archetypes=defaultArchetypes,
  bodyProfiles=defaultBodyProfiles,
  now=null
}={}){
  if(!world||typeof world!=='object')throw new TypeError('world is required');
  world.npcs=world.npcs||{};world.groups=world.groups||{};
  world.meta=world.meta||{};
  world.meta.population={...defaultPopulationMeta(),...(world.meta.population||{})};
  const meta=world.meta.population;
  const cfg={...populationConfig};
  if(targetCount!=null)cfg.initialNpcCount=targetCount;
  validatePopulationConfig(cfg,map);

  const result={changed:false,mode:'noop',createdNpcIds:[],createdGroupIds:[],existingNpcCount:Object.keys(world.npcs).length};
  if(meta.initialized===true){result.mode='already_initialized';return result;}

  const generatorVersion=clampInt(cfg.bootstrapGeneratorVersion??1,0,1e6);
  const hardMax=Number(cfg.hardMaxNpc)||Number.POSITIVE_INFINITY;
  const target=Math.min(clampInt(cfg.initialNpcCount,0,1e6),hardMax);
  const existing=Object.keys(world.npcs).length;
  const stamp=Number.isFinite(Number(now))?Number(now):Date.now();
  let remaining=Math.max(0,target-existing);
  result.mode=existing===0?'fresh':'migrate';

  const margin=Number(cfg.edgeMarginCm)||0;
  const spread=Number(cfg.groupMemberSpreadCm)||0;
  const weights=cfg.groupClassWeights||{};
  const rng=createRng(`${seed}|population|v${generatorVersion}|target${target}|existing${existing}`);

  while(remaining>0){
    let classId=weightedPick(rng,classCandidates(weights,groupClasses,null));
    if(!classId)break;
    const def=groupClasses[classId];
    const minSize=clampInt(def.minSize||1,1,MAX_GROUP_SIZE);
    const maxSize=clampInt(def.maxSize||minSize,minSize,MAX_GROUP_SIZE);
    let size=minSize+Math.min(maxSize-minSize,Math.floor(rng()*(maxSize-minSize+1)));
    if(size>remaining){
      size=remaining;
      const fallback=weightedPick(rng,classCandidates(weights,groupClasses,size));
      classId=fallback||(size===1?'solo':size===2?'duo':'survivor_group');
      if(!groupClasses[classId])classId=Object.keys(groupClasses).find(id=>groupClasses[id].minSize<=size&&groupClasses[id].maxSize>=size);
      if(!classId)break;
    }
    const classDef=groupClasses[classId];
    const anchor=anchorPosition(rng,map,margin);
    const groupId=nextGroupId(world);
    const members=[];
    for(let i=0;i<size;i++){
      const npcId=nextNpcId(world);
      const archetype=pickArchetype(rng,classDef,archetypes);
      const skillTier=pickSkillTier(rng,archetype,archetypes);
      const position=memberPosition(rng,anchor,spread,map,margin);
      const npc=createNpc({
        npcId,seed,archetype,skillTier,
        bodyProfile:null,
        bodyFamily:familyForArchetype(archetype,bodyProfiles),
        bodyLevel:clampInt(skillTier,1,5),
        position,
        homePosition:anchor,
        origin:'TESLES_GENERATED',
        groupId,
        now:stamp
      });
      world.npcs[npcId]=npc;
      members.push(npc);
      result.createdNpcIds.push(npcId);
    }
    const level=clampInt(members.reduce((s,n)=>s+n.skillTier,0)/members.length,1,5);
    const group=createGroup({groupId,classId,level,members});
    group.homePosition={...anchor};
    world.groups[groupId]=group;
    for(const other of Object.values(world.groups)){
      if(other.groupId===groupId)continue;
      const relation=relationDefault(group,other);
      setRelationState(group,other.groupId,relation);
      setRelationState(other,groupId,relation);
    }
    selectLeader(group);
    result.createdGroupIds.push(groupId);
    remaining-=size;
  }

  meta.initialized=true;
  meta.generatorVersion=generatorVersion;
  meta.initialTarget=target;
  meta.initializedAt=stamp;
  meta.replenishDead=cfg.replenishDead===true;
  meta.mode=result.mode;
  result.changed=result.createdNpcIds.length>0||meta.initialized;
  return result;
}

module.exports={bootstrapWorldPopulation,validatePopulationConfig,familyForArchetype,defaultBodyProfiles,MAX_GROUP_SIZE};
