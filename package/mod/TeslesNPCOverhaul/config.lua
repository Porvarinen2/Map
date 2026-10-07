-- TESLES NPC OVERHAUL - server configuration.
-- Distances are Unreal units unless a name says otherwise. 100 UU = 1 metre.
return {
    Version = "2.1.13",

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
    PhysicalRunSpeedUU = 262,       -- fleeing, catching up: SCUM's own jog pace

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
    -- How deadly fights between squads are (hit chance multiplier, 1 = the
    -- full hit chance). Near a player, where the squads have real bodies:
    -- (1.25 from 2.1.1: at 0.75 squads near players rarely killed anyone.)
    PlayerAreaCombatLethality = 1.25,
    -- Away from every player (fought on the map only):
    VirtualCombatLethality = 0.5,
    -- true: fights between two squads near players are handed to SCUM's
    -- own combat AI. Off: SCUM's AI never fired at another squad, with any
    -- team setting (2.1.5 team 5, 2.1.7 the players' team 0 - no hits).
    -- The director fights them instead, with SCUM's own combat numbers.
    NativeSquadFights = false,
    -- The server's NPC difficulty (0 easy, 1 normal, 2 hard): which of
    -- SCUM's firing rhythms squads use against each other.
    ScumNPCDifficulty = 1,
    -- Damage of a hit between squads (1 = the weapon's own).
    CombatDamageScale = 1.0,
    -- true: SCUM's own sight and hearing are off while the director walks
    -- an NPC (on again for a fight with a player). With them on, SCUM's AI
    -- chased animals and zombies on its own and aimed at them crouched
    -- while the body walked on - the crouched sliding.
    BlindDirectedNPCs = true,
    -- true: SCUM's own NPC AI (a state machine in the controller) is paused
    -- while the director walks an NPC, so it plays no crouched idle actions
    -- and walks no Guard back to its post mid-route. It runs again only in
    -- SCUM's own fights with players.
    PauseScumAIWhileDirected = true,
    -- The AI team trick for those fights: one side counts as the players'
    -- team for the other side's AI. false: only the generic team ids.
    NativeSquadAITeam = true,
    -- The team one side gets (SCUM's EAITeam: 0 Prisoner = the players,
    -- 5 Neutral, 10 ArmedNPC). Up to 2.1.6 this was 5, which no AI attacks.
    NativeSquadAITeamId = 0,
    -- ------------------------------------------------------------- stress ---
    -- How much stress an average NPC sheds in five minutes out of danger
    -- (0.01 = one point). Veterans and soldiers recover faster, survivors,
    -- hunters and civilians slower; every trauma slows it further.
    -- 0.10 from 2.0.5: at 0.01 a panicked survivor needed up to ten hours to
    -- calm down, and half the island was in panic all the time.
    StressRecoveryPer5Min = 0.10,
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
    -- 70 m and 80 degrees are SCUM's own NPC sight (its AI controllers).
    NPCDetectRangeM = 70,
    NPCFireRangeM = 100,
    NPCScopedFireRangeM = 250,
    NPCViewAngleDeg = 80,
    NPCCloseSenseM = 5,

    -- NPC VS NPC: how squads find and fight each other. All kept on updates.
    -- A squad notices another squad this far away (metres)...
    SquadDetectRangeM = 200,
    -- ...and, near players (where squads have bodies), only if a member
    -- sees it: in front of it (NPCViewAngleDeg to either side) with a clear
    -- line of sight. A squad that is shot at knows where from. false: range
    -- alone, through walls and hills.
    SquadNeedsSight = true,
    -- The distance squads fight from (metres), whatever their guns: a
    -- rifle hits well from there, a pistol or shotgun badly (their reach,
    -- below, is where their aim starts to fall off steeply).
    SquadFightDistanceM = 100,
    -- A member closer than this share of its fighting distance backs off.
    SquadBackOffShare = 0.55,
    -- How far each kind of weapon shoots in squad fights (metres).
    WeaponRangePistolM = 50,
    WeaponRangeSmgM = 80,
    WeaponRangeShotgunM = 35,
    WeaponRangeRifleM = 150,
    WeaponRangeScopedM = 200,
    WeaponRangeBowM = 50,
    WeaponRangeCrossbowM = 60,
    -- true: an NPC that got a shotgun is spawned again (out of players'
    -- sight) for another weapon: shotgun pellets fly where the muzzle
    -- points, and a server never animates NPCs, so that is the ground.
    SquadAvoidShotguns = true,
    -- Hit chance between squads with bodies (1 = normal, 2 = twice).
    SquadAccuracy = 1.0,
    -- true: a squad at least as strong keeps shooting at one that breaks
    -- off and runs, while it is in reach.
    SquadPursuit = true,
    -- How far a squad that breaks off runs (metres).
    SquadRetreatM = 150,
    -- true: hits between squads with bodies come only from SCUM's real
    -- bullets (the director fires the members' own weapons at their
    -- targets), no dice. Turn on only once director.log shows
    -- "bullet damage:" lines - otherwise nobody would ever be hit.
    RealBulletsOnly = false,

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
