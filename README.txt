TESLES NPC OVERHAUL 0.1.5-audit25fix
================================

TARGET
  SCUM Dedicated Server
  Default server root:
  F:\SteamLibrary\steamapps\common\SCUM Server

WHAT THIS PACKAGE CONTAINS
--------------------------
This is the first real implementation package of the modular Tesles NPC architecture.
It includes the complete game-independent brain/world layer and the SCUM-facing UE4SS
capability bridge required to prove the exact reflected classes/functions exposed by
YOUR current SCUMServer.exe build before full vanilla-AI replacement is enabled.

Implemented brain/world systems:
- persistent individual NPC entities
- deterministic individual traits (aggression, courage, fearfulness, discipline,
  paranoia, loyalty, leadership, stress resistance, recklessness, etc.)
- skill tiers 1–5 independent of SCUM BP_Guard/BP_Drifter level
- archetypes: civilian, scavenger, survivor, hunter, bandit, police, security,
  militia, ex-military, veteran, radiation specialist, bunker specialist, elite
- groups of 1–5 NPCs and group levels 1–5
- group classes including Solo, Duo, Hunters, Police Patrol, Ex-Military,
  Radiation Team, Bunker Team, Bandits and more
- leader selection based on individual capability instead of a group-wide clone stat
- leader death shock, delayed succession and residual morale effects
- individual stress, memory, trauma and relationships
- zombie pressure influencing stress, morale, route/response decisions and off-screen simulation
- group-vs-group hostility and virtual battles
- utility AI and action inertia
- tactical/flanking destination generation
- virtual movement and FULL/LIGHT/VIRTUAL simulation model
- persistent world save

Map viewer (default):
  http://127.0.0.1:17381
  If brain.config.server.host/port is overridden in brain\config\user.json, the installer, bridge compatibility check and diagnostics use the effective configured endpoint.

The map shows every known Tesles NPC as its own marker. Clicking an NPC shows:
- body Blueprint
- archetype
- skill tier
- simulation LOD
- group and leader role
- stress and morale
- trauma
- all traits
- all skills
- position and current activity
- group level, leader, cohesion, combat power and leader-death shock

Right-click anywhere on the map and choose "Copy teleport command" to copy:
  #Teleport X Y Z
SCUM's admin command supports coordinates in that order. On an NPC marker the NPC's
actual Z coordinate is used. On empty map space the configurable default Z is used.
The exact command itself is current SCUM admin syntax; map coordinate bounds/default Z
remain configurable in brain\config\default.json.

IMPORTANT QUALITY GATE
----------------------
SCUM is closed-source and its internal NPC combat/spawn functions are not a stable public API.
The package therefore DOES NOT fabricate function names and pretend the overhaul is working.

The default configuration uses takeover_mode="auto" as a SAFE PROBE mode:
1. discover real current NPC actors
2. identify their controller and BrainComponent
3. temporarily StopLogic on ONE NPC
4. issue a reversible +200 cm MoveToLocation probe and verify observed progress before declaring movement capability
5. restore that NPC's vanilla brain automatically and verify IsRunning
6. remain in safe probe mode until a build-specific weapon command primitive is implemented and verified; full mode is an explicit opt-in for development/live validation
7. inspect reflected NPC/controller/weapon members for current build-specific functions
8. report capability results into runtime\probe-report.log

This protects the server from having every NPC permanently lobotomized if a SCUM update changed
one internal class/function. AUTO mode intentionally stays in safe probe/brain mode while weapon command control is unverified. Set features.takeoverMode="full" only in brain\\config\\user.json for development after live validation; Node and UE4SS now consume the same mode. Once the
live probe identifies the exact weapon/spawn/death surfaces, the SCUM adapter can be finalized
without altering traits, groups, stress, navigation, viewer or any other module.

INSTALL
-------
1. Extract the ZIP anywhere.
2. Double-click install.bat.
3. Installer will:
   - validate the SCUM Server path
   - stop SCUMServer.exe if running
   - stop an older Tesles NPC brain process
   - use Node.js 18+ from PATH when suitable, otherwise download a pinned portable Node.js 18.20.8 runtime from nodejs.org and verify it against the official SHASUMS256.txt
   - preserve/backup an older TeslesNPCOverhaul installation
   - validate existing UE4SS or install the pinned compatible UE4SS build if missing
   - install only the Tesles UE4SS mod folder into the detected UE4SS Mods location
   - generate runtime paths/configuration
   - start Tesles NPC Brain + Map Viewer
   - restart SCUMServer.exe with:
       -log -MaxPlayers=64 -nobattleye
   - open the browser viewer

