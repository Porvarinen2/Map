'use strict';
function remember(npc,event){ npc.memories=npc.memories||[]; npc.memories.push({...event,at:event.at??Date.now()}); if(npc.memories.length>128) pruneMemories(npc,{now:Date.now(),max:96}); return event; }
function pruneMemories(npc,{now=Date.now(),max=64}={}){ npc.memories=(npc.memories||[]).map(m=>({m,score:(m.importance??.3)*2+Math.max(0,1-(now-(m.at||0))/86400000)})).sort((a,b)=>b.score-a.score).slice(0,max).map(x=>x.m); return npc.memories; }
function recentMemory(npc,type){ return [...(npc.memories||[])].reverse().find(m=>m.type===type)||null; }
module.exports={remember,pruneMemories,recentMemory};
