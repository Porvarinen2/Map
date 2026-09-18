'use strict';
const {clamp}=require('../core/prng');
const {effectiveTrait}=require('../state/trauma');
function scoreActions(npc,ctx={}){
 const t=new Proxy(npc.traits||{},{get:(obj,key)=>typeof key==='string'?effectiveTrait(npc,key):obj[key]}), s=npc.stress||0, own=ctx.ownStrength??1, enemy=ctx.enemyStrength??1, ratio=enemy/Math.max(.1,own), zp=ctx.zombiePressure||0;
 const leaderBoost=ctx.leaderOrder?0.15*(t.obedience??.5)*(t.discipline??.5):0;
 const scores={};
 scores.ATTACK=clamp((t.aggression??.5)*.36+(t.courage??.5)*.24+(t.combatConfidence??.5)*.18+(1-s)*.18-(Math.max(0,ratio-1))*.18-(zp*.025));
 scores.COVER=clamp((t.cautiousness??.5)*.32+(t.discipline??.5)*.18+s*.24+(ctx.hasCover?.16:0));
 scores.RETREAT=clamp((t.fearfulness??.5)*.28+(t.survivalInstinct??.5)*.27+s*.30+Math.max(0,ratio-1)*.22+zp*.035-(t.courage??.5)*.16);
 scores.FLANK=clamp((npc.skills?.tacticalMovement??.4)*.32+(t.discipline??.5)*.18+(t.courage??.5)*.12+(t.aggression??.5)*.10+(1-s)*.16-(ratio>1.6?.15:0));
 scores.INVESTIGATE=clamp((t.curiosity??.5)*.38+(t.awareness??.5)*.18+(1-s)*.10-(t.cautiousness??.5)*.08);
 scores.HELP_FRIEND=clamp((t.empathy??.5)*.28+(t.loyalty??.5)*.30+(t.protectiveness??.5)*.20-s*.08);
 scores.FLEE=clamp(scores.RETREAT+.12*(t.fearfulness??.5)+Math.max(0,zp-4)*.03);
 if(ctx.leaderOrder&&scores[ctx.leaderOrder]!=null)scores[ctx.leaderOrder]=clamp(scores[ctx.leaderOrder]+leaderBoost);
 return scores;
}
function chooseAction(npc,scores,{switchMargin=.12}={}){
 let best=Object.entries(scores).sort((a,b)=>b[1]-a[1])[0]||['IDLE',0]; const current=npc.ai?.action; const currentScore=current!=null?(scores[current]??npc.ai?.actionScore??0):0;
 if(current&&best[0]!==current&&best[1]<currentScore+switchMargin)best=[current,currentScore]; npc.ai={...(npc.ai||{}),action:best[0],actionScore:best[1],scores:{...scores},changedAt:best[0]===current?(npc.ai?.changedAt||Date.now()):Date.now()}; return npc.ai;
}
module.exports={scoreActions,chooseAction};
