-- Level of detail and the virtual <-> physical handover.
--
-- One fixed render circle around every player, on the map (2D, height does
-- not matter): a squad inside it is physical, a squad outside it is virtual.
-- No bands in between. The only guard is time: a squad that has just changed
-- state keeps it for a few seconds, so a squad walking along the edge does
-- not spawn and despawn every second.
--
-- The bands are not a visibility promise. Class availability, the spawn queue
-- and ground suitability all decide whether an actor actually appears, and
-- this module reports honestly when they do not.
local U = require("core.util")
local Grid = require("world.navgrid")
local GroupClasses = require("npc.groups")

local Ph = {}

Ph.tuning = {
    render_uu = 100000,           -- 1 km render circle around each player
    hold_sec = 30,                -- minimum time between state changes
    release_factor = 1.15,        -- bodies go only this much further out
    spawn_spacing_uu = 260,
    spawn_retry_sec = 25,
    -- One spawn per tick until this server has proven it can materialise an
    -- NPC at all. Class loading, physics, AI and replication all land on the
    -- game thread at once, and a burst of them is what stalls a tick.
    max_spawns_per_tick = 1,
    max_spawns_per_tick_proven = 5,
    require_ground_proof = true,
    max_physical_groups = 12,
    ground_probe_uu = 20000,
}

Ph.LOD = { PHYSICAL = "PHYSICAL", VIRTUAL = "VIRTUAL" }

-- Map distance to the nearest player. Height never counts: the render
-- circle is a circle on the map.
function Ph.nearest_player_distance(pos, players)
    if not (pos and players) or #players == 0 then return math.huge end
    local best = math.huge
    for _, p in ipairs(players) do
        local d = U.dist2d(pos, p)
        if d < best then best = d end
    end
    return best
end

