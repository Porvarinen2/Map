'use strict';
const { createRng, clamp }=require('../core/prng');
const traumaProfiles={
 witness_death:['hypervigilance','loss_anxiety','paranoia_spike'], leader_death:['loss_anxiety','vengeful_response','hypervigilance'], zombie_horde:['zombie_trauma','combat_aversion'], near_death:['combat_aversion','hypervigilance'], betrayal:['paranoia_spike','trust_damage']
};
function maybeAcquireTrauma(npc,event){ const fear=npc.traits.fearfulness??.5, resist=npc.traits.stressResistance??.5, s=npc.stress||0; const chance=clamp((event.severity??.5)*.45+fear*.25+s*.35-resist*.35,0,.95); const rng=createRng(`${npc.npcId}|${event.seed??event.type}|${npc.traumas.length}`); if(rng()>chance)return null; const options=traumaProfiles[event.type]||['hypervigilance']; const type=options[Math.floor(rng()*options.length)%options.length]; const t={id:`trauma-${npc.npcId}-${npc.traumas.length+1}`,type,trigger:event.type,severity:Number(clamp((event.severity??.5)*(.7+rng()*.4)).toFixed(3)),acquiredAt:event.at??Date.now(),persistent:(event.severity??0)>=.8}; npc.traumas.push(t); return t; }
function decayTraumas(npc,days){ for(const t of npc.traumas){ if(!t.persistent)t.severity=clamp(t.severity-days*.02); } npc.traumas=npc.traumas.filter(t=>t.persistent||t.severity>.05); }
function traumaModifiers(npc){const out={paranoia:0,fearfulness:0,courage:0,stressResistance:0,aggression:0};for(const t of npc.traumas||[]){const s=t.severity||0;if(t.type==='paranoia_spike'||t.type==='hypervigilance')out.paranoia+=.18*s;if(t.type==='loss_anxiety'||t.type==='zombie_trauma')out.fearfulness+=.15*s;if(t.type==='combat_aversion')out.courage-=.16*s;if(t.type==='vengeful_response')out.aggression+=.18*s;if(t.type==='hypervigilance')out.stressResistance-=.06*s;}return out;}
function effectiveTrait(npc,key){const m=traumaModifiers(npc);return clamp((npc.traits?.[key]??.5)+(m[key]||0),0,1);}
module.exports={maybeAcquireTrauma,decayTraumas,traumaModifiers,effectiveTrait};
