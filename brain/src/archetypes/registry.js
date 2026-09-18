'use strict';
const path=require('path');
function loadJson(){const p=process.env.TESLES_NPC_ARCHETYPES||path.join(__dirname,'..','..','config','archetypes.json');delete require.cache[require.resolve(p)];return require(p);}
const archetypes=Object.freeze(loadJson());
module.exports={archetypes,loadArchetypes:loadJson};
