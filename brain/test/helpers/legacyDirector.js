'use strict';
// audit25 made Tesles the only source of persistent NPC identity: an unmanaged SCUM
// actor no longer creates a Tesles entity unless the server explicitly opts in.
// Pre-audit25 suites use NPC_SEEN as a convenient fixture for an already-owned NPC,
// so they construct their director through this helper, which opts in on purpose.
const {WorldDirector}=require('../../src/director/worldDirector');
function legacyDirector(options={}){
  return new WorldDirector({...options,population:{adoptUnmanagedNpc:true,...(options.population||{})}});
}
module.exports={legacyDirector};
