# Tesles NPC Overhaul 0.1.2 Robust Fix Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Remove all defects found in the second cold audit and produce a regression-tested 0.1.2 ZIP that preserves persistent world state and fails safely around SCUM/UE4SS integration.

**Architecture:** Keep the existing modular Node brain, Lua UE4SS bridge, PowerShell installer, and web viewer. Fix module boundaries rather than coupling systems: persistence serializes IDs and rehydrates canonical NPC references; high-rate positional telemetry moves to an overwrite snapshot channel; SCUM takeover remains capability-gated; installer patches shared UE4SS state minimally and rolls back on failure.

**Tech Stack:** Node.js 18+, built-in node:test, UE4SS Lua, PowerShell/Batch, browser JavaScript.

**Spec:** `TeslesNPCOverhaul_DesignSpec_v1.0.txt`

## Global Constraints
- Dedicated server root default: `F:\SteamLibrary\steamapps\common\SCUM Server`.
- Installer must stop SCUM before changes and restart it after successful install.
- Uninstall/install may remove only files owned by TeslesNPCOverhaul; shared UE4SS settings and mod lists must be preserved.
- SCUM-specific reflected functions must be capability-probed instead of guessed.
- Groups contain 1-5 NPCs and are level 1-5.
- Existing persistent NPC world data must survive updates.
- Feature flags must be respected independently.

---

### Task 1: Persistence Canonicalization
**Files:** `brain/src/persistence/worldStore.js`, `brain/test/robustfix-regressions.test.js`
**Interfaces:** saveWorld(file, world), loadWorld(file) returns groups whose members are canonical references from world.npcs.
- [ ] Add failing save/load reference-identity test.
- [ ] Verify red.
- [ ] Serialize groups with member IDs only and rehydrate on load, including legacy saves.
- [ ] Verify green.

### Task 2: AI/Group Regression Fixes
**Files:** `brain/src/director/worldDirector.js`, `brain/src/groups/autoGroup.js`, `brain/src/groups/leadership.js`, `brain/src/combat/groupCombat.js`, `brain/src/zombies/threat.js`, tests.
**Interfaces:** feature flags prevent stress mutation; incompatible factions do not merge; zombie flee vector points away from local weighted threat; stale group combat targets clear; trauma decay runs.
- [ ] Add failing regression tests for stress flag, incompatible grouping, elite group class, zombie flee/clear, stale combat target, trauma decay and relationship evolution.
- [ ] Verify red.
- [ ] Implement minimal fixes.
- [ ] Verify green.

### Task 3: Telemetry and IPC Robustness
**Files:** `brain/src/server.js`, `ue4ss/.../ipc.lua`, `ue4ss/.../scum_adapter.lua`, runtime config, tests.
**Interfaces:** event log carries discrete events; `scum-state.log` is an overwrite snapshot for positions; Node reads both.
- [ ] Add failing static/runtime tests for state snapshot configuration and no high-frequency position appends.
- [ ] Verify red.
- [ ] Implement snapshot reader/writer and actor snapshot emission.
- [ ] Verify green.

### Task 4: Capability Probe Correctness
**Files:** `ue4ss/.../scum_adapter.lua`, tests.
**Interfaces:** movement capability is true only after observed displacement toward a probe target; brain restore is true only if `IsRunning()` confirms it.
- [ ] Add failing static tests.
- [ ] Verify red.
- [ ] Implement asynchronous move probe and verified brain restore.
- [ ] Verify green.

### Task 5: Installer/Uninstaller Safety
**Files:** `installer/Install.ps1`, `installer/Uninstall.ps1`, Batch scripts, package tests.
**Interfaces:** Node >=18 validated; packaged stop/start BAT files are used; runtime data survives upgrades; mods.json/mods.txt is edited without enabled.txt; UE4SS settings are patched by key only; failure restores backup and disables/removes partial deployment before restarting server.
- [ ] Add failing static package tests.
- [ ] Verify red.
- [ ] Implement install/rollback/minimal settings patch/mod-list handling.
- [ ] Verify green.

### Task 6: Map Viewer Teleport Safety
**Files:** `web/public/app.js`, `brain/src/server.js`, tests.
**Interfaces:** map background click without a known terrain Z must not silently generate an authoritative 30000-Z command; NPC clicks keep exact actor Z.
- [ ] Add failing API/viewer test.
- [ ] Verify red.
- [ ] Return a 2D teleport command for unknown Z only if SCUM syntax supports it; otherwise mark map click Z as approximate in copied command/UI.
- [ ] Verify green.

### Task 7: Full Verification and Packaging
**Files:** all package files, `CHANGELOG.txt`, `VERSION`.
- [ ] Run all Node tests.
- [ ] Run smoke simulation.
- [ ] Parse all JSON.
- [ ] Run Node syntax checks over all JS.
- [ ] Perform package static audit for Lua/PowerShell/Batch invariants.
- [ ] ZIP from a clean staging directory.
- [ ] Extract ZIP to a fresh directory and rerun all possible tests against extracted package.
- [ ] Generate SHA-256 checksum.
