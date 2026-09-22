-- TESLES NPC OVERHAUL - server configuration.
-- Distances are Unreal units unless a name says otherwise. 100 UU = 1 metre.
return {
    Version = "1.0.2",

    -- ---------------------------------------------------------- population --
    Enabled = true,
    TargetNPCs = 100,               -- guide default; hard cap is 250
    EnableReplenish = false,        -- dead NPCs are NOT auto-replaced by default
    WorldSeed = 0,                  -- 0 = derive from first start, then stored

    -- ---------------------------------------------------------------- tick --
    TickMs = 1000,                  -- director tick period
    StartupDelaySec = 25,           -- let the server finish loading first
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

    -- ------------------------------------------------- level of detail -----
    -- Guide bands: FULL <= 200 m, LIGHT <= 700 m, VIRTUAL beyond.
    -- Materialize / virtualize carry hysteresis so groups do not flicker.
    FullDistanceUU = 20000,
    LightDistanceUU = 70000,
    MaterializeDistanceUU = 60000,
    VirtualizeDistanceUU = 88000,
    MaxPhysicalGroups = 12,
    MaxSpawnsPerTick = 4,
    SpawnRetrySec = 25,

    -- ------------------------------------------------------------- combat --
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
