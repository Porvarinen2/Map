-- TESLES NPC OVERHAUL - UE4SS entry point.
--
-- This file works out where the mod lives, wires the modules together and
-- drives the tick. All engine contact is inside bridge/scum.lua; everything
-- else is plain Lua and is covered by the test suite.
--
-- Every stage writes to output\boot.log through a raw io.open before any
-- module is loaded. If the mod goes quiet, that file says exactly how far it
-- got, which is the difference between a diagnosable failure and silence.

local MOD_NAME = "TeslesNPCOverhaul"
local VERSION_FALLBACK = "1.0.0"

-- --------------------------------------------------------------- mod path --

-- UE4SS may present the script folder as "Scripts" or "scripts", and may use
-- either path separator. Always take the parent of whatever folder this file
-- is in rather than matching a name.
local function split_dir(path)
    local cut = 0
    for i = #path, 1, -1 do
        local c = path:sub(i, i)
        if c == "\\" or c == "/" then cut = i; break end
    end
    if cut == 0 then return ".", path end
    return path:sub(1, cut - 1), path:sub(cut + 1)
end

local SOURCE = debug.getinfo(1, "S").source
local SRC_PATH = SOURCE
if SRC_PATH:sub(1, 1) == "@" then SRC_PATH = SRC_PATH:sub(2) end
local SCRIPT_DIR = split_dir(SRC_PATH)
local MOD_DIR = split_dir(SCRIPT_DIR)
if MOD_DIR == "" or MOD_DIR == "." then MOD_DIR = SCRIPT_DIR end
local SEP = MOD_DIR:find("\\", 1, true) and "\\" or "/"

-- ------------------------------------------------------------- boot log ----

local BOOT_PATH = MOD_DIR .. SEP .. "output" .. SEP .. "boot.log"
local boot_target = nil

local function boot(msg)
    local line = os.date("%Y-%m-%d %H:%M:%S") .. "  " .. tostring(msg)
    if print then pcall(print, "[TeslesNPC] " .. line) end
    if boot_target == nil then
        -- Find a writable location once. output\ is created by the installer;
        -- fall back to the mod folder and then the script folder so a broken
        -- install still leaves a trace.
        for _, p in ipairs({
            BOOT_PATH,
            MOD_DIR .. SEP .. "boot.log",
            SCRIPT_DIR .. SEP .. "boot.log",
        }) do
            local f = io.open(p, "a")
            if f then f:close(); boot_target = p; break end
        end
        if boot_target == nil then boot_target = false end
    end
    if boot_target then
        local f = io.open(boot_target, "a")
        if f then f:write(line, "\n"); f:close() end
    end
end

-- A fresh boot log per start: the last start is the one being diagnosed.
do
    local f = io.open(BOOT_PATH, "w")
    if f then f:close() end
end

boot("---- " .. MOD_NAME .. " boot ----")
boot("lua        : " .. tostring(_VERSION))
boot("source     : " .. tostring(SOURCE))
boot("script dir : " .. tostring(SCRIPT_DIR))
boot("mod dir    : " .. tostring(MOD_DIR))
boot("separator  : " .. (SEP == "\\" and "backslash" or "slash"))
boot("log target : " .. tostring(boot_target))

package.path = MOD_DIR .. SEP .. "?.lua;"
    .. MOD_DIR .. SEP .. "?" .. SEP .. "init.lua;"
    .. package.path
boot("package.path set")

-- UE4SS ships Lua 5.4, but some builds embed 5.1/LuaJIT where math.atan takes
-- a single argument. Lua silently drops the extra argument rather than
-- erroring, so detect it by result: atan(1,-1) is 3pi/4 on 5.3+ and pi/4 on
-- 5.1. Restore the two-argument form before anything uses it.
if math.atan2 then
    local ok, v = pcall(math.atan, 1, -1)
    if not ok or math.abs(v - 2.3561944901923) > 1e-6 then
        local atan2 = math.atan2
        local atan1 = math.atan
        math.atan = function(y, x)
            if x == nil then return atan1(y) end
            return atan2(y, x)
        end
        boot("math.atan shim installed for Lua 5.1 / LuaJIT")
    end
end

-- ------------------------------------------------------------- config ------

local CFG
do
    local ok, result = pcall(dofile, MOD_DIR .. SEP .. "config.lua")
    if ok and type(result) == "table" then
        CFG = result
        boot("config.lua loaded (version " .. tostring(CFG.Version) .. ")")
    else
        CFG = { Version = VERSION_FALLBACK, Enabled = true, TickMs = 1000,
                TargetNPCs = 100 }
        boot("config.lua FAILED (" .. tostring(result) .. ") - using defaults")
    end
end

-- ----------------------------------------------------------------- modules --

-- Loaded one at a time so a failure names the module that broke instead of
-- taking the whole file down with a single stack trace.
local function need(name)
    local ok, mod = pcall(require, name)
    if not ok then
        boot("REQUIRE FAILED " .. name .. ": " .. tostring(mod))
        error("TeslesNPCOverhaul: could not load " .. name .. ": " .. tostring(mod), 0)
    end
    return mod
