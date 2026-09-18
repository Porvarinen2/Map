'use strict';
// Maps a persistent entity's body *intent* (family + level) onto a SCUM class the
// running build has actually reported. Nothing is ever fabricated: if the current
// build never published a matching class, the entity stays virtual with an explicit
// reason instead of being spawned as something it is not.
const BLOCKED_REASON='BODY_PROFILE_UNAVAILABLE';

function verifiedEntries(classCatalog){
  const out=[];
  for(const entry of Object.values(classCatalog||{})){
    if(!entry||entry.verified===false)continue;
    if(!entry.className||!entry.family)continue;
    out.push({className:entry.className,family:entry.family,level:Number(entry.level)||null});
  }
  return out;
}

function resolveBodyProfile(npc,classCatalog={}){
  const entries=verifiedEntries(classCatalog);
  if(npc&&npc.bodyProfile&&npc.hasEverMaterialized){
    const known=entries.find(e=>e.className===npc.bodyProfile);
    if(known)return {ok:true,className:npc.bodyProfile,match:'previous_materialization'};
  }
  const family=npc?.bodyFamily||null;
  if(!family)return {ok:false,reason:`${BLOCKED_REASON}: entity has no body family intent`};
  const familyEntries=entries.filter(e=>e.family===family);
  if(!familyEntries.length)return {ok:false,reason:`${BLOCKED_REASON}: no verified ${family} class in this build`};
  const level=Number(npc?.bodyLevel);
  if(Number.isFinite(level)){
    const exact=familyEntries.find(e=>e.level===level);
    if(exact)return {ok:true,className:exact.className,match:'exact_level'};
    const nearest=familyEntries
      .filter(e=>Number.isFinite(e.level))
      .sort((a,b)=>Math.abs(a.level-level)-Math.abs(b.level-level)||a.level-b.level)[0];
    if(nearest)return {ok:true,className:nearest.className,match:'nearest_level',requestedLevel:level,resolvedLevel:nearest.level};
  }
  const any=familyEntries.slice().sort((a,b)=>String(a.className).localeCompare(String(b.className)))[0];
  return {ok:true,className:any.className,match:'family_only'};
}
module.exports={resolveBodyProfile,BLOCKED_REASON};
