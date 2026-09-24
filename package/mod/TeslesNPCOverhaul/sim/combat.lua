-- Group combat and zombie pressure.
--
-- Contact is evaluated between groups that are physically present, within the
-- ranges the guide gives: about 120 m for hostile group contact and about
-- 140 m for zombie pressure. Individual behaviour still comes from the
-- personality scoring in npc/utility.lua - this module supplies the context.
local U = require("core.util")
local Utility = require("npc.utility")
local Stress = require("npc.stress")
local Trauma = require("npc.trauma")
local Diplomacy = require("npc.diplomacy")
local Leadership = require("npc.leadership")
local Grid = require("world.navgrid")
local Tr = require("npc.trauma")
local function Utility_trait(m, k) return Tr.trait(m, k) end

local C = {}

C.tuning = {
    contact_uu = 12000,            -- 120 m hostile group contact
    zombie_uu = 14000,             -- 140 m zombie awareness
    preferred_range_uu = 2500,     -- 25 m ranged stand-off
    min_range_uu = 900,
    melee_range_uu = 250,
    retreat_min_uu = 9000,
    retreat_max_uu = 17000,
    flank_offset_uu = 3200,
    morale_retreat = 0.25,
    retarget_sec = 6,
    disengage_uu = 26000,
    zombie_panic_count = 6,
}

