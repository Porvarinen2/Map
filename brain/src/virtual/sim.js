'use strict';
const DEFAULT_FULL_DISTANCE_CM=20000;
const DEFAULT_LIGHT_DISTANCE_CM=70000;
const DEFAULT_VIRTUAL_SPEED_CM_PER_SEC=130;
function dist(a,b){const dx=(b.x||0)-(a.x||0),dy=(b.y||0)-(a.y||0),dz=(b.z||0)-(a.z||0);return Math.sqrt(dx*dx+dy*dy+dz*dz);}
function simulationLod(nearestPlayerDistance,{full=DEFAULT_FULL_DISTANCE_CM,light=DEFAULT_LIGHT_DISTANCE_CM}={}){if(nearestPlayerDistance<=full)return'FULL';if(nearestPlayerDistance<=light)return'LIGHT';return'VIRTUAL';}
function advanceVirtualNpc(npc,dtSeconds,{speed=DEFAULT_VIRTUAL_SPEED_CM_PER_SEC}={}){if(!npc.destination||!npc.alive)return npc.position;const d=dist(npc.position,npc.destination);if(d<=.0001){npc.position={...npc.destination};npc.activity='arrived';return npc.position;}const safeDt=Math.max(0,Number(dtSeconds)||0),safeSpeed=Math.max(0,Number(speed)||0);const step=Math.min(d,safeSpeed*safeDt);const f=d>0?step/d:1;npc.position={x:npc.position.x+(npc.destination.x-npc.position.x)*f,y:npc.position.y+(npc.destination.y-npc.position.y)*f,z:(npc.position.z||0)+((npc.destination.z||0)-(npc.position.z||0))*f};if(step>=d-.0001){npc.position={...npc.destination};npc.activity='arrived';}else npc.activity='travelling';return npc.position;}
function materialize(npc){npc.simulationLod='FULL';npc.desiredSimulationLod='FULL';npc.materialized=true;return{type:'materialize',npcId:npc.npcId,bodyProfile:npc.bodyProfile,position:npc.position};}
function dematerialize(npc,position){if(position)npc.position={...position};npc.simulationLod='VIRTUAL';npc.desiredSimulationLod='VIRTUAL';npc.materialized=false;return{type:'dematerialize',npcId:npc.npcId};}
module.exports={simulationLod,advanceVirtualNpc,materialize,dematerialize,dist,DEFAULT_FULL_DISTANCE_CM,DEFAULT_LIGHT_DISTANCE_CM,DEFAULT_VIRTUAL_SPEED_CM_PER_SEC};
