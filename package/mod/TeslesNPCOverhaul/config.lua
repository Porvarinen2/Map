-- TESLES NPC OVERHAUL - server configuration.
-- Distances are Unreal units unless a name says otherwise. 100 UU = 1 metre.
return {
    Version = "2.0.1",

    -- Language of the live map and messages: "en" or "fi".
    Language = "en",

    -- ---------------------------------------------------------- population --
    Enabled = true,
    TargetNPCs = 200,               -- NPCs on the island (hard cap 250)
    -- REPLENISH: a squad wiped out is replaced by a new squad of a random
    -- type somewhere on the map, and while there are fewer NPCs than
    -- TargetNPCs a couple of new squads arrive every minute. The radiation
    -- zone (C0) and island (Z4) squads always come back in their own place.
    EnableReplenish = true,
    WorldSeed = 0,                  -- 0 = derive from first start, then stored

    -- ---------------------------------------------------------------- tick --
    TickMs = 1000,                  -- director tick period
    StartupDelaySec = 25,           -- let the server finish loading first
    -- The director ticks on the game thread through UE4SS's
    -- LoopInGameThreadWithDelay. false moves every tick to UE4SS's own timer
    -- thread instead (LoopAsync). Only for a UE4SS build whose game-thread
    -- timer misbehaves; say so if you need it.
    RunTicksOnGameThread = true,
    MaxDeltaSec = 12,               -- no catch-up burst after a server stall
    RouteSolvesPerTick = 2,         -- route searches allowed per tick
    RouteExpansionsPerTick = 7000,  -- shared A* work cap per tick
    RouteMillisecondsPerTick = 22,  -- wall-clock cap on route solving per tick
    SaveIntervalSec = 45,
    TelemetryIntervalSec = 2,

    -- ------------------------------------------------------------ movement --
    -- The path follower is deliberately conservative about re-commanding.
    -- Raising ReissueSec or RetargetEpsUU makes movement smoother but slower
    -- to react; lowering them brings the old stuttering back.
    MoveAcceptanceRadiusUU = 220.0,
    FollowerAcceptanceRadiusUU = 320.0,
    ReissueSec = 22,
    RetargetEpsUU = 450,
    FormationSpreadUU = 900,
    FormationDepthUU = 1000,
    EnableMovementDebug = true,     -- writes output\movement_debug.tsv

    -- --------------------------------------------------------- travel pace --
    VirtualTravelSpeedUU = 340,     -- 3.4 m/s while virtual
    VirtualRoadSpeedMultiplier = 1.25,
    PhysicalWalkSpeedUU = 135,      -- SCUM's own NPC walk speed: faster slides
    PhysicalTravelSpeedUU = 135,
    PhysicalRunSpeedUU = 450,       -- fleeing

    -- ------------------------------------------------------ render circle ---
    -- A squad within this map distance (2D, height ignored) of any player is
    -- physical; beyond it, virtual. Nothing in between.
    RenderRadiusUU = 100000,        -- 1 km
    MaxPhysicalGroups = 12,
    -- One spawn per tick until this server proves it can materialise an NPC,
    -- then the larger budget. Class loading, physics, AI and replication all
    -- land on the game thread together, and a burst of them stalls the tick.
    MaxSpawnsPerTick = 1,
    MaxSpawnsPerTickProven = 5,     -- a whole squad at once, side by side
    SpawnRetrySec = 25,
    -- Refuse to spawn where navigation cannot prove the ground height. An
    -- actor dropped from a guessed height falls, and that is a failed spawn.
    RequireGroundProof = true,

    -- ------------------------------------------------- engine scan budget --
    -- Reflection scans are the expensive part of a tick, so their results are
    -- reused for this many seconds instead of being repeated per group.
    PlayerScanIntervalSec = 2,
    -- A joining player counts once their pawn has stood in the world this
    -- long. The join crash was UE4SS's own hooks, not this, so it is short.
    JoinGraceSec = 3,
    ZombieScanIntervalSec = 4,
    -- Only the mod's groups walk the island: SCUM's own armed NPCs (Drifter
    -- and Guard encounter spawns) are removed near players. Zombies stay.
    RemoveVanillaArmedNPCs = true,
    VanillaCleanupIntervalSec = 3,

    -- ------------------------------------------------------------- combat --
    -- ------------------------------------------------------------- stress ---
    -- How much stress an average NPC sheds in five minutes out of danger
    -- (0.01 = one point). Veterans and soldiers recover faster, survivors,
    -- hunters and civilians slower; every trauma slows it further.
    StressRecoveryPer5Min = 0.01,
    -- false: NPCs keep the weapon SCUM gives them (it fires) and the mod adds
    -- a magazine, random rounds, condition and sometimes a scope.
    -- true: the old way, a weapon swapped in afterwards - such NPCs do not
    -- fire in fights with players (1.9.x tests).
    SwapWeapons = false,
    -- Setting SCUM's weapon list before the spawn crashed the server with
    -- this UE4SS (1.9.13). Keep false.
    PresetWeapons = false,
    -- Ghost weapon: SCUM's own weapon (the one the NPC fires) is hidden and
    -- the squad's weapon of the same type is shown in its hand; on death
    -- the hidden one is removed and the shown one drops as loot.
    GhostWeapons = true,
    -- CUSTOM WEAPON CHANCE: 0 = nobody (vanilla: SCUM's own weapons),
    -- 0.5 = half of the NPCs, 1.0 = everyone (when a matching one exists).
    -- Kept on updates.
    GhostWeaponChance = 0.0,
    -- TOP WEAPONS (SVD, sniper rifles, the best assault rifles and machine
    -- guns): only this share of the NPCs that would carry one get it, the
    -- rest one tier lower. 0.2 = one in five, 1.0 = all.
    TopWeaponChance = 0.2,

    -- SIGHT AND FIRE: an NPC notices a player this far away (metres), only
    -- in front of it (angle to either side) and with a clear line of sight.
    -- Right next to it (CloseSenseM) it notices even from behind. It opens
    -- fire at FireRangeM, with a scope at ScopedFireRangeM. Hunters go after
    -- the animals they see.
    NPCDetectRangeM = 300,
    NPCFireRangeM = 100,
    NPCScopedFireRangeM = 250,
    NPCViewAngleDeg = 45,
    NPCCloseSenseM = 5,

    -- Your own squad weapons: see loadouts.lua (kept on updates).

    EnableCombat = true,
    ContactRadiusUU = 12000,        -- 120 m hostile group contact
    ZombieRadiusUU = 14000,         -- 140 m zombie pressure
    PreferredRangeUU = 2500,        -- 25 m ranged stand-off
    MoraleRetreatThreshold = 0.25,

    -- ---------------------------------------------------------- buildings --
    -- Squads go through the houses at the places they visit.
    EnableBuildingSearch = true,    -- squads go through houses at the places they visit
    BuildingSearchRadiusUU = 12000,
    MaxBuildingsPerTarget = 8,
    InteriorDelaySec = 15,
    VisitedBuildingHistory = 50,

    -- --------------------------------------------------------- ownership ---
    -- Stops SCUM's encounter logic re-commanding an actor the director owns.
    -- Turn off if another mod needs to keep control of NPC behaviour trees.
    TakeOwnership = true,

    -- ------------------------------------------------------------ logging --
    LogLevel = "info",              -- error | warn | info | debug
    LogEcho = true,                 -- also print to the UE4SS console
}
