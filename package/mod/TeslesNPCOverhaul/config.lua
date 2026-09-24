-- TESLES NPC OVERHAUL - server configuration.
-- Distances are Unreal units unless a name says otherwise. 100 UU = 1 metre.
return {
    Version = "1.9.2",

    -- ---------------------------------------------------------- population --
    Enabled = true,
    TargetNPCs = 100,               -- guide default; hard cap is 250
    EnableReplenish = false,        -- dead NPCs are NOT auto-replaced by default
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
    PhysicalWalkSpeedUU = 300,
    PhysicalTravelSpeedUU = 420,

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

    -- Omat varusteet: katso varusteet.lua (sailyy paivityksissa).

    EnableCombat = true,
    ContactRadiusUU = 12000,        -- 120 m hostile group contact
    ZombieRadiusUU = 14000,         -- 140 m zombie pressure
    PreferredRangeUU = 2500,        -- 25 m ranged stand-off
    MoraleRetreatThreshold = 0.25,

    -- ---------------------------------------------------------- buildings --
    -- Off by default: the door and interior steps are not proven on this
    -- server yet, and the guide is explicit that a timer is not proof.
    EnableBuildingSearch = false,
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