end

boot("loading modules")
local Log        = need("core.log")
local Persist    = need("core.persist")
local Grid       = need("world.navgrid")
local Road       = need("world.roadnet")
local POI        = need("world.pois")
local Movement   = need("sim.movement")
local Physical   = need("sim.physical")
local Combat     = need("sim.combat")
local Buildings  = need("sim.buildings")
local Population = need("sim.population")
local Director   = need("sim.director")
local Bridge     = need("bridge.scum")
local Telemetry  = need("bridge.telemetry")
boot("modules loaded")

local STATE_DIR  = MOD_DIR .. SEP .. "state"
local OUTPUT_DIR = MOD_DIR .. SEP .. "output"

Log.configure(OUTPUT_DIR, CFG.LogLevel, CFG.LogEcho)
Persist.configure(STATE_DIR, CFG.SaveIntervalSec)
Telemetry.configure(OUTPUT_DIR)

-- Prove the output folder is writable before the director relies on it.
do
    local probe = io.open(OUTPUT_DIR .. SEP .. "director.log", "a")
    if probe then
        probe:close()
        boot("output folder is writable: " .. OUTPUT_DIR)
    else
        boot("OUTPUT FOLDER NOT WRITABLE: " .. OUTPUT_DIR)
    end
end

-- Push the config's tunables into the modules that own them.
Physical.tuning.full_uu = CFG.FullDistanceUU or Physical.tuning.full_uu
Physical.tuning.light_uu = CFG.LightDistanceUU or Physical.tuning.light_uu
Physical.tuning.materialize_uu = CFG.MaterializeDistanceUU or Physical.tuning.materialize_uu
Physical.tuning.virtualize_uu = CFG.VirtualizeDistanceUU or Physical.tuning.virtualize_uu
Physical.tuning.max_spawns_per_tick = CFG.MaxSpawnsPerTick or Physical.tuning.max_spawns_per_tick
Physical.tuning.max_spawns_per_tick_proven = CFG.MaxSpawnsPerTickProven
    or Physical.tuning.max_spawns_per_tick_proven
if CFG.RequireGroundProof ~= nil then
    Physical.tuning.require_ground_proof = CFG.RequireGroundProof
end
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
    local now = os.time()
    if Bridge.begin_tick then Bridge.begin_tick(now) end

    local ok, err = pcall(function()
        M.director:tick(now)
        M.ticks = M.ticks + 1

        if Persist.due(now) then
            Persist.rotate()
            Persist.save(Population.serialize(M.world))
        end
    end)

    -- Telemetry is how anyone sees what is happening, so it must not depend on
    -- the tick having succeeded. A tick that fails is exactly when the live map
    -- needs to say so.
    if now - M.last_telemetry >= (CFG.TelemetryIntervalSec or 2) then
        M.last_telemetry = now
        local okt, terr = pcall(Telemetry.write, M.world, Bridge, M.director, {
            version = CFG.Version,
            uptime = now - M.started_at,
        })
        if not okt and not M.telemetry_failed then
            M.telemetry_failed = true
            Log.error("live_state.json could not be written: " .. tostring(terr))
            boot("TELEMETRY FAILED: " .. tostring(terr))
        end
    end

    M.ticking = false
    if not ok then
        M.errors = M.errors + 1
        Log.error("tick failed: " .. tostring(err))
        if M.errors == 1 then boot("FIRST TICK ERROR: " .. tostring(err)) end
        if M.errors == 1 or M.errors % 25 == 0 then
            Bridge.health.brain = { status = "DEGRADED",
                                    detail = M.errors .. " tick errors" }
        end
    end
end

-- ---------------------------------------------------------------- threads --
--
-- One rule: this mod's Lua runs on exactly one OS thread, and that thread is
-- the game thread.
--
-- Every earlier version broke it. ExecuteWithDelay and LoopAsync call back on
-- UE4SS's timer thread; ExecuteInGameThread only queues work for the game
-- thread and returns at once. So the timer thread went on running our code
-- (logging, re-arming the timer) while the game thread ran the tick - two
-- threads inside one Lua state. That is what every "impossible" error in the
-- server logs was: a function inside a string buffer, "invalid key to 'next'",
-- "attempt to index a _UBOX* value", timestamps printed as 00:00:57, and
-- eventually a hang or an access violation inside UE4SS.dll.
--
-- The UE4SS build shipped with this mod has timers that fire ON the game
-- thread: LoopInGameThreadWithDelay and ExecuteInGameThreadWithDelay. With
-- those, no callback of ours ever runs anywhere else, and ticks cannot overlap
-- because the game thread runs them one after another.
--
-- An older UE4SS without them gets the timer thread for everything instead.
-- That keeps the Lua state single-threaded, which is the part that corrupts;
-- engine calls from off the game thread are the lesser risk.
local function has(name) return type(_G[name]) == "function" end

local SLOW_TICK_MS = 250

