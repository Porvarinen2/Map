TESLES NPC OVERHAUL — DATA-DRIVEN CONFIG

traits.json
- Add a new trait by adding one JSON property with mean (0..1) and spread (0..1).
- Trait generation automatically includes it for every newly generated NPC.
- Existing world saves retain their already generated trait values.

archetypes.json
- Controls trait and skill biases for archetypes such as civilian, hunter, police, ex_military and radiation_specialist.
- New archetypes can be added without touching navigation or SCUM adapter code.

group-classes.json
- Defines group size limits, preferred archetypes and tactical labels.
- Runtime hard safety limit remains 5 NPCs per group.

Environment overrides supported for development:
TESLES_NPC_TRAITS
TESLES_NPC_ARCHETYPES
TESLES_NPC_GROUP_CLASSES
TESLES_NPC_POPULATION
TESLES_NPC_BODY_PROFILES

Behavior modules consume named traits through stable interfaces. A brand-new trait is immediately generated and visible in the map UI; to make that trait alter a specific subsystem, add its modifier to that subsystem or an archetype/utility policy without changing unrelated modules.


default.json -> population
- maxNpc: managed NPC cap (default 100).
- hardMaxNpc: safety ceiling (default 250). maxNpc is clamped to this value.
- roamEnabled: enables autonomous off-screen group travel.
- roamIntervalSeconds: how often idle groups pick/refresh roaming goals.
- roamRadiusCm: maximum roaming target radius in Unreal centimeters.

population.json (audit25)
- Defaults for the persistent Tesles population. default.json and user.json override these.
- initialNpcCount: how many persistent NPCs a brand-new world generates once (default 100).
  An existing world is only topped up to this number once; an initialized world is never
  regenerated, not even when every NPC has died.
- replenishDead: false. Dead NPCs stay dead and are not replaced. Setting this true is
  reserved for a future refill policy and currently only records intent in world.meta.
- edgeMarginCm: how far from the map edge squads may be placed (default 50000 = 500 m).
- groupMemberSpreadCm: how far squad members start from their squad anchor (default 3000 = 30 m).
- bootstrapGeneratorVersion: bump to intentionally change generated worlds; the same seed
  plus the same version always produces the same identities, squads and positions.
- adoptUnmanagedNpc: false. An unmanaged vanilla SCUM NPC never becomes a Tesles entity.
  Set true only if you want Tesles to adopt NPCs it did not create.
- groupClassWeights: relative likelihood of each group class during bootstrap. Weights are
  balancing values, not SCUM facts, and must be non-negative.

body-profiles.json (audit25)
- Maps archetypes to body families (DRIFTER, GUARD, RADIATION, BUNKER) and lists the class
  name patterns each family may use.
- The exact SCUM class is never assumed: an entity keeps bodyProfile=null until the running
  build reports a matching class, and stays virtual with BODY_PROFILE_UNAVAILABLE otherwise.

default.json -> simulation (audit25)
- fullDistanceCm: 20000 (200 m). Nearest player inside this range = FULL.
- lightDistanceCm: 70000 (700 m). Between full and light = LIGHT. Beyond it = VIRTUAL.
- A physical SCUM actor exists in FULL and LIGHT; beyond 700 m the entity is virtualized.

default.json -> materialization (audit25)
- dematerializeGraceMs: 5000. How long an entity must stay beyond 700 m before its actor is
  captured and destroyed. Prevents spawn/despawn flapping on the boundary.
- spawnRetryMs / spawnBackoffMaxMs: retry backoff after a failed spawn (exponential, capped).
- maxMaterializePerTick / maxDematerializePerTick: physical transitions allowed per tick
  (2 / 5). A player teleporting into a dense area queues work instead of stalling the server.
- spawnCommandTimeoutMs / captureCommandTimeoutMs: how long the brain waits for a bridge
  result before retrying. A capture timeout always keeps the actor; state loss is never a
  fallback.

user.json
- Persistent user overrides. Edit this after installation.
- Nested values are deep-merged over installed/default configuration at process startup.
- Recommended place for population.maxNpc, takeoverMode and other server-specific tuning.
- Preserved during package updates.
