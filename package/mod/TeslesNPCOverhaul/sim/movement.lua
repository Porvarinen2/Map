-- Path following.
--
-- This module exists because of one specific failure: squads that were given a
-- clear destination still walked across the map in a saw-tooth. The causes were
-- all the same shape - something recomputed the *target* every tick, so the
-- actor turned a few degrees, walked, turned back, walked. Four rules fix it:
--
--   1. A route is immutable. It is solved once and only replaced by an
--      explicit replan. Nothing re-derives it per tick.
--   2. The waypoint index only ever moves forward, and advances on a
--      passed-the-plane test, not just a radius, so an actor that overshoots
--      never orbits back.
--   3. A move command is only re-sent when the target actually moved, the
--      command went stale, or the engine reported a failure. A one-degree
--      heading change is never a reason to re-command.
--   4. Progress, not time, decides whether a squad is stuck, and the response
--      escalates - re-issue, skip, replan, abandon - instead of jittering.
--
-- Formation members follow the leader's *smoothed* heading and only receive a
-- new slot when that heading genuinely changed, which stops followers from
-- ping-ponging around a leader that is walking a straight line.
local U = require("core.util")
local Grid = require("world.navgrid")
local Router = require("world.router")

local M = {}

M.tuning = {
    arrive_physical = 2600,        -- UU; waypoint counts as reached
    arrive_virtual = 3600,
    arrive_final = 1500,           -- final destination tolerance
    retarget_eps = 450,            -- don't re-command for less than this
    reissue_sec = 22,              -- keepalive so a dropped order recovers
    min_heading_change = 0.14,     -- ~8 degrees
    heading_gate_dist = 1800,      -- gate only applies while still far away
    stall_sec = 14,
    stall_progress = 260,          -- UU of forward progress that counts
    max_stalls = 4,
    max_replans = 3,
    formation_heading_change = 0.45,  -- ~26 degrees before slots are re-sent
    formation_reissue_sec = 16,
    formation_slot_tolerance = 700,
    heading_smooth = 0.35,
    max_virtual_step_sec = 15,     -- ceiling on one virtual movement step
}

M.ARRIVED, M.MOVING, M.BLOCKED, M.IDLE = "ARRIVED", "MOVING", "BLOCKED", "IDLE"

-- ------------------------------------------------------------ construction --

function M.new_state()
    return {
        route = nil,
        index = 1,
        state = M.IDLE,
        issued_target = nil,
        issued_at = 0,
        issued_heading = nil,
        smooth_heading = nil,
        progress = nil,
        progress_at = 0,
        stalls = 0,
        replans = 0,
        force_reissue = false,
        commands = 0,
        formation_heading = nil,
        formation_at = 0,
        travelled = 0,
        last_pos = nil,
    }
end

-- Attach a freshly solved route. Callers must not mutate it afterwards.
function M.set_route(mv, route, goal)
    mv.route = route
    mv.index = 1
    mv.state = route and M.MOVING or M.IDLE
    mv.goal = U.copy_vec(goal or (route and route.goal))
    mv.issued_target = nil
    mv.issued_at = 0
    mv.issued_heading = nil
    mv.progress = nil
    mv.progress_at = 0
    mv.stalls = 0
    mv.formation_heading = nil
    mv.formation_at = 0
    return mv
end

function M.clear(mv, state)
    mv.route = nil
    mv.index = 1
    mv.goal = nil
    mv.issued_target = nil
    mv.issued_heading = nil
    mv.state = state or M.IDLE
    mv.progress = nil
    mv.stalls = 0
end

function M.has_route(mv)
    return mv and mv.route and mv.route.points and #mv.route.points > 0
end

