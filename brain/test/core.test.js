const test = require('node:test');
const assert = require('node:assert/strict');
const { createNpc } = require('../src/core/entityFactory');
const { createRng } = require('../src/core/prng');
const { archetypes } = require('../src/archetypes/registry');

test('seeded NPC generation is deterministic but unique across ids', () => {
  const a = createNpc({ npcId: 'npc-1', seed: 42, archetype: 'ex_military', skillTier: 4, bodyProfile: 'BP_Guard_Lvl_4' });
  const b = createNpc({ npcId: 'npc-1', seed: 42, archetype: 'ex_military', skillTier: 4, bodyProfile: 'BP_Guard_Lvl_4' });
  const c = createNpc({ npcId: 'npc-2', seed: 42, archetype: 'ex_military', skillTier: 4, bodyProfile: 'BP_Guard_Lvl_4' });
  assert.deepEqual(a.traits, b.traits);
  assert.notDeepEqual(a.traits, c.traits);
  assert.equal(a.npcId, 'npc-1');
  assert.equal(a.skillTier, 4);
});

test('archetype biases affect generated traits without cloning NPCs', () => {
  const ex = createNpc({ npcId: 'a', seed: 100, archetype: 'ex_military', skillTier: 4, bodyProfile: 'BP_Guard_Lvl_4' });
  const civ = createNpc({ npcId: 'b', seed: 100, archetype: 'civilian', skillTier: 1, bodyProfile: 'BP_Drifter_Lvl_1' });
  assert.ok(ex.traits.discipline > civ.traits.discipline);
  assert.ok(ex.skills.tacticalMovement > civ.skills.tacticalMovement);
  assert.ok(ex.traits.stressResistance > civ.traits.stressResistance);
});

test('PRNG sequence is stable', () => {
  const a = createRng('hello');
  const b = createRng('hello');
  assert.equal(a(), b());
  assert.equal(a(), b());
  assert.ok(archetypes.hunter);
});
