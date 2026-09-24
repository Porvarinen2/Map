-- What an NPC feels, and what that makes it do.
--
-- Every meter has consequences here. Stimuli raise stress: gunfire heard or
-- close by, zombies near or swarming, wounds, friends falling, being
-- outnumbered. Stress spreads through a squad, and a steady leader damps it.
-- Stress, morale, fatigue and personality then change behaviour:
--
--   CALM / ALERT   normal work; the curious go and look at gunfire, the
--                  cautious stop and wait, or move away from it
--   STRESSED       worse aim; the squad closes up and prefers cover
--   HIGH           much worse aim; cover and retreat win most decisions
--   PANIC          the NPC runs from the threat; a squad in panic breaks
--                  off whatever it was doing and flees
--   low morale     a squad retreats from a fight; very low, it routs
--   fatigue        worse aim, slower recovery, forced rest (activity.lua)
--
-- Zombies near a physical squad are fought: members that keep their nerve
-- shoot the nearest ones (real damage through the engine), the fearful back
-- off. Virtual squads working a town meet the undead in the abstract: stress,
-- sometimes a wound.
local U = require("core.util")
local Stress = require("npc.stress")
local Tr = require("npc.trauma")
local Grid = require("world.navgrid")

local Bh = {}

Bh.tuning = {
    hear_near_uu = 8000,         -- gunfire this close is "near"
    hear_far_uu = 35000,         -- 350 m: gunfire is heard
    zombie_close_uu = 4000,      -- 40 m: a zombie is on top of them
    zombie_near_uu = 14000,      -- 140 m: zombies about
    zombie_fire_uu = 5500,       -- shooting range at zombies
    noise_life_sec = 8,
    flee_uu = 16000,             -- a fleeing squad runs this far
    panic_share = 0.5,           -- this share in panic breaks the squad
    rout_morale = 0.12,
    investigate_uu = 30000,
}

-- Cooldowns stop one continuous stimulus from being counted every second.
local COOLDOWN = {
    GUNSHOT_NEAR = 10, GUNSHOT_DISTANT = 20, ZOMBIE_CONTACT = 12, ZOMBIE_HORDE = 15,
    ENEMY_SPOTTED = 30, OUTNUMBERED = 20, INJURY = 1, SEVERE_INJURY = 1, AMBUSHED = 30,
}

local function stim(m, event, now, scale)
    m.stim_cd = m.stim_cd or {}
    if (m.stim_cd[event] or 0) > now then return 0 end
    m.stim_cd[event] = now + (COOLDOWN[event] or 5)
    local d = Stress.apply(m, event, scale)
    if d > 0 then m.reaction, m.reaction_at = event, now end
    return d
end
Bh.stim = stim

-- ------------------------------------------------------------- noises ---

-- Gunfire anywhere in the world, kept for a few seconds so every squad in
-- earshot can hear it once.
function Bh.noise(director, pos, kind, loudness)
    if not pos then return end
    director.noises = director.noises or {}
    local list = director.noises
    list[#list + 1] = { pos = U.copy_vec(pos), kind = kind or "gunfire",
                        t = director.now, loud = loudness or 1 }
    if #list > 200 then table.remove(list, 1) end
end

