'use strict';
const { clamp }=require('../core/prng');
const {effectiveTrait}=require('./trauma');
const base={gunshot:.11,explosion:.22,near_miss:.18,wound:.20,friend_death:.28,leader_death:.38,zombie:.06,zombie_horde:.22,outnumbered:.14,darkness:.04,hunger:.03,thirst:.04};
function distanceFactor(d){ if(d==null)return 1; return Math.max(.15,Math.min(1,1-(d/200))); }
function applyStressEvent(npc,e){ const b=(base[e.type]??.05)*(e.intensity??1)*distanceFactor(e.distance); const fear=.45+.8*effectiveTrait(npc,'fearfulness'); const courage=1-.45*effectiveTrait(npc,'courage'); const resist=1-.75*effectiveTrait(npc,'stressResistance'); const trauma=npc.traumas?.some(t=>t.trigger===e.type)?.25:0; npc.stress=clamp((npc.stress||0)+b*fear*courage*resist+trauma); npc.lastStressEvent={...e,at:e.at??Date.now()}; return npc.stress; }
function recoverStress(npc,seconds){ const recovery=.0009*seconds*(.6+(.8*effectiveTrait(npc,'composure'))+(.7*effectiveTrait(npc,'stressResistance'))); npc.stress=clamp((npc.stress||0)-recovery); return npc.stress; }
function stressState(s){ if(s<.2)return'CALM'; if(s<.4)return'ALERT'; if(s<.6)return'STRESSED'; if(s<.8)return'HIGH_STRESS'; return'PANIC'; }
function accuracyMultiplier(npc){ const s=npc.stress||0; const discipline=effectiveTrait(npc,'discipline'); return clamp(1-s*(.55-.25*discipline),.35,1); }
module.exports={applyStressEvent,recoverStress,stressState,accuracyMultiplier};
