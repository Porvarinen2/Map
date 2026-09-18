# Tesles NPC Overhaul Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a self-contained, modular SCUM dedicated-server NPC overhaul package with UE4SS runtime bridge, persistent Node.js world simulation, dynamic NPC/group/zombie systems, live browser map, clean installer/uninstaller, and capability-gated SCUM takeover.

**Architecture:** A thin UE4SS Lua bridge owns SCUM-facing discovery/control and writes normalized events to a file IPC channel. A separate Node.js brain process owns persistent NPC entities, traits, stress, trauma, groups, leadership, diplomacy, zombie pressure, utility decisions, virtual simulation, telemetry, and the web map. All SCUM-specific assumptions are isolated behind a capability probe and adapter; unsupported primitives degrade to observation-only instead of silently half-working.

**Tech Stack:** UE4SS Lua, Node.js 18+ with only built-in modules, HTML/CSS/vanilla JS, Windows batch + PowerShell installer.

**Spec:** `docs/superpowers/specs/2026-09-17-tesles-npc-overhaul-design.txt`

## Global Constraints
- Canonical default server root: `F:\SteamLibrary\steamapps\common\SCUM Server`.
- Install must stop SCUMServer, install dependencies, deploy mod, validate, start Node brain, and restart SCUM Server with `-log -MaxPlayers=64 -nobattleye`.
- Uninstall may remove only files recorded in the package manifest or dedicated Tesles directories.
- SCUM decision-AI takeover is capability-gated; observation mode remains available when takeover is not proven.
- One to five NPCs per group; group level 1–5; individual NPC skill tier 1–5 is independent of group level and SCUM body blueprint level.
- Every persistent NPC has independent traits, skills, stress, memory, trauma, relationships, group state and virtual world state.
- Groups may fight each other and zombies affect routing, stress, casualties, leadership, morale and off-screen simulation.
- Browser map shows every NPC marker and detailed NPC/group state; right-click copies `#Teleport X Y Z`, using exact NPC Z when applicable and configured fallback Z elsewhere.
- No web-framework or npm package dependency is required at runtime.

---

### Task 1: Core deterministic domain model
**Files:** `brain/src/core/*`, `brain/src/traits/*`, `brain/src/skills/*`, `brain/src/archetypes/*`, `brain/test/core.test.js`
- [ ] Write failing tests for seeded trait generation, archetype bias, skill tiers, and entity uniqueness.
- [ ] Run tests and confirm module-not-found / assertion failure.
- [ ] Implement deterministic PRNG, trait/skill registries, archetypes and entity factory.
- [ ] Run tests and confirm pass.
- [ ] Commit.

### Task 2: Stress, trauma, memory and relationships
**Files:** `brain/src/state/*`, `brain/src/memory/*`, `brain/src/relationships/*`, `brain/test/psychology.test.js`
- [ ] Write failing tests for gunshot/zombie stress, recovery, panic threshold, trauma acquisition, memory and relationship changes.
- [ ] Run tests and confirm fail.
- [ ] Implement state modules through pure functions and event application.
- [ ] Run tests and confirm pass.
- [ ] Commit.

### Task 3: Groups, classes, leadership and diplomacy
**Files:** `brain/src/groups/*`, `brain/test/groups.test.js`
- [ ] Write failing tests for size 1–5, group levels 1–5, leader selection, leader death shock, succession and hostility state.
- [ ] Run tests and confirm fail.
- [ ] Implement group classes, cohesion/morale, leadership scoring, succession and diplomacy.
- [ ] Run tests and confirm pass.
- [ ] Commit.

### Task 4: Zombies, group combat and virtual simulation
**Files:** `brain/src/zombies/*`, `brain/src/combat/*`, `brain/src/virtual/*`, `brain/test/world.test.js`
- [ ] Write failing tests for zombie pressure, flee/fight decisions, virtual movement, casualties and NPC-vs-NPC group encounters.
- [ ] Run tests and confirm fail.
- [ ] Implement zombie pressure fields, group combat resolution and simulation LOD.
- [ ] Run tests and confirm pass.
- [ ] Commit.

### Task 5: Utility AI and navigation policy
**Files:** `brain/src/ai/*`, `brain/src/navigation/*`, `brain/test/ai.test.js`
- [ ] Write failing tests for trait-sensitive scoring, action inertia, repath thresholds, final approach and stuck recovery state.
- [ ] Run tests and confirm fail.
- [ ] Implement utility scorer and navigation policy that emits intents instead of touching SCUM directly.
- [ ] Run tests and confirm pass.
- [ ] Commit.

### Task 6: Persistence, director and IPC
**Files:** `brain/src/persistence/*`, `brain/src/director/*`, `brain/src/bridge/*`, `brain/test/director.test.js`
- [ ] Write failing tests for atomic save/load, event ingestion, command emission, restart persistence and feature health.
- [ ] Run tests and confirm fail.
- [ ] Implement world director, persistence and line-oriented IPC protocol.
- [ ] Run tests and confirm pass.
- [ ] Commit.

### Task 7: Live SCUM map and teleport-copy UI
**Files:** `brain/src/server.js`, `web/*`, `brain/test/web.test.js`
- [ ] Write failing tests for telemetry endpoint and teleport command builder.
- [ ] Run tests and confirm fail.
- [ ] Implement HTTP service and dependency-free canvas map with NPC/group details and right-click context menu.
- [ ] Run tests and confirm pass.
- [ ] Commit.

### Task 8: UE4SS capability probe and runtime bridge
**Files:** `ue4ss/TeslesNPCOverhaul/scripts/*`
- [ ] Implement reflection-only capability probe that enumerates candidate NPC/controller/brain functions and writes explicit probe status.
- [ ] Implement Pawn discovery, location/controller/brain access, brain suppression attempts, standard UE MoveTo attempts, telemetry and command polling behind `pcall` boundaries.
- [ ] Ensure unsupported combat/spawn primitives are marked unavailable rather than guessed.
- [ ] Add observation-only fallback and takeover watchdog.
- [ ] Static-check Lua files and document runtime quality gate.
- [ ] Commit.

### Task 9: Installer, uninstaller and watchdog
**Files:** `install.bat`, `uninstall.bat`, `installer/*.ps1`, `server/*.bat`, `manifest.json`
- [ ] Implement stop logic matching supplied SCUM server executable path/process behavior.
- [ ] Bootstrap Node.js if absent and UE4SS zDEV if UE4SS is absent; never overwrite an existing UE4SS install blindly.
- [ ] Deploy UE4SS mod, write absolute runtime configuration, start brain service, restart server with supplied command line, validate processes and preserve rollback backup.
- [ ] Implement manifest-scoped uninstall and restore startup behavior.
- [ ] Add dry-run validation mode.
- [ ] Commit.

### Task 10: Package verification and release ZIP
**Files:** `README.txt`, `CHANGELOG.txt`, `VERSION`, diagnostics scripts
- [ ] Run all Node tests.
- [ ] Validate JSON, batch/PowerShell syntax where tooling allows, package structure and no placeholder tokens.
- [ ] Run standalone brain smoke test and HTTP viewer smoke test.
- [ ] Verify installer source references canonical server path and startup arguments.
- [ ] Build ZIP and checksum.
