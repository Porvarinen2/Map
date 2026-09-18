'use strict';
const {clamp}=require('../core/prng');
function adjustRelation(npc,otherId,delta){npc.relationships=npc.relationships||{};npc.relationships[otherId]=clamp((npc.relationships[otherId]||0)+delta,-1,1);return npc.relationships[otherId];}
function relation(npc,otherId){return npc.relationships?.[otherId]||0;}
function evolveGroupRelations(group,dtSeconds){
  const alive=(group.members||[]).filter(n=>n.alive!==false);
  const dt=Math.max(0,Number(dtSeconds)||0);
  if(dt<=0||alive.length<2)return;
  for(const a of alive)for(const b of alive){
    if(a===b)continue;
    const loyalty=a.traits?.loyalty??.5, social=a.traits?.sociability??.5, teamwork=a.traits?.teamwork??.5;
    const target=clamp(.08+loyalty*.18+social*.10+teamwork*.14+(group.cohesion||0)*.16,-1,1);
    const current=relation(a,b.npcId);
    const rate=Math.min(.02,dt/3600*.025);
    a.relationships[b.npcId]=clamp(current+(target-current)*rate,-1,1);
  }
}
module.exports={adjustRelation,relation,evolveGroupRelations};