-- Finds hostile groups in contact range. Physical squads meet physical
-- squads, virtual ones meet virtual ones: a squad within 120 m of a physical
-- one is inside a player's render circle and physical itself.
function C.find_contacts(group, groups, registry, now)
    local out = {}
    if not group.position then return out end
    local range = C.contact_range(group)
    for _, other in ipairs(groups) do
        if other ~= group and (other.physical == group.physical) and other.position
            and not (other.disengaged_until and other.disengaged_until > (now or 0)) then
            local d = U.dist2d(group.position, other.position)
            if d <= range then
                local hostile, value, tier = Diplomacy.hostile(registry, group, other)
                if hostile then
                    out[#out + 1] = { group = other, distance = d, standing = value, tier = tier }
                end
            end
        end
    end
    table.sort(out, function(a, b) return a.distance < b.distance end)
    return out
end

-- Aggressive, watchful squads pick a fight from further away.
function C.contact_range(group)
    local now = os.time()
    if group._range and now - group._range_at < 15 then return group._range end
    local sum, n = 0, 0
    for _, m in ipairs(group.members) do
        if m.alive then
            sum = sum + Utility_trait(m, "aggression") * 0.5 + Utility_trait(m, "awareness") * 0.3
            n = n + 1
        end
    end
    local f = n > 0 and (0.75 + sum / n * 0.7) or 1
    group._range, group._range_at = C.tuning.contact_uu * f, now
    return group._range
end

function C.zombie_pressure(group, bridge)
    if not (bridge and bridge.nearby_zombies and group.position) then return 0, 0 end
    local n = bridge.nearby_zombies(group.position, C.tuning.zombie_uu) or 0
    local alive = 0
    for _, m in ipairs(group.members) do if m.alive then alive = alive + 1 end end
    if alive == 0 then return 1, n end
    return U.clamp(n / math.max(1, alive * 2.5), 0, 1), n
end

-- Builds the decision context shared by every member of a group this tick.
function C.build_context(group, contact, zombie_pressure)
    local ctx = {
        threat = contact ~= nil,
        threat_distance = contact and contact.distance or nil,
        zombie_pressure = zombie_pressure or 0,
        cover_available = 0.5,
    }
    if contact then
        local own = Utility.group_power(group)
        local theirs = Utility.group_power(contact.group)
        ctx.power_ratio = theirs > 0.01 and (own / theirs) or 3.0
    else
        ctx.power_ratio = 1.0
    end
    for _, m in ipairs(group.members) do
        if m.alive and (m.health or 100) < 45 then ctx.friend_down = true end
    end
    local order, weight = Leadership.order(group, ctx.threat)
    ctx.order = order
    ctx.order_weight = weight
    return ctx
end

-- Runs the per-member decision pass. Returns a count per action.
function C.decide_group(group, ctx)
    local tally = {}
    for _, m in ipairs(group.members) do
        if m.alive then
            local action = Utility.decide(m, ctx)
            tally[action] = (tally[action] or 0) + 1
        end
    end
    return tally
end

-- Tactical destination for one member given its chosen action. Every point is
-- checked against the terrain grid, so no order sends anyone into water.
function C.tactical_point(npc, group, enemy_pos, action)
    local pos = npc.position or group.position
    if not pos then return nil end
    local t = C.tuning

    if action == "RETREAT" or action == "FLEE" then
        if not enemy_pos then return nil end
        local dir = U.direction(enemy_pos, pos)
        if not dir then return nil end
        local dist = (action == "FLEE") and t.retreat_max_uu or t.retreat_min_uu
        local p = { X = pos.X + dir.X * dist, Y = pos.Y + dir.Y * dist, Z = pos.Z }
        return Grid.snap_to_land(p) or p
    end

    if not enemy_pos then return nil end
    local dir, dist = U.direction(pos, enemy_pos)
    if not dir then return nil end

    if action == "ATTACK" then
        local skill = (npc.skills and npc.skills.rifle or 0)
        local ranged = skill > 0.25
        -- Low-skill attackers close in further than a trained shooter would.
        local want = ranged and (t.preferred_range_uu * (0.55 + skill * 0.65))
                             or t.melee_range_uu
        want = math.max(t.min_range_uu, want)
        if dist <= want then return nil end
        local step = dist - want
        return { X = pos.X + dir.X * step, Y = pos.Y + dir.Y * step, Z = pos.Z }
    end

    if action == "FLANK" then
        local side = ((npc.id or 1) % 2 == 0) and 1 or -1
        local skill = (npc.skills and npc.skills.tacticalMovement or 0.3)
        local offset = t.flank_offset_uu * (0.6 + skill * 0.8) * side
        local px, py = -dir.Y, dir.X
        local approach = math.max(t.preferred_range_uu, dist * 0.55)
        local p = {
            X = enemy_pos.X - dir.X * approach + px * offset,
            Y = enemy_pos.Y - dir.Y * approach + py * offset,
            Z = pos.Z,
        }
        return Grid.snap_to_land(p) or p
    end

    if action == "COVER" then
        -- Hold position, edging slightly away from the line of fire.
        local px, py = -dir.Y, dir.X
        local side = ((npc.id or 1) % 2 == 0) and 1 or -1
        local p = { X = pos.X + px * 500 * side, Y = pos.Y + py * 500 * side, Z = pos.Z }
        return Grid.snap_to_land(p) or p
    end

    if action == "HELP_FRIEND" then
        local hurt, best = nil, math.huge
        for _, m in ipairs(group.members) do
            if m.alive and m ~= npc and (m.health or 100) < 60 and m.position then
                local d = U.dist2d(pos, m.position)
                if d < best then hurt, best = m, d end
            end
        end
        if hurt then return U.copy_vec(hurt.position) end
    end

    return nil
end

-- Applies the stress consequences of a contact to everyone in the group.
function C.apply_contact_stress(group, ctx, rng)
    for _, m in ipairs(group.members) do
        if m.alive then
            if ctx.threat then
                Stress.apply(m, "ENEMY_SPOTTED")
                if (ctx.power_ratio or 1) < 0.65 then
                    Stress.apply(m, "OUTNUMBERED")
                    Trauma.maybe_trauma(m, "OUTNUMBERED", rng)
                end
            end
            if (ctx.zombie_pressure or 0) > 0.55 then
                Stress.apply(m, "ZOMBIE_HORDE", ctx.zombie_pressure)
                Trauma.maybe_trauma(m, "ZOMBIE_HORDE", rng)
            elseif (ctx.zombie_pressure or 0) > 0.15 then
                Stress.apply(m, "ZOMBIE_CONTACT", ctx.zombie_pressure)
            end
        end
    end
end

-- Contact pushes two groups further apart diplomatically. A standing feud is
-- how a bandit gang and a police patrol end up as blood enemies over a
-- session instead of resetting to the default every time they meet.
function C.register_contact(registry, a, b, dt, intensity)
    if not (registry and a and b) then return end
    local delta = -0.0025 * (dt or 1) * (intensity or 1)
    Diplomacy.adjust(registry, a, b, delta, "contact")
end

-- Records a casualty: memories, stress and morale for everyone who saw it.
function C.on_member_lost(group, victim, rng, on_event, registry, killer)
    if registry and killer then
        Diplomacy.adjust(registry, group, killer, -0.25, "casualty")
    end
    victim.alive = false
    victim.materialized = false
    victim.runtime_id = nil
    local was_leader = victim.is_leader
    local survivors = {}
    for _, m in ipairs(group.members) do
        if m.alive then survivors[#survivors + 1] = m end
    end
    local now = os.time()
    if #survivors == 1 then
        -- The last one standing: in a pair this is losing the only other
        -- person there was. A shock that goes all the way down, a trauma for
        -- certain, and grief that keeps the stress floor high for hours.
        local s = survivors[1]
        Stress.apply(s, "PARTNER_LOST")
        s.stress = math.max(s.stress or 0, 0.85)
        s.morale = U.clamp((s.morale or 0.6) - 0.4, 0, 1)
        s.grief_until = now + 3 * 3600
        s.shock_until = now + 20 + (rng and rng:range(0, 25) or 10)
        s.reaction, s.reaction_at = "PARTNER_LOST", now
        Trauma.remember(s, "PARTNER_LOST", victim.name, 1.0)
        Trauma.add(s, "FEAR_OF_LOSS")
        -- And one more scar, by temperament: revenge, or never again.
        local t = s.traits or {}
        if (t.aggression or 0.5) + (t.vindictiveness or 0.5) > (t.fearfulness or 0.5) + 0.5 then
            Trauma.add(s, "VENGEFUL")
        else
            Trauma.add(s, (rng and rng:chance(0.5)) and "COMBAT_AVERSE" or "PARANOIA")
        end
        if on_event then on_event("PARTNER_LOST", group.gid, s.name .. " lost " .. victim.name) end
    else
        for _, m in ipairs(survivors) do
            Stress.apply(m, was_leader and "LEADER_DOWN" or "ALLY_DOWN")
            Trauma.remember(m, was_leader and "LEADER_DOWN" or "ALLY_DOWN",
                victim.name, was_leader and 0.95 or 0.7)
            Trauma.maybe_trauma(m, was_leader and "LEADER_DOWN" or "ALLY_DOWN", rng)
            -- A small squad feels every loss more.
            if #survivors <= 2 then m.grief_until = now + 3600 end
        end
    end
    group.morale = U.clamp((group.morale or 0.6) - (was_leader and 0.28 or 0.14)
        - (#survivors == 1 and 0.25 or 0), 0, 1)
    group.cohesion = U.clamp((group.cohesion or 0.7) - (was_leader and 0.24 or 0.10), 0, 1)
    if on_event then
        on_event(was_leader and "LEADER_LOST" or "MEMBER_LOST", group.gid, victim.name)
    end
    return was_leader
end

-- ------------------------------------------------------------ gunfire ---

-- Squads kill each other. Once a second every member that is fighting
-- (not retreating or fleeing) fires at the nearest living enemy in range.
-- Hit chance comes from weapon skill, perception and level, falls with range
-- and against an enemy in cover. Hits cost health; at zero the NPC is dead.
-- The caller applies each hit to the real actor as well when there is one.
C.fire = {
    range_uu = 15000,          -- 150 m effective range
    base_hit = 0.28,
    dmg_min = 22, dmg_max = 42,
}

local function alive_members(group)
    local out = {}
    for _, m in ipairs(group.members) do if m.alive then out[#out + 1] = m end end
    return out
end

local function weapon_skill(m)
    local sk = m.skills or {}
    return math.max(sk.rifle or 0, (sk.pistol or 0) * 0.85, (sk.shotgun or 0) * 0.8)
end

-- One second of shooting from `group` at `enemy`. Returns a list of hits
-- { shooter, target, damage, killed }.
function C.exchange_fire(group, enemy, rng, accuracy)
    local hits = {}
    local foes = alive_members(enemy)
    if #foes == 0 then return hits end
    local f = C.fire
    for _, m in ipairs(group.members) do
        if m.alive and m.action ~= "RETREAT" and m.action ~= "FLEE" then
            local mp = m.position or group.position
            local target, best = nil, math.huge
            for _, e in ipairs(foes) do
                if e.alive then
                    local d = U.dist2d(mp, e.position or enemy.position)
                    if d < best then target, best = e, d end
                end
            end
            if target and best <= f.range_uu then
                -- Roughly one aimed shot every two seconds.
                if rng:chance(0.5) then
                    local skill = weapon_skill(m) + ((m.skills or {}).perception or 0) * 0.4
                        + (m.level or 1) * 0.06
                    local p = f.base_hit * (0.55 + skill) * (1 - 0.6 * best / f.range_uu)
                    if target.action == "COVER" then p = p * 0.6 end
                    if accuracy then p = p * accuracy(m) end
                    hits.shots = (hits.shots or 0) + 1
                    if rng:chance(U.clamp(p, 0.02, 0.8)) then
                        local dmg = rng:range(f.dmg_min, f.dmg_max) * (1 + (m.level or 1) * 0.05)
                        target.health = (target.health or 100) - dmg
                        local killed = target.health <= 0
                        if killed then target.health = 0 end
                        hits[#hits + 1] = { shooter = m, target = target, damage = dmg, killed = killed }
                        if killed then target.alive = false end
                    end
                end
            end
        end
    end
    return hits
end

-- A squad breaks off when it has lost its nerve: morale under the retreat
-- line, or most of its living members retreating or fleeing.
function C.should_disengage(group)
    if (group.morale or 1) < C.tuning.morale_retreat then return true end
    local n, back = 0, 0
    for _, m in ipairs(group.members) do
        if m.alive then
            n = n + 1
            if m.action == "RETREAT" or m.action == "FLEE" then back = back + 1 end
        end
    end
    return n == 0 or back / n > 0.5
end

return C
