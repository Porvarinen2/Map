-- TESLES NPC OVERHAUL - UE4SS entry point.
--
-- This file does three things and nothing else: work out where the mod lives,
-- wire the modules together, and drive the tick. All engine contact is inside
-- bridge/scum.lua; everything else is plain Lua and is covered by the test
-- suite that ships in the package.

local MOD_NAME = "TeslesNPCOverhaul"

-- --------------------------------------------------------------- mod path --

-- UE4SS may present the script folder as "Scripts" or "scripts", and may use
-- either path separator. Always take the parent of whatever folder this file
-- is in rather than matching a name: earlier versions matched only lowercase
-- "scripts" and ended up looking for config.lua inside the script folder.
local function split_dir(path)
    local cut = 0
    for i = #path, 1, -1 do
        local c = path:sub(i, i)
        if c == "\\" or c == "/" then cut = i; break end
    end
    if cut == 0 then return ".", path end
    return path:sub(1, cut - 1), path:sub(cut + 1)
end

local function mod_dir()
    local src = debug.getinfo(1, "S").source
    if src:sub(1, 1) == "@" then src = src:sub(2) end
    local script_dir = split_dir(src)
    local parent = split_dir(script_dir)
    if parent and parent ~= "" and parent ~= "." then return parent end
    return script_dir
end

local MOD_DIR = mod_dir()
local SEP = MOD_DIR:find("\\", 1, true) and "\\" or "/"
package.path = MOD_DIR .. SEP .. "?.lua;" .. package.path

local ok_cfg, CFG = pcall(dofile, MOD_DIR .. SEP .. "config.lua")
if not ok_cfg or type(CFG) ~= "table" then
    CFG = { Version = "1.0.0", Enabled = true, TickMs = 1000, TargetNPCs = 100 }
end

-- ----------------------------------------------------------------- modules --

local Log        = require("core.log")
local Persist    = require("core.persist")
local Grid       = require("world.navgrid")
local Road       = require("world.roadnet")
local POI        = require("world.pois")
local Movement   = require("sim.movement")
local Physical   = require("sim.physical")
local Combat     = require("sim.combat")
local Buildings  = require("sim.buildings")
local Population = require("sim.population")
local Director   = require("sim.director")
local Bridge     = require("bridge.scum")
local Telemetry  = require("bridge.telemetry")

local STATE_DIR  = MOD_DIR .. SEP .. "state"
local OUTPUT_DIR = MOD_DIR .. SEP .. "output"

Log.configure(OUTPUT_DIR, CFG.LogLevel, CFG.LogEcho)
Persist.configure(STATE_DIR, CFG.SaveIntervalSec)
Telemetry.configure(OUTPUT_DIR)

-- Push the config's tunables into the modules that own them.
Physical.tuning.full_uu = CFG.FullDistanceUU or Physical.tuning.full_uu
Physical.tuning.light_uu = CFG.LightDistanceUU or Physical.tuning.light_uu
Physical.tuning.materialize_uu = CFG.MaterializeDistanceUU or Physical.tuning.materialize_uu
Physical.tuning.virtualize_uu = CFG.VirtualizeDistanceUU or Physical.tuning.virtualize_uu
Physical.tuning.max_spawns_per_tick = CFG.MaxSpawnsPerTick or Physical.tuning.max_spawns_per_tick
Physical.tuning.spawn_retry_sec = CFG.SpawnRetrySec or Physical.tuning.spawn_retry_sec
Physical.tuning.max_physical_groups = CFG.MaxPhysicalGroups or Physical.tuning.max_physical_groups
Movement.tuning.reissue_sec = CFG.ReissueSec or Movement.tuning.reissue_sec
Movement.tuning.retarget_eps = CFG.RetargetEpsUU or Movement.tuning.retarget_eps
Combat.tuning.contact_uu = CFG.ContactRadiusUU or Combat.tuning.contact_uu
Combat.tuning.zombie_uu = CFG.ZombieRadiusUU or Combat.tuning.zombie_uu
Combat.tuning.preferred_range_uu = CFG.PreferredRangeUU or Combat.tuning.preferred_range_uu
Combat.tuning.morale_retreat = CFG.MoraleRetreatThreshold or Combat.tuning.morale_retreat
Buildings.tuning.search_radius_uu = CFG.BuildingSearchRadiusUU or Buildings.tuning.search_radius_uu
Buildings.tuning.max_buildings = CFG.MaxBuildingsPerTarget or Buildings.tuning.max_buildings
Buildings.tuning.interior_delay_sec = CFG.InteriorDelaySec or Buildings.tuning.interior_delay_sec
Buildings.tuning.visited_history = CFG.VisitedBuildingHistory or Buildings.tuning.visited_history
Population.HARD_CAP = 250

