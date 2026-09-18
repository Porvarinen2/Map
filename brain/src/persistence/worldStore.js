'use strict';
const fs=require('fs');
const path=require('path');
const {RUNTIME_NPC_FIELDS,runtimeNpcState}=require('../core/entityFactory');

const WORLD_SCHEMA_VERSION=6;

function defaultPopulationMeta(){
  return {initialized:false,generatorVersion:0,initialTarget:0,initializedAt:0,replenishDead:false,mode:null};
}

// Persistent NPC copy: identity, psychology, group membership and virtual position
// survive; everything describing this session's physical actor is dropped.
function stripRuntimeNpcState(npc){
  const copy={...npc};
  for(const field of RUNTIME_NPC_FIELDS)delete copy[field];
  return copy;
}

function normalizeLoadedNpc(npc){
  const clean={...stripRuntimeNpcState(npc),...runtimeNpcState()};
  if(!clean.origin)clean.origin=npc.source==='SCUM'?'SCUM_OBSERVED':'LEGACY';
  if(!clean.creationSeed)clean.creationSeed=`${clean.seed||''}|${clean.npcId}`;
  if(clean.bodyFamily===undefined)clean.bodyFamily=null;
  if(clean.bodyLevel===undefined)clean.bodyLevel=null;
  if(!clean.homePosition&&clean.position)clean.homePosition={...clean.position};
  if(typeof clean.hasEverMaterialized!=='boolean')clean.hasEverMaterialized=false;
  if(clean.alive===undefined)clean.alive=true;
  return clean;
}

function migrateWorld(world){
  if(!world||typeof world!=='object')return world;
  world.npcs=world.npcs||{};
  world.groups=world.groups||{};
  world.players=world.players||{};
  world.zombies=world.zombies||{};
  world.events=Array.isArray(world.events)?world.events:[];
  world.capabilities=world.capabilities||{};
  world.meta=world.meta||{};
  const meta=world.meta;
  meta.population={...defaultPopulationMeta(),...(meta.population||{})};
  for(const [id,npc] of Object.entries(world.npcs))world.npcs[id]=normalizeLoadedNpc(npc);
  // Keep the id sequences ahead of anything already stored so a later bootstrap or
  // adoption can never re-issue an existing identity.
  let maxNpcSeq=Number(world._npcSeq)||0;
  for(const id of Object.keys(world.npcs)){const m=/^npc-(\d+)$/.exec(id);if(m)maxNpcSeq=Math.max(maxNpcSeq,Number(m[1]));}
  world._npcSeq=maxNpcSeq;
  let maxGroupSeq=Number(world._groupSeq)||0;
  for(const id of Object.keys(world.groups)){const m=/^group-(\d+)$/.exec(id);if(m)maxGroupSeq=Math.max(maxGroupSeq,Number(m[1]));}
  world._groupSeq=maxGroupSeq;
  world.version=WORLD_SCHEMA_VERSION;
  return world;
}

function canonicalizeLoadedWorld(world){
  if(!world||typeof world!=='object')return world;
  migrateWorld(world);
  for(const g of Object.values(world.groups)){
    const ids=Array.isArray(g.memberIds)?g.memberIds:
      Array.isArray(g.members)?g.members.map(m=>typeof m==='string'?m:m&&m.npcId).filter(Boolean):[];
    g.memberIds=ids.slice();
    g.members=ids.map(id=>world.npcs[id]).filter(Boolean);
    for(const n of g.members)n.groupId=g.groupId;
  }
  return world;
}

function serializableWorld(world){
  const out={...world,version:WORLD_SCHEMA_VERSION,npcs:{},groups:{}};
  for(const [id,npc] of Object.entries(world.npcs||{}))out.npcs[id]=stripRuntimeNpcState(npc);
  for(const [id,g] of Object.entries(world.groups||{})){
    const memberIds=(g.members||[]).map(n=>typeof n==='string'?n:n&&n.npcId).filter(Boolean);
    const copy={...g,memberIds};
    delete copy.members;
    out.groups[id]=copy;
  }
  return out;
}

function readValidJson(file){
  if(!fs.existsSync(file))return null;
  try{return JSON.parse(fs.readFileSync(file,'utf8'));}catch{return null;}
}
function saveWorld(file,world){
  fs.mkdirSync(path.dirname(file),{recursive:true});
  const tmp=file+'.tmp',backup=file+'.bak';
  const current=readValidJson(file);
  if(current!==null)fs.copyFileSync(file,backup);
  fs.writeFileSync(tmp,JSON.stringify(serializableWorld(world),null,2));
  fs.renameSync(tmp,file);
}
function loadWorld(file){
  const primary=readValidJson(file);
  if(primary!==null)return canonicalizeLoadedWorld(primary);
  const backup=readValidJson(file+'.bak');
  if(backup!==null)return canonicalizeLoadedWorld(backup);
  if(!fs.existsSync(file))return null;
  throw new Error(`World save is corrupt and no valid backup exists: ${file}`);
}
module.exports={saveWorld,loadWorld,serializableWorld,canonicalizeLoadedWorld,migrateWorld,stripRuntimeNpcState,defaultPopulationMeta,WORLD_SCHEMA_VERSION};
