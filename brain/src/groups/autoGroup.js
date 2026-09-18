'use strict';
const {createGroup,groupClasses}=require('./classes');
const {selectLeader}=require('./leadership');
const {setRelationState}=require('./diplomacy');
const {dist}=require('../virtual/sim');
function allowed(classId,size){const d=groupClasses[classId];return !!d&&size>=d.minSize&&size<=d.maxSize;}
function majority(a,set){return a.filter(x=>set.includes(x)).length>=Math.ceil(a.length/2);}
function classForMembers(members){
  const size=members.length,a=members.map(n=>n.archetype);
  if(size<=1)return'solo';
  const candidates=[];
  if(majority(a,['elite']))candidates.push('elite_unit');
  if(a.some(x=>x==='radiation_specialist'))candidates.push('radiation_team');
  if(a.some(x=>x==='bunker_specialist'))candidates.push('bunker_team');
  if(majority(a,['elite','ex_military','veteran']))candidates.push('ex_military');
  if(majority(a,['police','security']))candidates.push('police_patrol');
  if(majority(a,['hunter']))candidates.push('hunters');
  if(majority(a,['bandit']))candidates.push('bandit_crew');
  if(majority(a,['scavenger']))candidates.push('scavengers');
  if(majority(a,['militia']))candidates.push('militia_cell');
  for(const id of candidates)if(allowed(id,size))return id;
  if(size===2)return'duo';
  return'survivor_group';
}
function groupLevel(members){return Math.max(1,Math.min(5,Math.round(members.reduce((s,n)=>s+n.skillTier,0)/Math.max(1,members.length))));}
function centroid(group){const alive=group.members.filter(n=>n.alive!==false);if(!alive.length)return{x:0,y:0,z:0};return alive.reduce((a,n)=>({x:a.x+n.position.x/alive.length,y:a.y+n.position.y/alive.length,z:a.z+(n.position.z||0)/alive.length}),{x:0,y:0,z:0});}
function relationDefault(a,b){const hostileA=a.classId==='bandit_crew',hostileB=b.classId==='bandit_crew';if((['police_patrol','ex_military','elite_unit'].includes(a.classId)&&hostileB)||(['police_patrol','ex_military','elite_unit'].includes(b.classId)&&hostileA))return-.8;if(hostileA!==hostileB)return-.65;return 0;}
function affiliationFamily(archetype){
  if(archetype==='bandit')return'bandit';
  if(['police','security'].includes(archetype))return'law';
  if(['elite','ex_military','veteran','radiation_specialist','bunker_specialist'].includes(archetype))return'military';
  if(archetype==='militia')return'militia';
  return'civilian';
}
function familiesCompatible(a,b){
  if(a===b)return true;
  if(a==='bandit'||b==='bandit')return false;
  if((a==='law'&&b==='military')||(a==='military'&&b==='law'))return true;
  if((a==='civilian'&&b==='militia')||(a==='militia'&&b==='civilian'))return true;
  if((a==='military'&&b==='militia')||(a==='militia'&&b==='military'))return true;
  return false;
}
function groupCompatible(group,npc){
  const alive=group.members.filter(n=>n.alive!==false);
  if(!alive.length)return true;
  const fam=affiliationFamily(npc.archetype);
  return alive.every(n=>familiesCompatible(affiliationFamily(n.archetype),fam));
}
function refreshGroup(group,world=null){const alive=group.members.filter(n=>n.alive!==false);const oldClass=group.classId;group.classId=classForMembers(alive);group.level=groupLevel(alive);const leaderValid=!!group.leaderId&&group.members.some(n=>n.npcId===group.leaderId&&n.alive!==false);if(!leaderValid&&group.status!=='LEADERLESS')selectLeader(group);if(world&&oldClass!==group.classId){for(const other of Object.values(world.groups)){if(other===group)continue;const prevA=group.relations?.[other.groupId]??0,prevB=other.relations?.[group.groupId]??0;const oldA=relationDefault({...group,classId:oldClass},other),newA=relationDefault(group,other);if(prevA===0||prevA===oldA)setRelationState(group,other.groupId,newA);if(prevB===0||prevB===oldA)setRelationState(other,group.groupId,newA);}}return group;}
function canAccept(group,npc){const alive=group.members.filter(n=>n.alive!==false);if(alive.length>=5||!groupCompatible(group,npc))return false;const prospective=[...alive,npc];const classId=classForMembers(prospective);const def=groupClasses[classId];return !def||prospective.length<=def.maxSize;}
function assignNpcToGroup(world,npc,{joinRadius=2000}={}){
  if(npc.groupId&&world.groups[npc.groupId])return world.groups[npc.groupId];
  let best=null,bestD=Infinity;
  for(const g of Object.values(world.groups)){if(!canAccept(g,npc))continue;const d=dist(centroid(g),npc.position);if(d<=joinRadius&&d<bestD){best=g;bestD=d;}}
  if(!best){world._groupSeq=(world._groupSeq||0)+1;const id=`group-${String(world._groupSeq).padStart(4,'0')}`;best=createGroup({groupId:id,classId:'solo',level:npc.skillTier,members:[npc]});world.groups[id]=best;for(const other of Object.values(world.groups)){if(other.groupId===id)continue;const r=relationDefault(best,other);setRelationState(best,other.groupId,r);setRelationState(other,id,r);}selectLeader(best);return best;}
  best.members.push(npc);npc.groupId=best.groupId;refreshGroup(best,world);return best;
}
module.exports={classForMembers,groupLevel,centroid,assignNpcToGroup,refreshGroup,relationDefault,canAccept,affiliationFamily,familiesCompatible,groupCompatible};