-- ------------------------------------------------------------------- world --

local M = { world = nil, director = nil, started_at = os.time(),
            last_telemetry = 0, ticking = false, ticks = 0, errors = 0 }

local function boot_world()
    local saved = Persist.load()
    if saved and saved.groups and #saved.groups > 0 then
        local ok, world = pcall(Population.deserialize, saved)
        if ok and world then
            Log.info(string.format("world state loaded: %d groups, %d NPCs",
                #world.groups, Population.alive_npc_count(world)))
            Bridge.health.persistence = { status = "OK", detail = "world state loaded" }
            return world
        end
        Log.error("world state could not be restored; generating a new world")
    end

    local seed = CFG.WorldSeed
    if not seed or seed == 0 then seed = os.time() end
    local world = Population.new_world({
        seed = seed,
        target_npcs = math.min(250, CFG.TargetNPCs or 100),
    })
    Population.generate(world, Log.info)
    Bridge.health.persistence = { status = "OK", detail = "new world generated" }
    return world
end

-- ------------------------------------------------------------------- tick --

local function safe_tick()
    if M.ticking then return end
    M.ticking = true
    local ok, err = pcall(function()
        local now = os.time()
        M.director:tick(now)
        M.ticks = M.ticks + 1

        if now - M.last_telemetry >= (CFG.TelemetryIntervalSec or 2) then
            M.last_telemetry = now
            Telemetry.write(M.world, Bridge, M.director, {
                version = CFG.Version,
                uptime = now - M.started_at,
            })
        end

        if Persist.due(now) then
            Persist.rotate()
            Persist.save(Population.serialize(M.world))
        end
    end)
    M.ticking = false
    if not ok then
        M.errors = M.errors + 1
        Log.error("tick failed: " .. tostring(err))
        if M.errors == 1 or M.errors % 25 == 0 then
            Bridge.health.brain = { status = "DEGRADED",
                                    detail = M.errors .. " tick errors" }
        end
    end
end

-- Engine work must run on the game thread. Outside the game (tests, syntax
-- checks) the function is simply called directly.
local function on_game_thread(fn)
    if type(ExecuteInGameThread) == "function" then
        ExecuteInGameThread(fn)
    else
        fn()
    end
end

local function start()
    Log.info("TESLES NPC OVERHAUL " .. tostring(CFG.Version) .. " starting")
    Log.info(string.format("nav grid %dx%d, road net %d nodes / %d edges, %d POIs",
        Grid.size, Grid.size, Road.node_count, Road.edge_count, POI.count))

    Bridge.init(CFG)
    Bridge.health.worldRouting = { status = "OK",
        detail = string.format("dry-land grid %dx%d / %d POIs", Grid.size, Grid.size, POI.count) }

    M.world = boot_world()
    Bridge.health.worldPopulation = { status = "OK",
        detail = string.format("%d persistent NPCs / %d groups",
            Population.alive_npc_count(M.world), #M.world.groups) }

    M.director = Director.new({
        world = M.world,
        bridge = Bridge,
        config = CFG,
        seed = M.world.seed,
    })

    Telemetry.write(M.world, Bridge, M.director,
        { version = CFG.Version, uptime = 0 })

    if type(LoopAsync) == "function" then
        LoopAsync(CFG.TickMs or 1000, function()
            on_game_thread(safe_tick)
            return false
        end)
        Log.info("director loop running at " .. tostring(CFG.TickMs) .. " ms")
    else
        Log.warn("LoopAsync unavailable: the director will not tick by itself")
    end
end

if CFG.Enabled == false then
    Log.info("TESLES NPC OVERHAUL is disabled in config.lua")
    return
end

-- Give the server time to finish loading before the first scan.
if type(ExecuteWithDelay) == "function" then
    ExecuteWithDelay((CFG.StartupDelaySec or 25) * 1000, function()
        local ok, err = pcall(start)
        if not ok then Log.error("startup failed: " .. tostring(err)) end
    end)
else
    local ok, err = pcall(start)
    if not ok then Log.error("startup failed: " .. tostring(err)) end
end

return M
