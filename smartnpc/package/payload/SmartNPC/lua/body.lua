-- SmartNPC :: body.lua
-- The physical driver: everything that touches a rendered NPC pawn.
--
-- ============================================================================
-- WHY NPCs USED TO ZIG-ZAG, AND WHAT THIS FILE DOES ABOUT IT
-- ----------------------------------------------------------------------------
-- 1. Two brains steering one body.  SCUM's own AI controller keeps issuing its
--    own move requests while an external script issues others.  Each request
--    aborts the previous path mid-stride, so the pawn snaps between two
--    directions several times a second.
--      -> suppress_brain(): the native logic is stopped while SmartNPC drives,
--         and handed straight back for combat and on release.
--
-- 2. Re-commanding on a timer.  Calling MoveToLocation every tick throws away
--    the path that was already being followed and starts a new one.
--      -> issue() is gated by GetMoveStatus(): while the engine reports Moving
--         we do not touch it at all.  One command per route node, nothing more.
--
-- 3. A target that moves every tick.  Followers chasing a leader actor, or a
--    "carrot" point recomputed each frame, oscillate by construction.
--      -> the goal is a fixed route node.  It is constant for an entire leg,
--         so there is nothing to oscillate about.
--
-- 4. Rotation tuned too slow.  A pawn that cannot turn as fast as it walks
--    overshoots every corner and swings back - the classic zig-zag.
--      -> apply_profile() sets a human turn rate together with matching
--         acceleration and braking.
-- ============================================================================

local S = SMARTNPC
local U = S.util
local C = S.config
local W = S.world

local B = {}

local abs, max, min, floor = math.abs, math.max, math.min, math.floor

-- EPathFollowingStatus
local PF_IDLE, PF_WAITING, PF_PAUSED, PF_MOVING = 0, 1, 2, 3
-- EPathFollowingRequestResult
local REQ_FAILED, REQ_AT_GOAL, REQ_OK = 0, 1, 2

--------------------------------------------------------------------------
-- ground height cache
--------------------------------------------------------------------------
-- Every valid pawn position we observe teaches us the ground height of a grid
-- cell.  After a few minutes of uptime the island is well sampled and spawns /
-- unsticks no longer need an engine trace.

local GROUND = {}

function B.learn_ground(p)
    if not U.pos_sane(p) then return end
    local c, r = W.to_cell(p)
    if not c then return end
    local k = r * 1000 + c
    local prev = GROUND[k]
    if prev then
        GROUND[k] = prev * 0.85 + p.z * 0.15
    else
        GROUND[k] = p.z
    end
end

function B.ground_at(p, fallback)
    local c, r = W.to_cell(p)
    if not c then return fallback end
    local k = r * 1000 + c
    if GROUND[k] then return GROUND[k] end
    -- widen the search: neighbouring cells are usually within a few metres
    local best, bestd = nil, math.huge
    for dc = -3, 3 do
        for dr = -3, 3 do
            local kk = (r + dr) * 1000 + (c + dc)
            local g = GROUND[kk]
            if g then
                local d = dc * dc + dr * dr
                if d < bestd then bestd, best = d, g end
            end
        end
    end
    return best or fallback
end

function B.ground_samples()
    local n = 0
    for _ in pairs(GROUND) do n = n + 1 end
    return n
end

--------------------------------------------------------------------------
-- controller
--------------------------------------------------------------------------

function B.controller(rec)
    local c = U.resolve(rec.ctrl)
    if c then
        -- Confirm the controller still possesses this pawn; SCUM re-possesses
        -- NPCs when they change state and a stale controller silently no-ops.
        local pawn = U.resolve(U.get(c, "Pawn", nil))
        if pawn and U.key(pawn) == rec.key then return c end
        rec.ctrl = nil
    end
    local a = U.resolve(rec.actor)
    if not a then return nil end

    local cand = U.get(a, "Controller", nil)
    cand = U.resolve(cand)
    if not cand then
        local ok, gc = U.call(a, "GetController")
        if ok then cand = U.resolve(gc) end
    end
    if cand then
        rec.ctrl = cand
        rec.brain_off = false   -- a fresh controller has a fresh brain
        return cand
    end
    return nil
end

--------------------------------------------------------------------------
-- native brain suppression
--------------------------------------------------------------------------

function B.brain(ctrl)
    return U.resolve(U.get(ctrl, "BrainComponent", nil))
end

