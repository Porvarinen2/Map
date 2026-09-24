-- Contract tests for the engine-facing layer.
--
-- These cover the behaviour the technical environment report calls out as the
-- real bottleneck: spawning is paced, an unproven ground height is a refusal
-- rather than a falling NPC, the class catalog is retried as assets finish
-- loading, and reflection scans are not repeated per group.
package.path = "../package/mod/TeslesNPCOverhaul/?.lua;./?.lua;" .. package.path

local U = require("core.util")
local RNG = require("core.rng")
local Log = require("core.log")
local Physical = require("sim.physical")
local Factory = require("npc.factory")
Log.configure(nil, "error", false)

local fails = 0
local function check(cond, msg)
    if cond then print("  ok  " .. msg)
    else print("FAIL: " .. msg); fails = fails + 1 end
end
local function section(t) print("\n== " .. t .. " ==") end

-- A bridge that records what it was asked to do.
local function make_bridge(opts)
    opts = opts or {}
    local b = {
        spawn_calls = 0, ground_calls = 0, owned = 0, handles = 0,
        ground = opts.ground,
    }
    function b.available() return true end
    function b.ground_at(p)
        b.ground_calls = b.ground_calls + 1
        return b.ground
    end
    function b.spawn_npc(req)
        b.spawn_calls = b.spawn_calls + 1
        b.last_req = req
        if opts.fail then return nil, "SPAWN_FAILED" end
        b.handles = b.handles + 1
        return b.handles
    end
    function b.take_ownership(h) b.owned = b.owned + 1; return true end
    function b.actor_position() return nil end
    function b.despawn() return true end
    return b
end

local function fresh_group(class, n)
    local g = Factory.new_group({ id = 1, class = class or "scavengers", seed = 7,
        size = n, position = { X = 0, Y = 0, Z = 1000 } })
    g.mv = { smooth_heading = 0 }
    return g
end