local function recent_noises(director, now)
    local keep, out = {}, {}
    for _, n in ipairs(director.noises or {}) do
        if now - n.t <= Bh.tuning.noise_life_sec then
            keep[#keep + 1] = n
            out[#out + 1] = n
        end
    end
    director.noises = keep
    return out
end

-- ------------------------------------------------------------ helpers ---

local function alive(group)
    local out = {}
    for _, m in ipairs(group.members) do if m.alive then out[#out + 1] = m end end
    return out
end

local function mean(list, f)
    if #list == 0 then return 0 end
    local s = 0
    for _, m in ipairs(list) do s = s + f(m) end
    return s / #list
end

-- Accuracy multiplier from the state of mind and body: stress and fatigue
-- ruin aim, composure and combat confidence hold it together.
function Bh.accuracy(m, fatigue)
    local stress = m.stress or 0
    local comp = Tr.trait(m, "composure")
    local conf = Tr.trait(m, "combatConfidence")
    local f = (1 - stress * 0.6) * (0.85 + comp * 0.15 + conf * 0.15)
    local tired = math.max(0, (fatigue or 0) - 60) / 100
    f = f * (1 - tired * 0.8)
    if (m.health or 100) < 50 then f = f * 0.8 end
    return U.clamp(f, 0.15, 1.3)
end

-- How far a squad notices things: awareness and perception.
local function senses(group, now)
    if group._senses and now - group._senses_at < 15 then return group._senses end
    local list = alive(group)
    group._senses = 0.8 + mean(list, function(m)
        return Tr.trait(m, "awareness") * 0.25 + ((m.skills or {}).perception or 0) * 0.25
    end)
    group._senses_at = now
    return group._senses
end

-- ----------------------------------------------------------- stimuli ---

-- Gunfire, zombies and wounds for one squad this tick. Returns a summary the
-- rest of the tick uses.
function Bh.sense(director, group, now, zombies)
    local t = Bh.tuning
    local list = alive(group)
    local out = { noise = nil, noise_d = math.huge, zombies_close = 0, zombies_near = 0 }
    if #list == 0 or not group.position then return out end
    local reach = senses(group, now)

    -- Gunfire. The squad's own shots are not news to it.
    for _, n in ipairs(recent_noises(director, now)) do
        if n.source ~= group.gid and n.from ~= group.gid then
            local d = U.dist2d(n.pos, group.position)
            if d <= t.hear_far_uu * reach * n.loud then
                if d < out.noise_d then out.noise, out.noise_d = n, d end
            end
        end
    end
    if out.noise then
        local near = out.noise_d <= t.hear_near_uu
        -- A squad already in a firefight expects the noise; it still wears.
        local fightscale = (group.act and group.act.state == "COMBAT") and 0.35 or 1
        for _, m in ipairs(list) do
            stim(m, near and "GUNSHOT_NEAR" or "GUNSHOT_DISTANT", now,
                 (near and 1 or U.clamp(1.4 - out.noise_d / t.hear_far_uu, 0.3, 1)) * fightscale)
        end
    end

    -- Zombies around a physical squad.
    for _, z in ipairs(zombies or {}) do
        local d = U.dist2d(z.pos, group.position)
        if d <= t.zombie_close_uu then out.zombies_close = out.zombies_close + 1 end
        if d <= t.zombie_near_uu * reach then out.zombies_near = out.zombies_near + 1 end
    end
    if out.zombies_near > 0 then
        -- A few zombies are work for an armed squad; a horde is terror. The
        -- brave and the confident take them in their stride.
        local horde = out.zombies_near >= math.max(6, #list * 3)
        for _, m in ipairs(list) do
            local nerve = 1.25 - Tr.trait(m, "courage") * 0.35 - Tr.trait(m, "combatConfidence") * 0.3
            stim(m, horde and "ZOMBIE_HORDE" or "ZOMBIE_CONTACT", now,
                 U.clamp(out.zombies_near / math.max(1, #list * 2), 0.4, 1.0) * nerve)
        end
    end

    -- Wounds: a physical body losing health, whoever did it.
    for _, m in ipairs(list) do
        local hp = m.health or 100
        if m.last_hp and hp < m.last_hp - 2 then
            local lost = m.last_hp - hp
            stim(m, lost >= 25 and "SEVERE_INJURY" or "INJURY", now)
            m.wounded_at = now
            group.hit_at = now
            -- Friends see it too.
            for _, o in ipairs(list) do
                if o ~= m then stim(o, "NEAR_MISS", now, 0.5) end
            end
        end
        m.last_hp = hp
    end
    return out
end

-- Virtual squads working a town meet the undead in the abstract.
local ZOMBIE_RISK = { CITY = 0.030, MILITARY = 0.028, INDUSTRIAL = 0.018, VILLAGE = 0.012,
                      MEDICAL = 0.02, RESEARCH = 0.02, BUNKER = 0.016, ABANDONED_BUNKER = 0.02 }
function Bh.abstract_zombies(director, group, now, rng)
    if group.physical then return end
    local st = group.act and group.act.state
    if st ~= "SEARCH" and st ~= "PATROL" then return end
    local poi = group.act.goal_poi
    local risk = poi and ZOMBIE_RISK[poi.kind] or 0
    if risk <= 0 or not rng:chance(risk) then return end
    local list = alive(group)
    local horde = rng:chance(0.2)
    for _, m in ipairs(list) do
        stim(m, horde and "ZOMBIE_HORDE" or "ZOMBIE_CONTACT", now)
    end
    -- Now and then someone gets bitten or clawed.
    if rng:chance(horde and 0.35 or 0.12) and #list > 0 then
        local v = list[rng:int(1, #list)]
        v.health = math.max(5, (v.health or 100) - rng:range(8, 28))
        stim(v, "INJURY", now)
    end
    -- Sometimes they had to shoot their way out, and others hear it.
    if rng:chance(0.35) then
        Bh.noise(director, group.position, "gunfire", 0.7)
        local n = director.noises[#director.noises]
        n.from, n.poi = group.gid, poi.id
    end
    group.zombie_note = horde and "zombilauma" or "zombeja"
    group.zombie_at = now
end

-- A hostile squad in sight: counted once in a while, not every second.
function Bh.contact_stress(group, ctx, now)
    if not ctx.threat then return end
    for _, m in ipairs(alive(group)) do
        stim(m, "ENEMY_SPOTTED", now)
        if (ctx.power_ratio or 1) < 0.65 then stim(m, "OUTNUMBERED", now) end
    end
end

-- --------------------------------------------------------- contagion ---

-- Fear spreads through a squad; a steady leader and a close-knit squad hold
-- it back.
function Bh.contagion(group, dt)
    local list = alive(group)
    if #list < 2 then return end
    local avg = mean(list, function(m) return m.stress or 0 end)
    local lead = nil
    for _, m in ipairs(list) do if m.is_leader then lead = m end end
    local calm_lead = lead and (((lead.skills or {}).leadership or 0.3) * 0.5
        + Tr.trait(lead, "composure") * 0.5) or 0.3
    local rate = 0.02 * (1.2 - calm_lead) * (1.1 - (group.cohesion or 0.7) * 0.4)
    for _, m in ipairs(list) do
        local s = m.stress or 0
        if avg > s then
            m.stress = U.clamp(s + (avg - s) * rate * dt, 0, 1)
        end
    end
    -- The squad's morale follows its members'.
    local mm = mean(list, function(m) return m.morale or 0.6 end)
    group.morale = U.clamp((group.morale or 0.6) * 0.97 + mm * 0.03, 0, 1)
end

-- ------------------------------------------------------------ mood ---

Bh.MOOD_FI = {
    CALM = "Rauhallinen", ALERT = "Valpas", TENSE = "Jännittynyt", SHAKEN = "Järkyttynyt",
    PANIC = "Paniikissa", ROUT = "Hajoaa pakoon", ZOMBIES = "Torjuu zombeja",
    INVESTIGATE = "Tutkii ammuskelua", COVER = "Suojautuu tulelta", AVOID = "Väistää ammuskelua", HOLD = "Odottaa hiljaa",
    FIGHT = "Taistelee",
}

function Bh.mood(group, now)
    local list = alive(group)
    if #list == 0 then return "CALM", 0 end
    local panic = 0
    for _, m in ipairs(list) do if (m.stress or 0) >= 0.8 then panic = panic + 1 end end
    local avg = mean(list, function(m) return m.stress or 0 end)
    if (group.morale or 1) < Bh.tuning.rout_morale then return "ROUT", panic end
    -- Panic breaks a squad when fear meets a reason: someone hit or fallen
    -- in the last half minute, or fear so deep nothing else matters.
    local shock = now and ((group.hit_at and now - group.hit_at < 30)
        or (group.loss_at and now - group.loss_at < 30))
    if panic / #list >= Bh.tuning.panic_share and (shock or avg >= 0.9) then
        return "PANIC", panic
    end
    if avg >= 0.6 then return "SHAKEN", panic end
    if avg >= 0.4 then return "TENSE", panic end
    if avg >= 0.2 then return "ALERT", panic end
    return "CALM", panic
end

-- --------------------------------------------------------- reactions ---

local function away_point(from, threat, dist)
    local dir = U.direction(threat, from)
    if not dir then
        local a = math.random() * math.pi * 2
        dir = { X = math.cos(a), Y = math.sin(a) }
    end
    local p = { X = from.X + dir.X * dist, Y = from.Y + dir.Y * dist, Z = from.Z or 0 }
    return Grid.snap_to_land(p) or p
end
Bh.away_point = away_point

-- Decides and starts this tick's reaction. Returns true when the reaction
-- owns the squad's movement this tick (the activity machine then waits).
function Bh.react(director, group, now, sense, fighting)
    local t = Bh.tuning
    local S = director.S
    local mood, panicking = Bh.mood(group, now)
    group.mood = mood
    local list = alive(group)
    if #list == 0 then return false end

    -- A flight in progress runs its course.
    if group.flee_until and now < group.flee_until then
        group.mood = group.mood == "ROUT" and "ROUT" or "PANIC"
        return group.flee_move ~= false
    end
    group.flee_until, group.flee_move = nil, nil

    local threat_pos = nil
    if sense.zombies_close > 0 or sense.zombies_near > 0 then
        threat_pos = director.zombie_centroid
    elseif sense.noise and sense.noise_d < t.hear_near_uu * 2 then
        threat_pos = sense.noise.pos
    elseif group.last_contact and group.last_contact.position then
        threat_pos = group.last_contact.position
    end
    -- Hit with no enemy squad or zombie in sight: the shooter is most likely
    -- the player standing nearest.
    local shot_by_player = false
    if not threat_pos and group.hit_at and now - group.hit_at < 15 then
        local best, bd = nil, 20000
        for _, p in ipairs(director.players or {}) do
            local d = U.dist2d(p, group.position)
            if d < bd then best, bd = p, d end
        end
        if best then threat_pos, shot_by_player = best, true end
    end

    -- Panic and rout: the squad breaks and runs.
    if (mood == "PANIC" or mood == "ROUT") and threat_pos then
        local dest = away_point(group.position, threat_pos, t.flee_uu * (mood == "ROUT" and 1.6 or 1))
        group.flee_until = now + (mood == "ROUT" and 45 or 25)
        group.disengaged_until = now + 60
        group.act.state = S.RETREAT
        group.act.until_t = group.flee_until
        director:solve_route(group, dest, { prefer_roads = false, direct_max = 400000 })
        -- Every body runs for it, not just the leader.
        for _, m in ipairs(list) do
            if m.runtime_id and director.bridge.move_to then
                local spread = { X = dest.X + director.rng:range(-800, 800),
                                 Y = dest.Y + director.rng:range(-800, 800),
                                 Z = m.position and m.position.Z or 0 }
                director.bridge.move_to(m.runtime_id, spread, { direct = true, radius = 300 })
            end
        end
        group.flee_move = group.physical and true or false
        director.log_event("PANIC", group.gid, Bh.MOOD_FI[mood])
        return group.physical == true
    end

    if fighting then group.mood = "FIGHT"; return false end

    -- Under fire from a player: the steady take cover and face the shooter,
    -- (the fearful have already run, above).
    if shot_by_player and group.physical then
        group.mood = "COVER"
        group.hold_until = now + 12
        for _, m in ipairs(list) do
            if m.runtime_id and director.bridge.face then
                director.bridge.face(m.runtime_id, threat_pos)
                group.focused = true
            end
            m.action = "COVER"
        end
        return true
    end

    -- Zombies on top of a physical squad: stand and fight, or back off.
    if group.physical and sense.zombies_close > 0 then
        group.mood = "ZOMBIES"
        return Bh.fight_zombies(director, group, now, list)
    end

    -- Gunfire nearby with nobody to fight: curiosity against caution. One
    -- decision per burst of gunfire, not one per shot; squads working the
    -- same place as the shooters (Krsko's sweep teams) carry on, and so does
    -- a squad in the middle of a sweep.
    local same_place = sense.noise and sense.noise.poi and group.act.goal_poi
        and sense.noise.poi == group.act.goal_poi.id
    if sense.noise and not group.investigating and group.act.state ~= S.TRAVEL
        and not same_place and not group.act.sweep_dir
        and now - (group.noise_react_at or 0) >= 120 then
        group.noise_react_at = now
        local curious = mean(list, function(m) return Tr.trait(m, "curiosity") end)
        local cautious = mean(list, function(m) return Tr.trait(m, "cautiousness") end)
        local aggressive = mean(list, function(m) return Tr.trait(m, "aggression") end)
        local drive = curious * 0.5 + aggressive * 0.4 - cautious * 0.5 - (mean(list, function(m) return m.stress or 0 end)) * 0.6
        if drive > 0.12 and sense.noise_d <= t.investigate_uu then
            group.investigating = { pos = U.copy_vec(sense.noise.pos), until_t = now + 90 }
            director:solve_route(group, sense.noise.pos, { prefer_roads = false, direct_max = 400000 })
            group.act.state = S.PATROL
            group.act.until_t = now + 90
            group.mood = "INVESTIGATE"
            director.log_event("INVESTIGATE", group.gid, string.format("%.0f m", sense.noise_d / 100))
        elseif drive < -0.15 and sense.noise_d <= t.hear_near_uu * 2.5 then
            local dest = away_point(group.position, sense.noise.pos, t.flee_uu * 0.6)
            director:solve_route(group, dest, { prefer_roads = false, direct_max = 400000 })
            group.act.state = S.RETREAT
            group.act.until_t = now + 40
            group.flee_until = now + 30
            group.flee_move = false
            group.mood = "AVOID"
            director.log_event("AVOID", group.gid, string.format("%.0f m", sense.noise_d / 100))
        elseif sense.noise_d <= t.hear_near_uu * 2 then
            -- Undecided: stop, listen, wait for it to die down.
            group.hold_until = now + 20
            group.mood = "HOLD"
            director.log_event("HOLD", group.gid, string.format("%.0f m", sense.noise_d / 100))
        end
    end
    if group.investigating then
        if now > group.investigating.until_t then group.investigating = nil
        else group.mood = "INVESTIGATE" end
    end
    if group.hold_until and now < group.hold_until then
        group.mood = "HOLD"
        return true
    end
    return false
end

-- Members that keep their nerve shoot the nearest zombies; the rest back
-- away from them. Returns true: the squad holds its ground this tick.
function Bh.fight_zombies(director, group, now, list)
    local t = Bh.tuning
    local zombies = director.zombies_here or {}
    local fatigue = group.act and group.act.fatigue or 0
    for _, m in ipairs(list) do
        local courage = Tr.trait(m, "courage") * 0.5 + Tr.trait(m, "combatConfidence") * 0.3
            + (1 - (m.stress or 0)) * 0.4
        local mp = m.position or group.position
        local target, best = nil, math.huge
        for _, z in ipairs(zombies) do
            local d = U.dist2d(mp, z.pos)
            if d < best then target, best = z, d end
        end
        if target and courage >= 0.55 and best <= t.zombie_fire_uu then
            if m.runtime_id and director.bridge.face then director.bridge.face(m.runtime_id, target.pos) end
            if director.rng:chance(0.6) then
                if m.runtime_id and director.bridge.fire_once then director.bridge.fire_once(m.runtime_id) end
                Bh.noise(director, mp, "gunfire", 1)
                director.noises[#director.noises].from = group.gid
                local skill = math.max((m.skills or {}).rifle or 0, (m.skills or {}).pistol or 0)
                local p = 0.35 * (0.6 + skill) * Bh.accuracy(m, fatigue) * (1 - 0.5 * best / t.zombie_fire_uu)
                if director.rng:chance(U.clamp(p, 0.05, 0.85)) and director.bridge.damage_actor then
                    director.bridge.damage_actor(target.actor, director.rng:range(30, 60), m.runtime_id)
                    m.zombie_hits = (m.zombie_hits or 0) + 1
                    -- Hitting back steadies the nerves.
                    m.stress = U.clamp((m.stress or 0) - 0.03, 0, 1)
                    m.morale = U.clamp((m.morale or 0.6) + 0.01, 0, 1)
                end
            end
            m.action = "ATTACK"
        elseif target and best <= t.zombie_close_uu and m.runtime_id and director.bridge.move_to then
            -- The fearful back off from the one closest to them.
            local p = away_point(mp, target.pos, 1500)
            director.bridge.move_to(m.runtime_id, p, { direct = true, radius = 150 })
            m.action = "RETREAT"
        end
    end
    return true
end

return Bh
