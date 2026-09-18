'use strict';
const { skillNames }=require('./registry');
const { createRng, normalish, clamp }=require('../core/prng');
function generateSkills({seed,npcId,skillTier,archetypeDef={}}){
 const rng=createRng(`${seed}|${npcId}|skills`); const base=(Math.max(1,Math.min(5,skillTier))-1)/4; const bias=archetypeDef.skills||{}; const out={};
 for(const name of skillNames){ const jitter=(normalish(rng)-.5)*.22; out[name]=Number(clamp(.08+base*.72+jitter+(bias[name]||0)).toFixed(4)); }
 return out;
}
module.exports={generateSkills};