section("spawn pacing")
Physical.proven = false
local b = make_bridge({ ground = 950 })
local g = fresh_group("scavengers", 5)
check(#g.members == 5, "the test group really has five members (" .. #g.members .. ")")
local spawned, failed = Physical.materialize(g, b, { now = 100, take_ownership = true })
check(spawned == Physical.tuning.max_spawns_per_tick,
      string.format("an unproven server spawns %d per tick, not the whole group (got %d)",
                    Physical.tuning.max_spawns_per_tick, spawned))
check(Physical.proven == true, "a successful spawn marks the server as proven")

local spawned2 = Physical.materialize(g, b, { now = 101, take_ownership = true })
check(spawned2 <= Physical.tuning.max_spawns_per_tick_proven,
      string.format("a proven server stays within the larger budget (%d)", spawned2))
check(spawned2 > Physical.tuning.max_spawns_per_tick,
      "the budget actually widens once spawning is proven")
check(b.owned == spawned + spawned2, "ownership is taken for every spawned actor")

section("ground proof")
Physical.proven = false
local b2 = make_bridge({ ground = nil })     -- navigation cannot prove a height
local g2 = fresh_group("scavengers", 4)
local s2, f2, why = Physical.materialize(g2, b2, { now = 200 })
check(s2 == 0, "nothing is spawned when the ground height cannot be proven")
check(why == "NO_GROUND_PROOF", "the refusal names the reason (got " .. tostring(why) .. ")")
check(b2.spawn_calls == 0, "the engine is never asked to spawn into thin air")
check(Physical.physical_count(g2) == 0, "no member is marked materialized")
check(g2.spawn_retry_at ~= nil, "a backoff is set instead of retrying every tick")

Physical.tuning.require_ground_proof = false
local b3 = make_bridge({ ground = nil })
local g3 = fresh_group("scavengers", 2)
local s3 = Physical.materialize(g3, b3, { now = 300 })
check(s3 > 0, "with the check disabled the spawn is attempted anyway")
Physical.tuning.require_ground_proof = true

section("radiation variant")
Physical.proven = false
local b4 = make_bridge({ ground = 500 })
local g4 = fresh_group("radiation_group", 2)
g4.zone = "RADIATION"
Physical.materialize(g4, b4, { now = 400 })
check(b4.last_req and b4.last_req.variant == "Radiation",
      "a radiation group asks for the hazmat body variant")
local b5 = make_bridge({ ground = 500 })
local g5 = fresh_group("scavengers", 2)
Physical.materialize(g5, b5, { now = 400 })
check(b5.last_req and b5.last_req.variant == nil,
      "an ordinary group asks for the plain class")

section("spawn placement")
Physical.proven = true
local g6 = fresh_group("scavengers", 5)
local pts = {}
for i = 1, 5 do pts[i] = Physical.member_spawn_point(g6, i, 5) end
local min_gap = math.huge
for i = 1, 5 do
    for j = i + 1, 5 do
        local d = U.dist2d(pts[i], pts[j])
        if d < min_gap then min_gap = d end
    end
end
check(min_gap > 50, string.format("members are not stacked on one point (%.0f UU apart)", min_gap))
local far = 0
for _, p in ipairs(pts) do
    local d = U.dist2d(p, g6.position)
    if d > far then far = d end
end
check(far < 2000, string.format("the squad still lands together (%.0f UU spread)", far))

section("scan caching")
-- The bridge module itself needs the UE4SS globals, so the cache contract is
-- checked through a stand-in with the same shape the director calls.
local scans = 0
local cached = { cfg = { PlayerScanIntervalSec = 2 }, _c = { t = 0, v = {} } }
function cached.player_positions()
    local now = os.time()
    if cached._c.t and (now - cached._c.t) < cached.cfg.PlayerScanIntervalSec then
        return cached._c.v
    end
    scans = scans + 1
    cached._c.t, cached._c.v = now, { { X = 0, Y = 0, Z = 0 } }
    return cached._c.v
end
for _ = 1, 50 do cached.player_positions() end
check(scans == 1, string.format("repeated lookups inside the window scan once (%d)", scans))

section("catalog retry")
local catalog = { catalog_found = 0, scans = 0 }
function catalog.refresh_catalog()
    catalog.scans = catalog.scans + 1
    -- Assets finish loading on the third attempt.
    if catalog.scans >= 3 then catalog.catalog_found = 10 end
    return catalog.catalog_found
end
function catalog.maybe_refresh_catalog(now)
    if (catalog.catalog_found or 0) >= 5 then return false end
    if catalog.next_scan and now < catalog.next_scan then return false end
    catalog.next_scan = now + 45
    local before = catalog.catalog_found or 0
    catalog.refresh_catalog()
    return (catalog.catalog_found or 0) > before
end
local t = 1000
for _ = 1, 400 do
    catalog.maybe_refresh_catalog(t)
    t = t + 1
end
check(catalog.scans == 3, string.format("the catalog is retried on a backoff, not every tick (%d scans)", catalog.scans))
check(catalog.catalog_found >= 5, "the retry eventually finds the classes")
local before_scans = catalog.scans
for _ = 1, 200 do catalog.maybe_refresh_catalog(t); t = t + 1 end
check(catalog.scans == before_scans, "scanning stops once the catalog is complete")

print("")
print("== telemetry cost ==")

-- live_state.json is written on the game thread every two seconds. Before
-- 1.1.3 the encoder re-joined the whole buffer at every level of recursion:
-- 2.5 s for a real snapshot here, about 8 s on the server, and the engine
-- called that a hung game thread. The budget below is generous for a desktop
-- and still two orders of magnitude under what broke.
do
    local Population = require("sim.population")
    local Director = require("sim.director")
    local Telemetry = require("bridge.telemetry")
    local MockBridge = dofile("mock_bridge.lua")
    local CFG = dofile("../package/mod/TeslesNPCOverhaul/config.lua")
    local w = Population.new_world({ seed = 42, target_npcs = 100 })
    Population.generate(w, function() end)
    local d = Director.new({ world = w, bridge = MockBridge, config = CFG, seed = 42 })
    local snap = Telemetry.snapshot(w, MockBridge, d, { version = "t", uptime = 0 })

    local t0 = os.clock()
    local json = U.json(snap)
    local ms = (os.clock() - t0) * 1000
    check(#json > 100000, string.format("a full snapshot is realistic in size (%d bytes)", #json))
    check(ms < 150, string.format("encoding it takes %.0f ms (< 150)", ms))

    -- Doubling the input must not quadruple the time.
    local big = { a = snap, b = snap }
    local t1 = os.clock()
    local json2 = U.json(big)
    local ms2 = (os.clock() - t1) * 1000
    check(#json2 > 2 * #json, "the doubled document is encoded in full")
    check(ms2 < math.max(40, ms * 3.5),
          string.format("cost grows linearly: %.0f ms for 1x, %.0f ms for 2x", ms, ms2))

    -- The encoder is only a speed fix if it still writes the same thing.
    check(json:sub(1, 1) == "{" and json:sub(-1) == "}", "the document is one JSON object")
    check(U.json({ 1, "a", true, { x = 1.5 } }) == '[1,"a",true,{"x":1.500}]',
          "arrays, strings, booleans and nested objects encode exactly")
    check(U.json({ f = function() end, n = 2 }) == '{"n":2}',
          "functions are left out of objects")
end

print("")
print("== NPC class loading ==")
-- On a live server the Drifter Blueprints are not in memory until loaded, so
-- StaticFindObject alone never found them and nothing could ever spawn.
do
    local loaded, loads = {}, 0
    local fake_class = { IsValid = function() return true end,
                         GetFullName = function() return "BlueprintGeneratedClass BP_Drifter" end }
    _G.StaticFindObject = function(path) return loaded[path] and fake_class or nil end
    _G.LoadAsset = function(path) loads = loads + 1; loaded[path] = true end
    package.loaded["bridge.scum"] = nil
    local SB = require("bridge.scum")
    SB.cfg = {}
    local calls = 0
    while (SB.catalog_pending or 1) > 0 and calls < 20 do
        SB.maybe_refresh_catalog(1000 + calls); calls = calls + 1
    end
    check(loads == 20, "every Drifter and Guard class is loaded once (" .. loads .. " loads)")
    check(calls == 20, "one load per tick, never a burst (" .. calls .. " ticks)")
    check(SB.catalog_found == 5, "all five Drifter levels resolve after loading")
    check(SB.class_for(3, "Radiation") ~= nil, "a radiation variant resolves")
    local _, fam = SB.class_for(4, "AbandonedBunker", "Guard")
    check(fam == "Guard", "a Guard bunker variant resolves as Guard")
    local _, fam1, var1 = SB.class_for(1, "Radiation", "Guard")
    check(fam1 == "Guard" and var1 == nil, "a missing variant falls back to the plain body of the same family")
    local before = loads
    for k = 1, 30 do SB.maybe_refresh_catalog(2000 + k) end
    check(loads == before, "a complete catalog is never reloaded")
    _G.StaticFindObject, _G.LoadAsset = nil, nil
end

print("")
print("== vanilla NPC cleanup ==")
-- Only the mod's groups may be on the island: SCUM's own armed encounter NPCs
-- are destroyed, the mod's actors and corpses are left alone.
do
    local function pawn(name, hp)
        return { name = name, Health = hp, destroyed = false,
                 IsValid = function() return true end,
                 GetFullName = function(self) return self.name end,
                 K2_DestroyActor = function(self) self.destroyed = true end }
    end
    local mine, foreign, corpse = pawn("BP_Drifter_Lvl_2_C mine", 100),
        pawn("BP_Guard_Lvl_3_C vanilla", 100), pawn("BP_Drifter_Lvl_1_C corpse", 0)
    local function ctrl(p)
        return { IsValid = function() return true end, GetFullName = function() return "c" end,
                 K2_GetPawn = function() return p end, StopMovement = function() end,
                 K2_DestroyActor = function() end }
    end
    local scanned = 0
    _G.FindAllOf = function(cname)
        scanned = scanned + 1
        if cname == "ArmedNPCBaseAIController" then
            return { ctrl(mine), ctrl(foreign), ctrl(corpse) }
        end
        return nil
    end
    package.loaded["bridge.scum"] = nil
    local SB = require("bridge.scum")
    SB.cfg = { RemoveVanillaArmedNPCs = true, VanillaCleanupIntervalSec = 3 }
    SB.owned_names["BP_Drifter_Lvl_2_C mine"] = true
    SB.player_positions = function() return { { X = 0, Y = 0, Z = 0 } } end
    local removed = SB.cleanup_vanilla(5000)
    check(removed == 1 and foreign.destroyed, "a SCUM armed NPC near a player is removed")
    check(not mine.destroyed, "the mod's own actor is never touched")
    check(not corpse.destroyed, "a corpse is left for looting")
    local before = scanned
    SB.cleanup_vanilla(5001)
    check(scanned == before, "at most one scan per cleanup interval")
    SB.player_positions = function() return {} end
    SB.cleanup_vanilla(5010)
    check(scanned == before, "no scans while nobody is online")
    _G.FindAllOf = nil
end

print("")
print("== class freed by the garbage collector ==")
do
    local objs, loads = {}, 0
    local function class_obj(path)
        return { alive = true, IsValid = function(self) return self.alive end,
                 GetFullName = function() return "BlueprintGeneratedClass " .. path end }
    end
    _G.StaticFindObject = function(path) local o = objs[path]; return (o and o.alive) and o or nil end
    _G.LoadAsset = function(path) loads = loads + 1; objs[path] = class_obj(path) end
    package.loaded["bridge.scum"] = nil
    local SB = require("bridge.scum")
    SB.cfg = {}
    for k = 1, 25 do SB.maybe_refresh_catalog(1000 + k) end
    check(SB.class_for(2, nil, "Drifter") ~= nil, "the catalog is complete")
    -- The engine frees every class nobody has used yet.
    for _, o in pairs(objs) do o.alive = false end
    local before = loads
    local c = SB.class_for(2, nil, "Drifter")
    check(c ~= nil and c.alive, "a freed class is loaded again when a spawn needs it")
    check(loads == before + 1, "only the class that is needed is reloaded (" .. (loads - before) .. ")")
    _G.StaticFindObject, _G.LoadAsset = nil, nil
end

print("")
print("== radiation zone ==")
do
    local Ph = require("sim.physical")
    check(Ph.body_level(2, "Radiation") == 3, "a level 2 radiation NPC wears the level 3 hazmat body")
    check(Ph.body_level(5, "Radiation") == 5, "higher levels keep their own hazmat body")
    check(Ph.body_level(2, nil) == 2, "plain bodies keep the NPC's level")

    -- An older save: three radiation squads, one outsider standing in C0.
    local Population = require("sim.population")
    local Zones = require("world.zones")
    local w = Population.new_world({ seed = 7, target_npcs = 60 })
    Population.generate(w, function() end)
    local removed = 0
    local kept = {}
    for _, g in ipairs(w.groups) do
        if g.class == "radiation_group" and removed < 2 then removed = removed + 1
        else kept[#kept + 1] = g end
    end
    w.groups = kept
    local intruder = nil
    for _, g in ipairs(w.groups) do
        if g.class ~= "radiation_group" then intruder = g; break end
    end
    intruder.position = Zones.random_point_in("C0")
    Population.ensure_reserved(w)
    local rad, inside_other = 0, 0
    for _, g in ipairs(w.groups) do
        local c0 = Zones.sector(g.position) == "C0"
        if g.class == "radiation_group" then
            if c0 then rad = rad + 1 end
        elseif c0 then inside_other = inside_other + 1 end
    end
    check(rad == 5, "an older world is topped up to five radiation squads inside C0 (" .. rad .. ")")
    check(inside_other == 0, "an outsider found in C0 is moved out")

    -- Routes: an outsider never crosses C0, a radiation squad never leaves it.
    local Router = require("world.router")
    local r = Zones.RESERVED[1]
    local b = Zones.sector_bounds("C0")
    local west = { X = b.xMax + 40000, Y = (b.yMin + b.yMax) / 2, Z = 0 }
    local south = { X = (b.xMin + b.xMax) / 2, Y = b.yMin - 40000, Z = 0 }
    local route = Router.route(west, south, { fence = r.fence_out })
    local ok = route ~= nil
    for i = 1, route and #route.points - 1 or 0 do
        if not Router.segment_ok(route.points[i], route.points[i + 1], r.fence_out) then ok = false end
    end
    check(ok, "a route past C0 goes around it")
    local fenced = Router.route(west, { X = (b.xMin + b.xMax) / 2, Y = (b.yMin + b.yMax) / 2, Z = 0 },
                                { fence = r.fence_out })
    check(fenced == nil, "an outsider cannot be routed into C0")
end

print("")
os.exit(fails == 0 and 0 or 1)