-- The squad's distance is its closest member's (or its marker's).
function Ph.group_lod(group, players)
    local best = Ph.nearest_player_distance(group.position, players)
    for _, m in ipairs(group.members) do
        if m.alive and m.position then
            local d = Ph.nearest_player_distance(m.position, players)
            if d < best then best = d end
        end
    end
    local lod = best <= Ph.tuning.render_uu and Ph.LOD.PHYSICAL or Ph.LOD.VIRTUAL
    return lod, best
end

-- Inside the render circle: physical. Outside: virtual. A state younger than
-- hold_sec is kept.
function Ph.wants_physical(group, distance, now)
    -- A squad with bodies keeps them until it is clearly out of range (15 %
    -- further): at the very edge it was made and removed every 10 s, and
    -- the server crashed in one of those rounds (1.9.45).
    local limit = Ph.tuning.render_uu
    if group.physical then limit = limit * Ph.tuning.release_factor end
    local inside = distance <= limit
    if now and group.lod_changed_at and inside ~= (group.physical == true)
        and now - group.lod_changed_at < Ph.tuning.hold_sec then
        return group.physical == true
    end
    return inside
end

-- Ground position for one member of a materialising group: spread around the
-- group marker, on land, never stacked on the same spot.
function Ph.member_spawn_point(group, index, count)
    local base = group.position
    if not base then return nil end
    if count <= 1 then return Grid.snap_to_land(base) or base end
    local t = Ph.tuning
    local heading = (group.mv and group.mv.smooth_heading) or 0
    local ring = math.floor((index - 1) / 4)
    local slot = (index - 1) % 4
    local ang = heading + math.pi + (slot - 1.5) * 0.55
    local dist = t.spawn_spacing_uu * (1 + ring)
    local p = {
        X = base.X + math.cos(ang) * dist,
        Y = base.Y + math.sin(ang) * dist,
        Z = base.Z,
    }
    if not Grid.is_passable(p) then
        p = Grid.snap_to_land(p) or U.copy_vec(base)
        p.Z = base.Z
    end
    return p
end

-- Which SCUM body an NPC wears. Uniformed and trained archetypes use the
-- Guard bodies, everyone else the Drifter bodies; the variant follows where
-- the group is and what the NPC is. The bridge falls back to the plain body,
-- then to Drifter, when this build lacks a combination.
local GUARD_ARCHETYPES = {
    police = true, security = true, ex_military = true, veteran = true,
    bunker_specialist = true, elite = true,
}
function Ph.body_family(m, group)
    local cls = group and GroupClasses.get(group.class)
    if cls and cls.body then return cls.body end
    return GUARD_ARCHETYPES[m.archetype] and "Guard" or "Drifter"
end
function Ph.body_variant(group, m)
    if group.zone == "RADIATION" or m.archetype == "radiation_specialist"
        or group.class == "radiation_group" then
        return "Radiation"
    end
    local cls = GroupClasses.get(group.class)
    if cls and cls.variant then return cls.variant end
    -- A share of the class in the Abandoned Bunker body, fixed per NPC.
    if cls and cls.bunker_share and ((m.seed or m.id or 0) % 1000) / 1000 < cls.bunker_share then
        return "AbandonedBunker"
    end
    if group.class == "bunker_group" or m.archetype == "bunker_specialist" then
        return "AbandonedBunker"
    end
    return nil
end

-- SCUM ships the Radiation bodies for levels 3-5 and the AbandonedBunker
-- bodies for 4-5 only. Every radiation NPC must wear the hazmat body, so a
-- lower level NPC wears the lowest body of its variant; its own level and
-- skills are unchanged.
local VARIANT_MIN_LEVEL = { Radiation = 3, AbandonedBunker = 4 }
function Ph.body_level(level, variant)
    local lv = math.max(1, math.min(5, math.floor(tonumber(level) or 1)))
    local min = variant and VARIANT_MIN_LEVEL[variant]
    if min and lv < min then
        -- A bunker group keeps its plain low-level body; radiation never does.
        if variant == "Radiation" then return min end
    end
    return lv
end

-- Materialises a group through the bridge. Returns spawned, failed, reason.
function Ph.materialize(group, bridge, ctx)
    if not bridge or not bridge.available() then
        return 0, #group.members, "BRIDGE_UNAVAILABLE"
    end
    local now = ctx.now
    if group.spawn_retry_at and now < group.spawn_retry_at then
        return 0, 0, "BACKOFF"
    end

    local spawned, failed = 0, 0
    local last_reason = nil
    -- The wider budget is earned: only after this session has materialised an
    -- NPC successfully is it safe to ask for several in one tick.
    local budget = Ph.proven and Ph.tuning.max_spawns_per_tick_proven
                   or Ph.tuning.max_spawns_per_tick
    local alive = {}
    for _, m in ipairs(group.members) do
        if m.alive then alive[#alive + 1] = m end
    end

    -- One NPC at a time when the bridge asks for it: SCUM hands each NPC its
    -- weapon from a list set just before the spawn, so the next one waits
    -- until the last has its weapon.
    if bridge.spawn_ready then budget = math.min(budget, 1) end
    for i, m in ipairs(alive) do
        if budget <= 0 then break end
        if not m.materialized and bridge.spawn_ready and not bridge.spawn_ready() then break end
        if not m.materialized then
            local pos = Ph.member_spawn_point(group, i, #alive)
            local ground = bridge.ground_at and bridge.ground_at(pos) or nil
            -- No proven ground means the actor would be dropped from a guessed
            -- height. A falling NPC is a failed spawn dressed up as a live one,
            -- so refuse rather than place it.
            local grounded = ground ~= nil or not Ph.tuning.require_ground_proof
            if ground then pos.Z = ground end
            budget = budget - 1

            if not grounded then
                failed = failed + 1
                last_reason = "NO_GROUND_PROOF"
            else
                local variant = Ph.body_variant(group, m)
                local lo = ctx.loadout_for and ctx.loadout_for(m) or ctx.loadout
                local handle, err = bridge.spawn_npc({
                    weapons = lo and lo.Weapons or nil,
                    archetype = m.archetype,
                    level = Ph.body_level(m.level, variant),
                    position = pos,
                    group = group.gid,
                    npcId = m.npcId,
                    -- Radiation-zone groups get SCUM's hazmat body variant
                    -- where the server exposes it; the bridge falls back to
                    -- the plain class when it does not.
                    family = Ph.body_family(m, group),
                    variant = variant,
                    yaw = ctx.yaw,
                })
                if handle then
                    m.runtime_id = handle
                    m.materialized = true
                    m.position = U.copy_vec(pos)
                    m.spawned_at = now
                    spawned = spawned + 1
                    Ph.proven = true
                    -- Without this SCUM's own encounter logic keeps issuing
                    -- its own move orders and fights the director for the
                    -- same pawn.
                    if ctx.take_ownership and bridge.take_ownership then
                        bridge.take_ownership(handle)
                    end
                    -- The squad's own gear (config Loadouts), when set.
                    if lo and bridge.apply_loadout then
                        pcall(bridge.apply_loadout, handle, lo, group.gid .. "/" .. tostring(m.npcId))
                    end
                    if ctx.on_spawn then ctx.on_spawn(group, m, pos) end
                else
                    failed = failed + 1
                    last_reason = err or "SPAWN_FAILED"
                end
            end
        end
    end

    if failed > 0 and spawned == 0 then
        group.spawn_retry_at = now + Ph.tuning.spawn_retry_sec
        group.spawn_failures = (group.spawn_failures or 0) + 1
    else
        group.spawn_failures = 0
    end
    group.physical = spawned > 0 or Ph.physical_count(group) > 0
    return spawned, failed, last_reason
end

function Ph.physical_count(group)
    local n = 0
    for _, m in ipairs(group.members) do
        if m.alive and m.materialized then n = n + 1 end
    end
    return n
end

-- Releases actors but keeps every persistent fact. The group's marker takes
-- over from the last known actor position, so nothing teleports on handover.
function Ph.virtualize(group, bridge, ctx)
    local released = 0
    local sum_x, sum_y, sum_z, n = 0, 0, 0, 0
    for _, m in ipairs(group.members) do
        if m.materialized and m.runtime_id then
            local pos = bridge and bridge.actor_position and bridge.actor_position(m.runtime_id)
            if pos then
                m.position = U.copy_vec(pos)
                sum_x, sum_y, sum_z = sum_x + pos.X, sum_y + pos.Y, sum_z + pos.Z
                n = n + 1
            end
            if bridge and bridge.despawn then bridge.despawn(m.runtime_id) end
            m.runtime_id = nil
            m.native_fight, m.fight_far_since = nil, nil
            m.materialized = false
            released = released + 1
        end
    end
    if n > 0 then
        group.position = { X = sum_x / n, Y = sum_y / n, Z = sum_z / n }
    end
    group.physical = false
    if ctx and ctx.on_virtualize then ctx.on_virtualize(group, released) end
    return released
end

-- Reads actor positions back so the live map shows where the character
-- really is, not where the director thinks it should be.
function Ph.sync_positions(group, bridge)
    if not (bridge and bridge.actor_position) then return false end
    local sum_x, sum_y, sum_z, n = 0, 0, 0, 0
    local lost = {}
    for _, m in ipairs(group.members) do
        if m.materialized and m.runtime_id then
            if bridge.is_alive and not bridge.is_alive(m.runtime_id) then
                lost[#lost + 1] = m
            else
                local pos = bridge.actor_position(m.runtime_id)
                if pos then
                    m.position = U.copy_vec(pos)
                    sum_x, sum_y, sum_z = sum_x + pos.X, sum_y + pos.Y, sum_z + pos.Z
                    n = n + 1
                end
                if bridge.actor_health then
                    local hp = bridge.actor_health(m.runtime_id)
                    if hp then m.health = hp end
                end
            end
        end
    end
    if n > 0 then
        group.position = { X = sum_x / n, Y = sum_y / n, Z = sum_z / n }
    end
    return n > 0, lost
end

return Ph
