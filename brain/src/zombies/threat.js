'use strict';
const {applyStressEvent}=require('../state/stress');
function distance(a,b){const dx=(a.x||0)-(b.x||0),dy=(a.y||0)-(b.y||0),dz=(a.z||0)-(b.z||0);return Math.sqrt(dx*dx+dy*dy+dz*dz);}
function computeZombiePressure(zombies,origin,{radius=1200}={}){let p=0;for(const z of zombies||[]){const d=distance(z,origin);if(d<=radius)p+=Math.max(0,1-d/radius);}return Number(p.toFixed(4));}
function applyZombiePressure(group,pressure,{at=Date.now(),applyStress=true}={}){if(pressure<=0)return;const type=pressure>=4?'zombie_horde':'zombie';for(const n of group.members.filter(n=>n.alive!==false)){n.experience.zombieEncounters=(n.experience.zombieEncounters||0)+1;if(applyStress)applyStressEvent(n,{type,intensity:Math.min(2,.45+pressure*.22),at});}group.zombiePressure=pressure;group.morale=Math.max(0,group.morale-Math.min(.18,pressure*.018));}
function chooseZombieResponse(group,pressure){const alive=group.members.filter(n=>n.alive!==false);if(!alive.length)return'AVOID';const avg=(k)=>alive.reduce((s,n)=>s+(n.traits[k]||0),0)/alive.length;const strength=group.combatPower||alive.length*.6;const fear=avg('fearfulness')+(1-avg('stressResistance'))*.5;if(pressure>strength*2.2||fear>.95)return'FLEE';if(pressure>strength*1.1)return'AVOID';if(avg('aggression')>.62&&group.morale>.45)return'FIGHT';return'AVOID';}
function fleeDestination(origin,zombies,{radius=14000,distanceOut=8000}={}){
  let vx=0,vy=0,weightSum=0;
  for(const z of zombies||[]){const p=z.position||z;const dx=(origin.x||0)-(p.x||0),dy=(origin.y||0)-(p.y||0);const d=Math.hypot(dx,dy);if(d<=0||d>radius)continue;const w=Math.max(.001,1-d/radius);vx+=(dx/d)*w;vy+=(dy/d)*w;weightSum+=w;}
  if(weightSum<=0)return null;
  const mag=Math.hypot(vx,vy)||1;return{x:origin.x+(vx/mag)*distanceOut,y:origin.y+(vy/mag)*distanceOut,z:origin.z||0};
}
module.exports={computeZombiePressure,applyZombiePressure,chooseZombieResponse,fleeDestination};