function B.suppress_brain(rec, ctrl)
    if not C.SuppressNativeBrain then return false end
    local br = B.brain(ctrl)
    if not br then
        -- No reflected brain component.  Fall back to muting the component that
        -- ticks the native decision logic, if one is exposed at all.
        rec.brain_missing = true
        return false
    end
    local ok = select(1, U.call(br, "StopLogic", "SmartNPC"))
    if not ok then
        U.call(br, "SetComponentTickEnabled", false)
        U.call(br, "Deactivate")
    end
    rec.brain_off = true
    rec.brain_at = U.now()
    return true
end

function B.release_brain(rec, ctrl)
    ctrl = ctrl or B.controller(rec)
    if not ctrl then return end
    local br = B.brain(ctrl)
    if not br then return end
    local ok = select(1, U.call(br, "RestartLogic"))
    if not ok then
        U.call(br, "Activate", true)
        U.call(br, "SetComponentTickEnabled", true)
    end
    rec.brain_off = false
end

--------------------------------------------------------------------------
-- movement profile
--------------------------------------------------------------------------

function B.gait_speed(rec, gait)
    local base
    if gait == "sprint" then base = C.SpeedSprint
    elseif gait == "jog" then base = C.SpeedJog
    else base = C.SpeedWalk end
    local jitter = 1 + (U.hash01(rec.key or "x", "gait") - 0.5) * 2 * C.SpeedJitter
    local tmul = (rec.traits and rec.traits.speed_mul) or 1
    return base * jitter * tmul
end

function B.apply_profile(rec, force)
    local a = U.resolve(rec.actor)
    if not a then return false end
    local mv = U.resolve(U.get(a, "CharacterMovement", nil))
    if not mv then
        mv = U.resolve(U.get(a, "CharacterMovementComponent", nil))
    end
    if not mv then
        rec.movement_missing = true
        return false
    end

    if rec.original_speed == nil then
        rec.original_speed = U.getnum(mv, "MaxWalkSpeed", nil)
    end

    local want = B.gait_speed(rec, rec.gait or "walk")
    if force or abs((rec.applied_speed or -1) - want) > 3 then
        U.set(mv, "MaxWalkSpeed", want)
        rec.applied_speed = want
    end
    if force or not rec.profile_done then
        U.set(mv, "MaxAcceleration", C.MoveAcceleration)
        U.set(mv, "BrakingDecelerationWalking", C.MoveBraking)
        U.set(mv, "GroundFriction", C.GroundFriction)
        U.set(mv, "BrakingFrictionFactor", 1.0)
        U.set(mv, "bRequestedMoveUseAcceleration", true)
        U.set(mv, "bOrientRotationToMovement", true)
        U.set(mv, "bUseControllerDesiredRotation", false)
        U.set(mv, "RotationRate", { Pitch = 0.0, Yaw = C.RotationRateYaw, Roll = 0.0 })
        if C.UseRVOAvoidance then
            U.set(mv, "bUseRVOAvoidance", true)
            U.set(mv, "AvoidanceConsiderationRadius", C.AvoidanceRadiusUU)
            U.set(mv, "AvoidanceWeight", 0.5)
        end
        rec.profile_done = true
    end
    return true
end

--------------------------------------------------------------------------
-- move status / commands
--------------------------------------------------------------------------

function B.move_status(ctrl)
    local ok, v = U.call(ctrl, "GetMoveStatus")
    if not ok then return nil end
    local n = U.num(v, nil)
    return n
end

-- Issue exactly one MoveToLocation.  Returns true when the engine accepted it.
function B.issue(rec, ctrl, goal, now, opts)
    opts = opts or {}
    local dest = { X = goal.x, Y = goal.y, Z = goal.z or B.ground_at(goal, rec.pos and rec.pos.z or 0) }

    local ok, res = pcall(function()
        return ctrl:MoveToLocation(
            dest,
            opts.acceptance or C.MoveAcceptanceUU,
            false,                    -- bStopOnOverlap: do not halt on brush contact
            true,                     -- bUsePathfinding
            true,                     -- bProjectDestinationToNavigation
            false,                    -- bCanStrafe: face where you walk
            nil,                      -- FilterClass
            true                      -- bAllowPartialPath: keep walking, replan later
        )
    end)

    rec.last_issue_at = now
    if not ok then
        rec.issue_errors = (rec.issue_errors or 0) + 1
        if rec.issue_errors == 3 then
            U.warn_once("moveto-" .. tostring(rec.class or "npc"), tostring(res))
        end
        return false
    end

    local code = U.num(res, REQ_OK)
    rec.cmd = {
        target = { x = goal.x, y = goal.y, z = dest.Z },
        issued_at = now,
        probe_pos = rec.pos and { x = rec.pos.x, y = rec.pos.y } or nil,
        probe_at = now,
        stalls = (rec.cmd and rec.cmd.stalls) or 0,
        code = code,
    }
    rec.move_commands = (rec.move_commands or 0) + 1
    if code == REQ_FAILED then
        rec.failed_requests = (rec.failed_requests or 0) + 1
        return false
    end
    return true
