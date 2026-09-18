# 700 m materialization acceptance scenario

Live gate for `0.1.5-audit25fix`. Node tests being green is not sufficient: this
scenario is run against the real SCUM dedicated server before the physical rows of
the health panel may be expected to stay green during normal play.

Collect one diagnostics bundle (`RunDiagnostics.bat`) at the end of a passing run and
archive it next to the release.

## 0. Preconditions

- SCUM dedicated server installed and startable with the packaged scripts.
- `TeslesNPCOverhaul` installed, brain running, map viewer reachable.
- No players online at the start.

## 1. Persistent world exists without any player or SCUM actor

1. Delete nothing. Start the server with a fresh `runtime/world.json` (new world).
2. Open the map viewer before joining.

Expected:
- top bar reports `NPC 100` and a non-zero squad count,
- every marker is drawn in the VIRTUAL colour, physical count is `0`,
- `worldPopulation`, `persistence` and `brain` are **OK**,
- `scumAdapter`, `spawnCatalog`, `physicalVirtualization`, `takeover` and
  `physicalCombat` are **PENDING** - not DEGRADED, because nothing has been tried yet.

## 2. Bridge reports what this build can actually do

Join the server so UE4SS discovers NPC classes.

Expected:
- `spawnCatalog` turns OK and the class catalog in the diagnostics bundle lists the
  `BP_Drifter_Lvl_*` / `BP_Guard_Lvl_*` classes this build really loaded,
- families with no matching runtime class stay unavailable; entities of those families
  report `spawnBlockedReason=BODY_PROFILE_UNAVAILABLE` instead of spawning a guess.

## 3. Materialization at 700 m

1. Pick a virtual squad on the map and walk toward it.
2. Watch the squad markers while crossing the 700 m ring.

Expected:
- at <= 700 m squad members queue and materialize within the per-tick budget
  (2 spawns per tick by default - a burst is throttled, never dropped),
- persistent `npcId`s do **not** change; no new NPCs appear in the top bar,
- `takeover` turns OK after the first controller + brain stop is verified,
- the physical NPCs move under Tesles navigation without MoveTo spam.

## 4. Dematerialization after 5 s beyond 700 m

1. Walk more than 700 m away and keep moving.

Expected:
- the entity enters `DESPAWN_GRACE` and stays materialized for 5 seconds,
- turning back inside the ring before the grace expires cancels the despawn
  (no spawn/despawn flapping on the boundary),
- after the grace, capture runs **before** destruction: position (and health when
  readable) is captured, then the actor is destroyed and verified gone,
- markers keep moving virtually on the map afterwards.

## 5. Rematerialization keeps identity

1. Return within 700 m of the same squad.

Expected:
- the same `npcId`s rematerialize at their current virtual positions,
- traits, skills, stress, trauma, group membership and leader are unchanged,
- `physicalVirtualization` turns OK only now - a single spawn is not a roundtrip.

## 6. Death is permanent

1. Kill one squad member.
2. Leave the area, let the squad dematerialize, rejoin, then restart the server.

Expected:
- the killed member stays dead across dematerialization and restart,
- the surviving members keep the same identities and the succession result stands,
- the population is **not** refilled (`replenishDead=false`).

## 7. Diagnostics bundle

`RunDiagnostics.bat` must produce a bundle containing:

- `population-summary.json` with `populationMeta`, per-LOD counts, per-state counts,
  materialization queue, roundtrip proof flag, class catalog, capabilities and health,
- `materialization-events.json` with the last 100 materialization events,
- `pending-commands.log` with the current command snapshot,
- `compat-profile.json` with the reflected classes/functions this build accepted or rejected,
- `world.json` plus the usual SCUM/UE4SS log tails.

## Failure handling

If spawn or destroy cannot be driven safely through Lua on the current build, stop here
and report `spawn_actor` / `destroy_actor` as DEGRADED with the exact reason from
`compat-profile.json`. The persistent world, squads, AI, persistence and viewer keep
working virtually; only the physical layer is blocked, and it must never be reported
green on the strength of Node tests alone.
