'use strict';
const fs=require('fs');
const path=require('path');

function canonicalizeLoadedWorld(world){
  if(!world||typeof world!=='object')return world;
  world.npcs=world.npcs||{}; world.groups=world.groups||{};
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
  const out={...world,npcs:{...world.npcs},groups:{}};
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
module.exports={saveWorld,loadWorld,serializableWorld,canonicalizeLoadedWorld};