end

function B.stop(rec)
    local ctrl = B.controller(rec)
    if ctrl then U.call(ctrl, "StopMovement") end
    rec.cmd = nil
end

--------------------------------------------------------------------------
-- facing
--------------------------------------------------------------------------

function B.face(rec, ctrl, point)
    if not point then
        U.call(ctrl, "K2_ClearFocus")
        return
    end
    U.call(ctrl, "K2_SetFocalPoint", { X = point.x, Y = point.y, Z = point.z or (rec.pos and rec.pos.z or 0) })
end

--------------------------------------------------------------------------
-- teleport helpers (offscreen only)
--------------------------------------------------------------------------

function B.can_reposition(pos, nearest_player_dist)
    if not pos then return false end
    return (nearest_player_dist or math.huge) > C.UnstickMinPlayerDistanceUU
end

function B.teleport(rec, p)
    local a = U.resolve(rec.actor)
    if not a then return false end
    local z = p.z or B.ground_at(p, rec.pos and rec.pos.z or 0)
    if not z then return false end
    local ok, res = U.call(a, "K2_TeleportTo",
        { X = p.x, Y = p.y, Z = z + 60 },
        { Pitch = 0, Yaw = rec.yaw or 0, Roll = 0 })
    if ok and res ~= false then
        rec.cmd = nil
        return true
    end
    -- K2_TeleportTo refuses when the destination overlaps geometry; lift and retry.
    local ok2, res2 = U.call(a, "K2_TeleportTo",
        { X = p.x, Y = p.y, Z = z + 400 },
        { Pitch = 0, Yaw = rec.yaw or 0, Roll = 0 })
    if ok2 and res2 ~= false then
        rec.cmd = nil
        return true
    end
    return false
end

--------------------------------------------------------------------------
-- per-NPC step
--------------------------------------------------------------------------
-- Called on the game thread, at most a few times per second per NPC.
-- rec.goal is written by the squad brain; this function decides only *whether*
-- and *how* to hand that goal to the engine.

