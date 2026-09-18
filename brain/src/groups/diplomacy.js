'use strict';
const {clamp}=require('../core/prng');
function setRelationState(group,otherId,value){group.relations[otherId]=clamp(value,-1,1);return group.relations[otherId];}
function adjustGroupRelation(group,otherId,delta){return setRelationState(group,otherId,(group.relations[otherId]||0)+delta);}
function relationState(group,otherId){const v=group.relations[otherId]||0;if(v<=-.85)return'BLOOD_FEUD';if(v<=-.35)return'HOSTILE';if(v<-.10)return'SUSPICIOUS';if(v<.55)return'NEUTRAL';return'FRIENDLY';}
module.exports={setRelationState,adjustGroupRelation,relationState};
