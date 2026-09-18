'use strict';
const {clamp}=require('../core/prng');
function recomputeGroupStats(group){ const alive=group.members.filter(n=>n.alive!==false); if(!alive.length){group.combatPower=0;group.morale=0;group.cohesion=0;return group;} const avg=(key)=>alive.reduce((s,n)=>s+(n.skills[key]||0),0)/alive.length; const avgStress=alive.reduce((s,n)=>s+(n.stress||0),0)/alive.length; group.combatPower=Number((alive.length*(.35+avg('rifle')*.35+avg('tacticalMovement')*.3)*(1-avgStress*.35)*(.65+group.cohesion*.35)).toFixed(3)); group.morale=clamp(group.morale);group.cohesion=clamp(group.cohesion); return group; }
module.exports={recomputeGroupStats};