local function timed_tick()
    local t0 = os.clock()
    safe_tick()
    local ms = (os.clock() - t0) * 1000
    M.last_tick_at = os.time()
    M.last_tick_ms = ms

    local slow = ms >= SLOW_TICK_MS
    if M.ticks <= 3 or (slow and ms > (M.worst_tick_ms or 0)) then
        local line = string.format("tick %d: %.0f ms", M.ticks, ms)
        if Bridge.scan then
            line = line .. string.format(" (scans %d, slowest %.0f ms %s)",
                Bridge.scan.calls, Bridge.scan.slowest_ms,
                Bridge.scan.slowest_name ~= "" and Bridge.scan.slowest_name or "-")
        end
        if slow then
            M.worst_tick_ms = ms
            Log.warn("SLOW " .. line)
            boot("SLOW " .. line)
        else
            boot(line)
        end
    end
end

local function start_ticking()
    local ms = CFG.TickMs or 1000
    if CFG.RunTicksOnGameThread ~= false and has("LoopInGameThreadWithDelay") then
        M.tick_driver = "LoopInGameThreadWithDelay (game thread)"
        LoopInGameThreadWithDelay(ms, function() timed_tick() end)
    elseif has("LoopAsync") then
        M.tick_driver = "LoopAsync (UE4SS timer thread only)"
        LoopAsync(ms, function() timed_tick(); return false end)
    else
        M.tick_driver = "none"
        Log.warn("no UE4SS timer available: the director cannot tick")
    end
    Log.info("director loop: " .. M.tick_driver .. ", every " .. ms .. " ms")
    boot("tick driver: " .. M.tick_driver .. ", every " .. ms .. " ms")
end

local function start()
    boot("startup beginning")
    Log.info("TESLES NPC OVERHAUL " .. tostring(CFG.Version) .. " starting")
    Log.info(string.format("nav grid %dx%d, road net %d nodes / %d edges, %d POIs",
        Grid.size, Grid.size, Road.node_count, Road.edge_count, POI.count))
    boot(string.format("world data ready: grid %d, roads %d/%d, pois %d",
        Grid.size, Road.node_count, Road.edge_count, POI.count))

    Bridge.on_api_error = function(where, err)
        -- One line per call site, the first time it fails. Without this an
        -- engine API that changed shows up only as "tick failed".
        Log.error("engine call failed: " .. where .. " -> " .. err)
        boot("ENGINE CALL FAILED: " .. where .. " -> " .. err)
    end
    Bridge.write_crumbs = function(lines)
        local f = io.open(OUTPUT_DIR .. SEP .. "last_engine_calls.txt", "w")
        if not f then return end
        f:write(table.concat(lines, "\n"), "\n")
        f:close()
    end
    Bridge.init(CFG)
    boot("bridge init: " .. (Bridge.available() and "engine available"
        or "engine NOT available yet"))
    Bridge.health.worldRouting = { status = "OK",
        detail = string.format("dry-land grid %dx%d / %d POIs", Grid.size, Grid.size, POI.count) }

    M.world = boot_world()
    boot(string.format("world ready: %d groups / %d NPCs",
        #M.world.groups, Population.alive_npc_count(M.world)))
    Bridge.health.worldPopulation = { status = "OK",
        detail = string.format("%d persistent NPCs / %d groups",
            Population.alive_npc_count(M.world), #M.world.groups) }

    M.director = Director.new({
        world = M.world,
        bridge = Bridge,
        config = CFG,
        seed = M.world.seed,
    })

    local wrote = Telemetry.write(M.world, Bridge, M.director,
        { version = CFG.Version, uptime = 0 })
    boot("first live_state.json write: " .. tostring(wrote))
    if not wrote then
        boot("live_state.json COULD NOT BE WRITTEN to " .. OUTPUT_DIR)
    end

    start_ticking()
    boot("director loop registered at " .. tostring(CFG.TickMs) .. " ms")
    boot("startup complete")
end

if CFG.Enabled == false then
    Log.info("TESLES NPC OVERHAUL is disabled in config.lua")
    boot("disabled in config.lua - stopping here")
    return M
end

-- Give the server time to finish loading before the first scan.
local function guarded_start()
    local ok, err = pcall(start)
    if not ok then
        Log.error("startup failed: " .. tostring(err))
        boot("STARTUP FAILED: " .. tostring(err))
    end
end

-- Startup touches the engine (class catalog, world lookup), so it belongs on
-- the game thread too, and it must not share the Lua state with anything else.
local delay = (CFG.StartupDelaySec or 25) * 1000
if has("ExecuteInGameThreadWithDelay") then
    boot("startup deferred by " .. delay .. " ms, on the game thread")
    ExecuteInGameThreadWithDelay(delay, guarded_start)
elseif has("ExecuteWithDelay") then
    boot("startup deferred by " .. delay .. " ms (no game-thread timer in this UE4SS)")
    ExecuteWithDelay(delay, guarded_start)
else
    boot("no UE4SS timer available - starting immediately")
    guarded_start()
end

return M