function B.step(rec, now, ctx)
    local a = U.resolve(rec.actor)
    if not a then return false end

    local pos = U.actor_pos(a)
    if not U.pos_sane(pos) then
        rec.bad_pos = (rec.bad_pos or 0) + 1
        return rec.bad_pos < 20
    end
    rec.bad_pos = 0

    -- observed speed, used by the map and by stall detection
    if rec.pos and rec.pos_at then
        local dt = now - rec.pos_at
        if dt > 0.25 then
            rec.speed = U.dist2(pos, rec.pos) / dt
            rec.pos_at = now
            rec.prev_pos = rec.pos
        end
    else
        rec.pos_at = now
    end
    rec.pos = pos
    rec.yaw = U.actor_yaw(a) or rec.yaw
    B.learn_ground(pos)

    local ctrl = B.controller(rec)
    if not ctrl then
        rec.no_ctrl = (rec.no_ctrl or 0) + 1
        return true
    end
    rec.no_ctrl = 0

    -- profile + brain upkeep
    if now - (rec.profile_at or -1e9) > 6 then
        B.apply_profile(rec)
        rec.profile_at = now
    end
    if C.SuppressNativeBrain and not rec.combat
        and (not rec.brain_off or now - (rec.brain_at or 0) > C.BrainReassertSec) then
        B.suppress_brain(rec, ctrl)
    end
    if rec.combat and C.RestoreBrainInCombat and rec.brain_off then
        B.release_brain(rec, ctrl)
    end

    -- In combat SCUM's own AI owns the pawn: it aims, shoots and takes cover
    -- far better than an external script can.  We only keep the squad together.
    if rec.combat and C.HandBackToNativeAI then
        rec.cmd = nil
        return true
    end

    local goal = rec.goal
    if not goal then
        return true
    end

    local status = B.move_status(ctrl)
    local cmd = rec.cmd

    ----------------------------------------------------------------------
    -- THE ISSUE RULE
    ----------------------------------------------------------------------
    local reason = nil

    if not cmd then
        reason = "first"
    elseif U.dist2(cmd.target, goal) > C.GoalChangeReissueUU then
        reason = "goal-moved"
    elseif status == nil then
        -- GetMoveStatus not exposed: fall back to arrival + age.
        if U.dist2(pos, cmd.target) < C.MoveAcceptanceUU * 1.6 then
            reason = "arrived"
        elseif now - cmd.issued_at > C.CommandMaxAgeSec then
            reason = "age"
        end
    elseif status ~= PF_MOVING then
        reason = "idle"
    elseif now - cmd.issued_at > C.CommandMaxAgeSec then
        reason = "age"
    end

    -- stall detection while the engine claims to be moving
    if not reason and cmd and (status == nil or status == PF_MOVING) then
        local probe = cmd.probe_pos
        if probe then
            if U.dist2(pos, probe) > C.StallProgressUU then
                cmd.probe_pos = { x = pos.x, y = pos.y }
                cmd.probe_at = now
                cmd.stalls = 0
            elseif now - (cmd.probe_at or now) > C.StallCheckSec then
                cmd.stalls = (cmd.stalls or 0) + 1
                cmd.probe_at = now
                reason = "stall"
            end
        else
            cmd.probe_pos = { x = pos.x, y = pos.y }
            cmd.probe_at = now
        end
    end

    if not reason then
        rec.last_reason = nil
        return true
    end

    -- hard rate limit: nothing below this ever reaches the engine
    if now - (rec.last_issue_at or -1e9) < C.MinCommandIntervalSec then
        return true
    end

    rec.last_reason = reason

    ----------------------------------------------------------------------
    -- stall ladder
    ----------------------------------------------------------------------
    local stalls = (cmd and cmd.stalls) or 0
    if reason == "stall" then
        rec.stall_total = (rec.stall_total or 0) + 1

        if stalls == 1 then
            -- Clear the stuck path request first; re-issuing on top of a jammed
            -- path following state is what produced the old retry storms.
            U.call(ctrl, "StopMovement")
        elseif stalls == 2 then
            -- Aim at a nearer intermediate point: short paths route around the
            -- obstacle that the long path kept ignoring.
            local dx, dy, d = U.norm2(goal.x - pos.x, goal.y - pos.y)
            if d > 1 then
                local mid = { x = pos.x + dx * min(d * 0.5, 4000), y = pos.y + dy * min(d * 0.5, 4000) }
                if not W.is_water(mid) then goal = mid end
            end
        elseif stalls >= 3 and stalls < C.StallsBeforeUnstick then
            -- Sidestep: pick a point beside the blocked direction.
            local dx, dy = U.norm2(goal.x - pos.x, goal.y - pos.y)
            local sgn = (stalls % 2 == 0) and 1 or -1
            local side = { x = pos.x + dy * 2600 * sgn + dx * 1500,
                           y = pos.y - dx * 2600 * sgn + dy * 1500 }
            if not W.is_water(side) then goal = side end
            rec.want_replan = true
        elseif stalls >= C.StallsBeforeUnstick then
            rec.want_replan = true
            if B.can_reposition(pos, ctx and ctx.nearest_player_dist) then
                local target = rec.goal
                local dest = W.snap_to_land(target, nil, 4)
                if dest and B.teleport(rec, dest) then
                    rec.unstick_count = (rec.unstick_count or 0) + 1
                    S.telemetry.event("UNSTICK", rec.squad_id, string.format(
                        "%s repositioned %.0f m after %d stalls",
                        rec.short or "npc", U.dist2(pos, dest) / 100, stalls))
                    return true
                end
            end
            if cmd then cmd.stalls = 0 end
        end
    end

    ----------------------------------------------------------------------
    -- face where we are going, then command once
    ----------------------------------------------------------------------
    U.set(ctrl, "bAllowStrafe", false)
    B.face(rec, ctrl, nil)
    B.issue(rec, ctrl, goal, now)
    return true
end

--------------------------------------------------------------------------
-- release (hand the pawn back to SCUM untouched)
--------------------------------------------------------------------------

function B.release(rec)
    local ctrl = B.controller(rec)
    if ctrl then
        U.call(ctrl, "StopMovement")
        B.release_brain(rec, ctrl)
    end
    local a = U.resolve(rec.actor)
    if a and rec.original_speed then
        local mv = U.resolve(U.get(a, "CharacterMovement", nil))
        if mv then U.set(mv, "MaxWalkSpeed", rec.original_speed) end
    end
    rec.goal = nil
    rec.cmd = nil
end

return B