UNINSTALL
---------
Double-click uninstall.bat.
It removes the Tesles UE4SS mod folder and stops the Tesles brain, then restarts SCUM.
By default persistent TeslesMods data is retained.
For a full package-data purge run from PowerShell:
  .\installer\Uninstall.ps1 -PurgeData
Shared UE4SS and Node.js installations are deliberately NOT removed.

FIRST LIVE TEST / NEXT ITERATION
--------------------------------
After SCUM has been running with at least one Guard/Drifter NPC visible/spawned for ~30 seconds,
double-click:
  RunDiagnostics.bat

It creates a ZIP in the package runtime folder containing:
- probe-report.log
- scum-events.log tail
- brain.log tail
- API health/capability snapshot
- UE4SS log tail when found

Upload that diagnostic ZIP back into ChatGPT. That is the fastest reliable way to finish the
build-specific physical weapon/fire/spawn adapter without guessing SCUM internals.

CONFIGURATION / MODULARITY
--------------------------
brain\config\traits.json
  Add new traits here. Newly generated NPCs automatically receive them.

brain\config\archetypes.json
  Trait/skill distributions for Hunter, Police, Ex-Military, etc.

brain\config\group-classes.json
  Group classes, size ranges and tactical labels.

brain\config\user.json -> population
  maxNpc defaults to 100. Change this file to set the managed NPC population cap; it survives package updates.
  default.json contains package defaults and is not the recommended post-install edit target.
  hardMaxNpc defaults to 250 as a safety ceiling.
  roamEnabled/roamIntervalSeconds/roamRadiusCm control off-screen autonomous travel.

Changing a trait does not require touching navigation. Fixing navigation does not require changing
stress. SCUM-specific hook changes are isolated to ue4ss\TeslesNPCOverhaul\scripts\modules.

FILES THAT MATTER WHEN DEBUGGING
--------------------------------
runtime\brain.log
runtime\world.json
runtime\probe-report.log
runtime\scum-events.log
runtime\scum-commands.log

SAFETY / SERVER SCOPE
---------------------
Use this on your own modded/no-BattlEye server. The package intentionally does not contain
anti-cheat bypass or stealth mechanisms.


0.1.3 WORLDFIX NOTES
=====================
- Persistent groups store member IDs and are rehydrated to canonical NPC objects on load.
- Runtime updates preserve the previous runtime/world state.
- High-frequency actor positions use a bounded overwrite state snapshot instead of append-only telemetry.
- Zombie flee vectors are proximity-weighted and stale flee/combat orders are cleared.
- Stress feature flags apply consistently to zombie, gunshot, leader-death and virtual-combat stress.
- Group auto-formation respects broad affiliation compatibility.
- Trauma decay and relationship evolution run during world simulation.
- UE4SS 3.x engine override is patched in [EngineVersionOverride] using MajorVersion=4 / MinorVersion=27.
- Only required UE4SS settings are patched; shared settings/mod lists are backed up and restored on failed install.
- First capability probe restores vanilla BrainComponent only after verifying StartLogic with IsRunning.
- Background map teleport altitude is explicitly marked approximate; NPC-marker teleport uses the actor's exact Z.

- Default managed NPC population cap is 100 and is data-driven in default.json.
- Auto takeover only escalates after the live capability probe proves brain stop, movement and brain restore.
- Stuck recovery is wired into the live navigation path.
- Group diplomacy refreshes when a group class changes.
- Virtual retreat, autonomous roaming, zombie combat consequences and leader injury effects are active.
- Temporary trauma uses modifiers instead of mutating base personality traits.
- Map polling uses a compact snapshot; full NPC details are fetched on selection.
- Group history is bounded and shared UE4SS settings are restored on uninstall when untouched.


0.1.4 AUDIT4FIX NOTES
=====================
- Delayed leader succession is preserved; refreshGroup no longer elects a leader during LEADERLESS delay.
- NPCs ignored at the managed cap can be admitted later from live position snapshots when capacity opens.
- Completed virtual group retreats clear back to idle/roaming.
- user.json is the persistent user override config and survives package updates.
- Node and UE4SS takeover modes are generated from the same effective configuration.
- Packaged SCUM start/stop BAT files honor TESLES_SCUM_SERVER_ROOT, so install/rollback works from any extraction folder.
- Collision-prone spawn-cell stable keys and spatial nearest-body fallback rebinding were removed; only verified stable reflected identities may rebind across sessions. Unstable identities remain session-scoped.
- Movement probe timeout branches are separated and reachable.
- Auto takeover is explicitly safe-probe until live weapon command control is implemented; it no longer waits on an unreachable internal flag.
