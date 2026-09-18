'use strict';
const path=require('path');
function loadJson(envName,defaultName){const p=process.env[envName]||path.join(__dirname,'..','..','config',defaultName);delete require.cache[require.resolve(p)];return require(p);}
const traitDefinitions=Object.freeze(loadJson('TESLES_NPC_TRAITS','traits.json'));
module.exports={traitDefinitions,loadTraitDefinitions:()=>loadJson('TESLES_NPC_TRAITS','traits.json')};
