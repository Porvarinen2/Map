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

Behavior modules consume named traits through stable interfaces. A brand-new trait is immediately generated and visible in the map UI; to make that trait alter a specific subsystem, add its modifier to that subsystem or an archetype/utility policy without changing unrelated modules.


default.json -> population
- maxNpc: managed NPC cap (default 100).
- hardMaxNpc: safety ceiling (default 250). maxNpc is clamped to this value.
- roamEnabled: enables autonomous off-screen group travel.
- roamIntervalSeconds: how often idle groups pick/refresh roaming goals.
- roamRadiusCm: maximum roaming target radius in Unreal centimeters.

user.json
- Persistent user overrides. Edit this after installation.
- Nested values are deep-merged over installed/default configuration at process startup.
- Recommended place for population.maxNpc, takeoverMode and other server-specific tuning.
- Preserved during package updates.