function M.current_waypoint(mv)
    if not M.has_route(mv) then return nil end
    local pts = mv.route.points
    return pts[math.min(mv.index, #pts)]
end

-- ------------------------------------------------------- waypoint stepping --

-- Direction of travel out of waypoint `i`, used for the passed-plane test.
local function leg_direction(pts, i)
    if i < #pts then
        local d = U.direction(pts[i], pts[i + 1])
        if d then return d end
    end
    if i > 1 then
        local d = U.direction(pts[i - 1], pts[i])
        if d then return d end
    end
    return nil
end

-- Advances the (monotonic) waypoint index. Returns true when the final
-- destination has been reached.
function M.update_index(mv, pos, arrive)
    if not M.has_route(mv) then return false end
    local pts = mv.route.points
    arrive = arrive or M.tuning.arrive_physical

    local guard = 0
    while mv.index < #pts and guard < 64 do
        guard = guard + 1
        local wp = pts[mv.index]
        local d = U.dist2d(pos, wp)
        if d <= arrive then
            mv.index = mv.index + 1
        else
            -- Already beyond this waypoint's plane: never turn back for it.
            local dir = leg_direction(pts, mv.index)
            if dir and d <= arrive * 3 and U.past_plane(pos, wp, dir) then
                mv.index = mv.index + 1
            else
                break
            end
        end
    end

    if mv.index >= #pts then
        local final = pts[#pts]
        if U.dist2d(pos, final) <= math.max(arrive, M.tuning.arrive_final) then
            mv.state = M.ARRIVED
            return true
        end
    end
    return false
end

-- ------------------------------------------------------------ progress ------

local function remaining(mv, pos)
    if not M.has_route(mv) then return 0 end
    return Router.remaining(mv.route, mv.index, pos)
end

-- Returns "OK" | "STALL" | "GIVE_UP".
function M.check_progress(mv, pos, now)
    local rem = remaining(mv, pos)
    if mv.progress == nil then
        mv.progress, mv.progress_at = rem, now
        return "OK", rem
    end
    if rem < mv.progress - M.tuning.stall_progress then
        mv.progress, mv.progress_at = rem, now
        mv.stalls = 0
        return "OK", rem
    end
    if now - mv.progress_at >= M.tuning.stall_sec then
        mv.stalls = mv.stalls + 1
        mv.progress, mv.progress_at = rem, now
        if mv.stalls >= M.tuning.max_stalls then return "GIVE_UP", rem end
        return "STALL", rem
    end
    return "OK", rem
end

-- ------------------------------------------------------------- commanding ---

-- Decides whether a new move order should be sent this tick.
-- Returns target, reason  (or nil when the existing order still stands).
function M.next_command(mv, pos, now, opts)
    opts = opts or {}
    if not M.has_route(mv) then return nil, "NO_ROUTE" end
    local target = M.current_waypoint(mv)
    if not target then return nil, "NO_WAYPOINT" end

    local t = M.tuning
    if mv.issued_target == nil then
        return target, "FIRST"
    end
    if mv.force_reissue then
        return target, "RETRY"
    end
    if now - mv.issued_at >= (opts.reissue_sec or t.reissue_sec) then
        return target, "KEEPALIVE"
    end

    local moved = U.dist2d(mv.issued_target, target)
    if moved <= t.retarget_eps then
        return nil, "SAME_TARGET"
    end

    -- The target moved, but is the actor's heading materially different? A
    -- few degrees is not worth interrupting an in-flight path request.
    local new_heading = U.heading(pos, target)
    if new_heading and mv.issued_heading then
        local delta = math.abs(U.angle_delta(mv.issued_heading, new_heading))
        local far = U.dist2d(pos, target) > t.heading_gate_dist
        if far and delta < t.min_heading_change then
            return nil, "HEADING_GATE"
        end
    end
    return target, "WAYPOINT"
end

function M.mark_issued(mv, target, pos, now, accepted)
    mv.issued_target = U.copy_vec(target)
    mv.issued_at = now
    mv.issued_heading = U.heading(pos, target)
    mv.force_reissue = not accepted
    if accepted then mv.commands = mv.commands + 1 end
    if mv.smooth_heading == nil then
        mv.smooth_heading = mv.issued_heading
    end
end

-- Escalating response to no forward progress.
-- Returns "REISSUE" | "SKIP" | "REPLAN" | "ABANDON".
function M.handle_stall(mv, pos)
    if mv.stalls <= 1 then
        mv.force_reissue = true
        return "REISSUE"
    end
    if mv.stalls == 2 and M.has_route(mv) and mv.index < #mv.route.points then
        mv.index = mv.index + 1
        mv.force_reissue = true
        return "SKIP"
    end
    if mv.replans < M.tuning.max_replans then
        mv.replans = mv.replans + 1
        return "REPLAN"
    end
    return "ABANDON"
end

-- ------------------------------------------------------------- heading ------

-- Exponentially smoothed travel heading. Formation slots hang off this so a
-- momentary wobble in the leader does not swing the whole squad.
function M.update_heading(mv, pos, now)
    if mv.last_pos then
        local step = U.dist2d(mv.last_pos, pos)
        if step > 1 then
            mv.travelled = (mv.travelled or 0) + step
            local h = U.heading(mv.last_pos, pos)
            if h then
                if mv.smooth_heading == nil then
                    mv.smooth_heading = h
                else
                    local d = U.angle_delta(mv.smooth_heading, h)
                    mv.smooth_heading = mv.smooth_heading + d * M.tuning.heading_smooth
                end
            end
        end
    end
    mv.last_pos = U.copy_vec(pos)
    if mv.smooth_heading == nil then
        local wp = M.current_waypoint(mv)
        if wp then mv.smooth_heading = U.heading(pos, wp) end
    end
    return mv.smooth_heading
end

-- ----------------------------------------------------------- formations -----

-- Deterministic slot layout: staggered pairs trailing the leader. Index 1 is
-- the leader itself and always maps to the leader's own position.
function M.formation_offset(index, spread, depth)
    if index <= 1 then return 0, 0 end
    local i = index - 1
    local side = (i % 2 == 1) and 1 or -1
    local row = math.floor((i - 1) / 2) + 1
    if row > 3 then row = 3 end
    return side * spread * (0.55 + 0.45 * math.min(row, 2)), -depth * row
end

-- World-space slot for a follower, rotated onto the leader's heading.
function M.formation_slot(leader_pos, heading, index, spread, depth)
    if index <= 1 then return U.copy_vec(leader_pos) end
    local lat, back = M.formation_offset(index, spread or 900, depth or 1000)
    local h = heading or 0
    local fx, fy = math.cos(h), math.sin(h)
    local sx, sy = -fy, fx
    local p = {
        X = leader_pos.X + sx * lat + fx * back,
        Y = leader_pos.Y + sy * lat + fy * back,
        Z = leader_pos.Z,
    }
    -- Never place a slot in water; pull it back onto the leader if needed.
    if not Grid.is_passable(p) then
        local snapped = Grid.snap_to_land(p)
        if snapped then
            snapped.Z = leader_pos.Z
            return snapped
        end
        return U.copy_vec(leader_pos)
    end
    return p
end

-- True when followers should be re-commanded. Gated on heading change and a
-- long keepalive so a straight march sends almost no follower orders.
function M.formation_due(mv, heading, now)
    local t = M.tuning
    if mv.formation_heading == nil then return true end
    if now - (mv.formation_at or 0) >= t.formation_reissue_sec then return true end
    if heading and math.abs(U.angle_delta(mv.formation_heading, heading)) >= t.formation_heading_change then
        return true
    end
    return false
end

function M.mark_formation(mv, heading, now)
    mv.formation_heading = heading
    mv.formation_at = now
end

-- ---------------------------------------------------------- virtual step ----

-- Moves a virtual (non-physical) group along its route by `dt` seconds at
-- `speed` UU/s. Exact arc-length stepping: the marker traces the route
-- precisely, so the live map trail is the route, not a random walk.
function M.virtual_step(mv, pos, dt, speed)
    if not M.has_route(mv) then return pos, false end
    local pts = mv.route.points
    -- Hard cap on how far one step may move a marker. Without it a long delta
    -- after a server stall would slide a group across the map in one frame.
    local budget = math.max(0, (speed or 400) * math.max(0, dt))
    local cap = (speed or 400) * (M.tuning.max_virtual_step_sec or 15)
    if budget > cap then budget = cap end
    local cur = U.copy_vec(pos)
    local guard = 0

    while budget > 0 and guard < 128 do
        guard = guard + 1
        local wp = pts[math.min(mv.index, #pts)]
        local dir, dist = U.direction(cur, wp)
        if not dir or dist < 1 then
            if mv.index >= #pts then
                mv.state = M.ARRIVED
                return wp and U.copy_vec(wp) or cur, true
            end
            mv.index = mv.index + 1
        elseif dist <= budget then
            budget = budget - dist
            cur = U.copy_vec(wp)
            if mv.index >= #pts then
                mv.state = M.ARRIVED
                return cur, true
            end
            mv.index = mv.index + 1
        else
            cur.X = cur.X + dir.X * budget
            cur.Y = cur.Y + dir.Y * budget
            mv.travelled = (mv.travelled or 0) + budget
            budget = 0
        end
    end

    local h = U.heading(pos, cur)
    if h then
        if mv.smooth_heading == nil then
            mv.smooth_heading = h
        else
            mv.smooth_heading = mv.smooth_heading
                + U.angle_delta(mv.smooth_heading, h) * M.tuning.heading_smooth
        end
    end
    mv.last_pos = U.copy_vec(cur)
    return cur, false
end

-- Diagnostic: path straightness of a travelled trail. 1.0 is a perfect line;
-- the old saw-tooth scored well above 2.
function M.trail_ratio(trail)
    if not trail or #trail < 2 then return 1 end
    local len = 0
    for i = 1, #trail - 1 do len = len + U.dist2d(trail[i], trail[i + 1]) end
    local direct = U.dist2d(trail[1], trail[#trail])
    if direct < 1 then return 1 end
    return len / direct
end

-- Resamples a trail to fixed-length steps. Per-frame samples hide a saw-tooth
-- because a turn-rate limited character always changes heading slowly; the
-- oscillation only shows up at the scale it actually happens on.
function M.resample_trail(trail, step)
    if not trail or #trail < 2 then return trail or {} end
    step = step or 2000
    local out = { U.copy_vec(trail[1]) }
    local acc = 0
    for i = 1, #trail - 1 do
        local d = U.dist2d(trail[i], trail[i + 1])
        acc = acc + d
        if acc >= step then
            out[#out + 1] = U.copy_vec(trail[i + 1])
            acc = 0
        end
    end
    local last = trail[#trail]
    if U.dist2d(out[#out], last) > step * 0.25 then out[#out + 1] = U.copy_vec(last) end
    return out
end

-- Mean absolute heading change per resampled step, in degrees. This is the
-- saw-tooth metric: a squad walking a road scores a few degrees, the trail in
-- the original bug report scores tens of degrees.
function M.trail_jitter_spatial(trail, step)
    return M.trail_jitter(M.resample_trail(trail, step))
end

-- Fraction of resampled steps that turn back on themselves by more than
-- `limit` degrees. Real saw-tooth shows up here even when the mean is low.
function M.trail_reversals(trail, step, limit)
    local r = M.resample_trail(trail, step or 2000)
    limit = limit or 55
    local prev, n, rev = nil, 0, 0
    for i = 1, #r - 1 do
        local h = U.heading(r[i], r[i + 1])
        if h then
            if prev then
                n = n + 1
                if math.abs(U.deg(U.angle_delta(prev, h))) > limit then rev = rev + 1 end
            end
            prev = h
        end
    end
    if n == 0 then return 0 end
    return rev / n
end

-- Mean distance from the trail to the route it was supposed to follow.
function M.trail_cross_track(trail, route)
    if not (trail and route and route.points and #route.points > 1) then return 0 end
    local pts = route.points
    local total, n = 0, 0
    for _, p in ipairs(trail) do
        local best = math.huge
        for i = 1, #pts - 1 do
            local a, b = pts[i], pts[i + 1]
            local dx, dy = b.X - a.X, b.Y - a.Y
            local len2 = dx * dx + dy * dy
            local t = 0
            if len2 > 1e-6 then
                t = ((p.X - a.X) * dx + (p.Y - a.Y) * dy) / len2
                if t < 0 then t = 0 elseif t > 1 then t = 1 end
            end
            local cx, cy = a.X + dx * t, a.Y + dy * t
            local d = math.sqrt((p.X - cx) ^ 2 + (p.Y - cy) ^ 2)
            if d < best then best = d end
        end
        total = total + best
        n = n + 1
    end
    if n == 0 then return 0 end
    return total / n
end

-- Diagnostic: mean absolute heading change per step, in degrees. A straight
-- march is near 0; the saw-tooth trail in the bug report was above 40.
function M.trail_jitter(trail)
    if not trail or #trail < 3 then return 0 end
    local total, n = 0, 0
    local prev = nil
    for i = 1, #trail - 1 do
        local h = U.heading(trail[i], trail[i + 1])
        if h then
            if prev then
                total = total + math.abs(U.deg(U.angle_delta(prev, h)))
                n = n + 1
            end
            prev = h
        end
    end
    if n == 0 then return 0 end
    return total / n
end

return M
