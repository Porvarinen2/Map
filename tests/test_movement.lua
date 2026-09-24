-- Proves the path follower actually removes the saw-tooth.
--
-- Two directors drive the same mock actor over the same routes:
--   LEGACY  recomputes a scattered destination every tick (the old behaviour)
--   FIXED   sim/movement.lua: immutable route, monotonic index, gated commands
--
-- Reported metrics:
--   ratio   travelled distance / straight-line distance (1.0 = perfect)
--   jitter  mean heading change per sample, degrees (saw-tooth = high)
--   cmds    move orders issued (fewer is better; each one interrupts pathing)
package.path = "../package/mod/TeslesNPCOverhaul/?.lua;./?.lua;" .. package.path

local U = require("core.util")
local RNG = require("core.rng")
local Router = require("world.router")
local Move = require("sim.movement")
local Actor = require("mock_actor")
local POI = require("world.poi_data")

local DT = 0.25          -- actor physics step
local TICK = 1.0         -- director tick
local MAX_SEC = 9000      -- the longest island crossings on the real map

local function run_fixed(from, to, seed)
    local rng = RNG.new(seed)
    local actor = Actor.new(from, { rng = rng, reject_rate = 0.06 })
    local route = Router.route(from, to)
    if not route then return nil end
    local mv = Move.new_state()
    Move.set_route(mv, route, to)

    local now, next_tick, arrived = 0, 0, false
    local replans = 0
    while now < MAX_SEC do
        if now >= next_tick then
            next_tick = now + TICK
            if Move.update_index(mv, actor.pos, Move.tuning.arrive_physical) then
                arrived = true
                break
            end
            local status = Move.check_progress(mv, actor.pos, now)
            if status ~= "OK" then
                local action = Move.handle_stall(mv, actor.pos)
                if action == "REPLAN" then
                    local r2 = Router.route(actor.pos, to)
                    if r2 then Move.set_route(mv, r2, to); replans = replans + 1
                    else break end
                elseif action == "ABANDON" then
                    break
                end
            end
            Move.update_heading(mv, actor.pos, now)
            local target, reason = Move.next_command(mv, actor.pos, now)
            if target then
                local ok = actor:command(target)
                Move.mark_issued(mv, target, actor.pos, now, ok)
            end
        end
        actor:step(DT)
        now = now + DT
    end
    return {
        arrived = arrived, trail = actor.trail, commands = mv.commands,
        seconds = now, replans = replans, kind = route.kind, route = route,
        route_len = route.length, rejects = actor.rejects,
    }
end

-- The legacy pattern: every tick, aim at the goal offset by a fresh scatter
-- point, and re-issue unconditionally.
local function run_legacy(from, to, seed)
    local rng = RNG.new(seed)
    local actor = Actor.new(from, { rng = rng, reject_rate = 0.06 })
    local now, next_tick, arrived = 0, 0, false
    local cmds = 0
    local reissue = 8
    local last_issue = -100
    while now < MAX_SEC do
        if now >= next_tick then
            next_tick = now + TICK
            if U.dist2d(actor.pos, to) <= 1800 then arrived = true; break end
            if now - last_issue >= reissue then
                last_issue = now
                -- scatter destination, as the old activity code did
                local ang = rng:float() * math.pi * 2
                local rad = rng:range(2000, 16000)
                local dir = U.direction(actor.pos, to)
                local aim = {
                    X = to.X + math.cos(ang) * rad,
                    Y = to.Y + math.sin(ang) * rad,
                    Z = to.Z,
                }
                -- and an intermediate scatter waypoint when still far out
                if U.dist2d(actor.pos, to) > 60000 and dir then
                    local step = rng:range(30000, 70000)
                    local off = (rng:float() - 0.5) * 2 * U.rad(38)
                    local h = math.atan(dir.Y, dir.X) + off
                    aim = {
                        X = actor.pos.X + math.cos(h) * step,
                        Y = actor.pos.Y + math.sin(h) * step,
                        Z = to.Z,
                    }
                end
                if actor:command(aim) then cmds = cmds + 1 end
            end
        end
        actor:step(DT)
        now = now + DT
    end
    return { arrived = arrived, trail = actor.trail, commands = cmds, seconds = now }
