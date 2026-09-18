'use strict';
const path=require('path');
const groupClasses=Object.freeze(require(process.env.TESLES_NPC_GROUP_CLASSES||path.join(__dirname,'..','..','config','group-classes.json')));
function createGroup({groupId,classId='survivor_group',level=1,members=[]}){
 if(!groupId)throw new Error('groupId required'); if(level<1||level>5)throw new Error('group level must be 1-5'); const def=groupClasses[classId]; if(!def)throw new Error(`unknown group class ${classId}`); if(members.length>5)throw new Error('group may contain at most 5 NPCs');
 const g={groupId,classId,level,members,leaderId:null,status:'ACTIVE',morale:1,cohesion:1,relations:{},effects:{leaderDeathShock:0,leaderInjuryShock:0},orders:[],currentTask:'idle',destination:null,combatPower:0,successionAt:null,successionDelayMs:5000+level*750,history:[],resources:{ammo:120}};
 for(const n of members){n.groupId=groupId;} return g;
}
module.exports={groupClasses,createGroup};
