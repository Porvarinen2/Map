'use strict';
const { traitDefinitions } = require('./registry');
const { createRng, normalish, clamp } = require('../core/prng');
function generateTraits({seed,npcId,archetypeDef={}}) {
  const rng = createRng(`${seed}|${npcId}|traits`); const out={}; const bias=archetypeDef.traits||{};
  for (const [name,d] of Object.entries(traitDefinitions)) {
    const noise=(normalish(rng)-.5)*2*d.spread;
    out[name]=Number(clamp(d.mean+noise+(bias[name]||0)).toFixed(4));
  }
  return out;
}
module.exports={generateTraits};