end

local function summarise(name, results)
    local n, arrived, ratio, jit, rev, cmds, secs, track = 0, 0, 0, 0, 0, 0, 0, 0
    for _, r in ipairs(results) do
        n = n + 1
        if r.arrived then arrived = arrived + 1 end
        ratio = ratio + Move.trail_ratio(r.trail)
        jit = jit + Move.trail_jitter_spatial(r.trail, 2500)
        rev = rev + Move.trail_reversals(r.trail, 2500, 55)
        cmds = cmds + r.commands
        secs = secs + r.seconds
        if r.route then track = track + Move.trail_cross_track(r.trail, r.route) end
    end
    print(string.format(
        "%-7s runs=%2d arrived=%2d  ratio=%.2f  turn/250m=%5.1f deg  reversals=%4.1f%%  cmds=%5.1f  avg=%4.0f s",
        name, n, arrived, ratio / n, jit / n, 100 * rev / n, cmds / n, secs / n))
    return { arrived = arrived, n = n, ratio = ratio / n, jitter = jit / n,
             reversals = rev / n, cmds = cmds / n, track = track / n }
end

local pts = POI.points
local rng = RNG.new(4242)
local pairs_list = {}
while #pairs_list < 30 do
    local a = pts[rng:int(1, #pts)]
    local b = pts[rng:int(1, #pts)]
    local from = { X = a.x, Y = a.y, Z = 0 }
    local to = { X = b.x, Y = b.y, Z = 0 }
    local d = U.dist2d(from, to)
    if d > 150000 and d < 900000 and Router.route(from, to) then
        pairs_list[#pairs_list + 1] = { from = from, to = to }
    end
end

local fixed, legacy = {}, {}
for i, p in ipairs(pairs_list) do
    local f = run_fixed(p.from, p.to, 1000 + i)
    if f then fixed[#fixed + 1] = f end
    legacy[#legacy + 1] = run_legacy(p.from, p.to, 1000 + i)
end

print("== long-distance travel, " .. #pairs_list .. " POI pairs ==")
local L = summarise("LEGACY", legacy)
local F = summarise("FIXED", fixed)

local fails = 0
local function check(cond, msg)
    if not cond then print("FAIL: " .. msg); fails = fails + 1
    else print("  ok  " .. msg) end
end
print("")
-- Travelled distance against the route the group was actually given: this is
-- the honest "did it walk the path or wander" number.
local overshoot, n = 0, 0
for _, r in ipairs(fixed) do
    local len = 0
    for i = 1, #r.trail - 1 do len = len + U.dist2d(r.trail[i], r.trail[i + 1]) end
    overshoot = overshoot + len / math.max(1, r.route_len)
    n = n + 1
end
overshoot = overshoot / n
print(string.format("\nfixed: travelled/planned = %.3f   mean cross-track = %.0f UU (%.1f m)",
    overshoot, F.track, F.track / 100))

check(F.arrived == F.n, "every fixed-path run reached its destination")
check(overshoot < 1.10, string.format("travelled/planned %.3f < 1.10", overshoot))
check(F.track < 2500, string.format("cross-track %.0f UU < 2500 (25 m)", F.track))
check(F.jitter < 8.0, string.format("turn per 250 m %.1f deg < 8", F.jitter))
check(F.reversals < 0.02, string.format("reversals %.1f%% < 2%%", 100 * F.reversals))
check(F.jitter < L.jitter * 0.45, string.format("turn rate %.1f vs legacy %.1f", F.jitter, L.jitter))
check(F.reversals < L.reversals * 0.3 or L.reversals < 0.02,
      string.format("reversals %.1f%% vs legacy %.1f%%", 100 * F.reversals, 100 * L.reversals))
check(F.cmds < 260, string.format("move commands %.0f stay bounded", F.cmds))
os.exit(fails == 0 and 0 or 1)
