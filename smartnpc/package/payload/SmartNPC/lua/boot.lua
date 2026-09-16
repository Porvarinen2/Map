-- SmartNPC :: boot.lua
-- Module loading, configuration merge and the scheduler.
--
-- Threading contract:
--   * LoopAsync runs on a worker thread.  It may not touch UObjects.
--   * Every UObject access happens inside ExecuteInGameThread.
--   * At most one game-thread callback is ever in flight, so a slow tick can
--     never pile up behind itself and stall the server.

local ROOT = SMARTNPC_ROOT
assert(type(ROOT) == "string" and #ROOT > 0, "SmartNPC: SMARTNPC_ROOT not set")

-- Windows in production, POSIX under the offline test harness.
local SEP = "\\"
do
    local ok, cfgstr = pcall(function() return package.config:sub(1, 1) end)
    if ok and cfgstr == "/" then SEP = "/" end
end

SMARTNPC = {
    VERSION    = "1.0.2",
    ROOT       = ROOT,
    SEP        = SEP,
    DIR_LUA    = ROOT .. SEP .. "lua",
    DIR_DATA   = ROOT .. SEP .. "data",
    DIR_STATE  = ROOT .. SEP .. "state",
    DIR_OUTPUT = ROOT .. SEP .. "output",
    DIR_LOGS   = ROOT .. SEP .. "logs",
    tick_count = 0,
}
local S = SMARTNPC

math.randomseed(os.time() % 2147483647)
for _ = 1, 5 do math.random() end

--------------------------------------------------------------------------
-- module loader
--------------------------------------------------------------------------

local function load_module(name)
    local path = S.DIR_LUA .. SEP .. name .. ".lua"
    local ok, mod = pcall(dofile, path)
    if not ok then
        error("SmartNPC: failed to load " .. name .. ".lua -> " .. tostring(mod), 0)
    end
    return mod
end

--------------------------------------------------------------------------
-- configuration
--------------------------------------------------------------------------

local defaults = load_module("defaults")
local cfg = {}
for k, v in pairs(defaults) do cfg[k] = v end

do
    local ok, user = pcall(dofile, ROOT .. SEP .. "smartnpc.config.lua")
    if ok and type(user) == "table" then
        for k, v in pairs(user) do
            if type(v) == "table" and type(cfg[k]) == "table" then
                local merged = {}
                for dk, dv in pairs(cfg[k]) do merged[dk] = dv end
                for uk, uv in pairs(v) do merged[uk] = uv end
                cfg[k] = merged
            else
                cfg[k] = v
            end
        end
        cfg.__config_loaded = true
    else
        cfg.__config_error = tostring(user)
    end
end
S.config = cfg

--------------------------------------------------------------------------
-- modules
--------------------------------------------------------------------------

S.util = load_module("util")
local U = S.util

U.log("========================================================")
U.log("SmartNPC " .. S.VERSION .. " starting")
U.log("root: " .. ROOT)
if cfg.__config_error then
    U.log("config: using defaults (" .. cfg.__config_error .. ")")
else
    U.log("config: smartnpc.config.lua loaded")
end

if cfg.Enabled == false then
    U.log("SmartNPC is disabled in the configuration. Nothing will run.")
    return
end

S.world     = load_module("world")
S.traits    = load_module("traits")
S.body      = load_module("body")
S.telemetry = load_module("telemetry")
S.squad     = load_module("squad")
S.director  = load_module("director")

local W = S.world
local B = S.body
local D = S.director
local M = S.telemetry

U.guard("world.load", W.load)

--------------------------------------------------------------------------
-- scheduler
--------------------------------------------------------------------------

local start_wall = os.time()
local started = false
local pending = false

-- Phase accumulators (seconds).
local acc = {
    body = 0, brain = 0, players = 0, discover = 0,
    population = 0, telemetry = 0, cleanup = 0, save = 0,
}
local PHASE = {
    body       = 0.45,   -- per-NPC command gate; cheap, must stay responsive
    brain      = 1.00,   -- squad state machine + virtual integration
    players    = 2.50,
    discover   = 9.00,
    population = 6.00,
    telemetry  = 1.00,   -- the writer applies its own interval on top
    cleanup    = 15.00,
    save       = 60.00,
}

local last_time = nil

-- Round-robin cursor so a large population is spread over several ticks
-- instead of hammering the game thread in one burst.
local body_cursor = nil

local function step_bodies(now, ctx, budget)
    local keys = {}
    for _, sq in pairs(D.squads) do
        if not sq.virtual then
            for _, m in ipairs(sq.members) do
                keys[#keys + 1] = m
            end
        end
    end
    if #keys == 0 then return end
    -- Stable order, so a population larger than the per-tick budget is served
    -- round-robin instead of leaving whoever pairs() forgot standing still.
    table.sort(keys, function(a, b) return (a.key or "") < (b.key or "") end)

    local start = 1
    if body_cursor and body_cursor <= #keys then start = body_cursor end
    local done = 0
    local i = start
    local looped = 0
    while done < #keys and looped < #keys do
        local m = keys[i]
        if m then
            local sq = D.squads[m.squad_id]
            ctx.nearest_player_dist = sq and sq.player_dist or math.huge
            B.step(m, now, ctx)
            done = done + 1
        end
        i = i + 1
        looped = looped + 1
        if i > #keys then i = 1 end
        if done >= budget then break end
    end
    body_cursor = i
end

local function tick()
    local now = U.now()
    local dt = last_time and (now - last_time) or 0.2
    last_time = now
    if dt <= 0 then dt = 0.05 end
    if dt > 5 then dt = 5 end

    S.tick_count = S.tick_count + 1

    if not started then
        if os.time() - start_wall < cfg.StartupDelaySec then return end
        started = true
        U.log("director: startup delay elapsed, entering service")
        U.guard("restore", D.restore_state)
        M.event("BOOT", "SmartNPC", "version " .. S.VERSION)
    end

    for k in pairs(acc) do acc[k] = acc[k] + dt end
    local ctx = {}

    if acc.players >= PHASE.players then
        acc.players = 0
        U.guard("players", D.scan_players)
    end

    if acc.discover >= PHASE.discover then
        acc.discover = 0
        if cfg.AdoptNativeNPCs then U.guard("discover", D.discover) end
    end

    if acc.brain >= PHASE.brain then
        local bdt = acc.brain
        acc.brain = 0
        for _, sq in pairs(D.squads) do
            U.guard("bubble", D.update_bubble, sq)
        end
        for _, sq in pairs(D.squads) do
            ctx.nearest_player_dist = sq.player_dist or math.huge
            U.guard("squad.tick", sq.tick, sq, now, bdt, ctx)
        end
    end

    if acc.body >= PHASE.body then
        acc.body = 0
        U.guard("bodies", step_bodies, now, ctx, 40)
    end

    if acc.population >= PHASE.population then
        acc.population = 0
        U.guard("population", D.maintain_population)
    end

    if acc.cleanup >= PHASE.cleanup then
        acc.cleanup = 0
        U.guard("cleanup", D.cleanup)
    end

    if acc.telemetry >= PHASE.telemetry then
        acc.telemetry = 0
        U.guard("telemetry", M.write)
    end

    if acc.save >= PHASE.save then
        acc.save = 0
        U.guard("save", D.save_state)
    end
end

--------------------------------------------------------------------------
-- start
--------------------------------------------------------------------------

local function schedule()
    if type(LoopAsync) ~= "function" or type(ExecuteInGameThread) ~= "function" then
        U.log("FATAL: UE4SS async API unavailable; SmartNPC cannot run.")
        return
    end
    LoopAsync(cfg.TickMs, function()
        if pending then return false end
        pending = true
        ExecuteInGameThread(function()
            local t0 = os.clock()
            local ok, err = pcall(tick)
            S.last_tick_ms = (os.clock() - t0) * 1000
            if not ok then
                U.log("tick error: " .. tostring(err))
            end
            pending = false
        end)
        return false
    end)
    U.log("scheduler: LoopAsync " .. cfg.TickMs .. " ms, one pending game-thread tick")
end

U.write_atomic(S.DIR_OUTPUT .. SEP .. "world.json", U.json({
    version = S.VERSION, ok = false, time = U.stamp(),
    stats = {}, squads = {}, events = {},
    note = "waiting for the server to finish loading",
}))

schedule()
U.log("SmartNPC ready. First decisions in " .. cfg.StartupDelaySec .. " s.")
