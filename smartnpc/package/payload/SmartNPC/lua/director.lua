-- SmartNPC :: director.lua
-- Population: discovery, squad formation, spawning, player tracking and the
-- virtual/physical bubble.
--
-- The director owns the NPC registry and decides which squads are simulated as
-- dots and which are driven as bodies.  It never touches movement itself - that
-- belongs to squad.lua (goals) and body.lua (commands).

local S = SMARTNPC
local U = S.util
local C = S.config
local W = S.world
local B = S.body
local T = S.traits
local Q = S.squad

local D = {}

local max, min, floor, abs = math.max, math.min, math.floor, math.abs

D.npcs = {}          -- key -> rec
D.squads = {}        -- id  -> squad
D.players = {}       -- list of {x,y,z,name}
D.npc_count = 0
D.stats = {}

local world_obj = nil
local aihelper = nil
local navsys = nil
local spawn_classes = {}      -- level -> UClass
local class_hits = {}
local last_spawn_at = 0
local discovery_round = 0

--------------------------------------------------------------------------
-- class discovery
--------------------------------------------------------------------------

-- Candidate pawn classes.  SCUM's armed NPC pawns derive from a shared base;
-- FindAllOf resolves subclasses too, so the first base name that returns
-- anything is enough.  The explicit Lvl names are the documented spawnables
-- (#SpawnArmedNPC BP_Drifter_Lvl_1 ... BP_Guard_Lvl_5).
local PAWN_CANDIDATES = {
    "ArmedNPCBase", "BP_ArmedNPCBase_C", "ArmedNPC", "BP_ArmedNPC_C",
    "ConZArmedNPC", "NPCBase", "BP_NPCBase_C",
    "BP_Drifter_Lvl_1_C", "BP_Drifter_Lvl_2_C", "BP_Drifter_Lvl_3_C",
    "BP_Drifter_Lvl_4_C", "BP_Drifter_Lvl_5_C",
    "BP_Guard_Lvl_1_C", "BP_Guard_Lvl_2_C", "BP_Guard_Lvl_3_C",
    "BP_Guard_Lvl_4_C", "BP_Guard_Lvl_5_C",
}

local SPAWNABLE_NAMES = {
    "BP_Drifter_Lvl_1_C", "BP_Drifter_Lvl_2_C", "BP_Drifter_Lvl_3_C",
    "BP_Drifter_Lvl_4_C", "BP_Drifter_Lvl_5_C",
    "BP_Guard_Lvl_1_C", "BP_Guard_Lvl_2_C", "BP_Guard_Lvl_3_C",
    "BP_Guard_Lvl_4_C", "BP_Guard_Lvl_5_C",
}

local active_pawn_classes = nil

local function find_all(name)
    local ok, list = pcall(function() return FindAllOf(name) end)
    if ok and type(list) == "table" then return list end
    return nil
end

function D.resolve_pawn_classes()
    if active_pawn_classes and #active_pawn_classes > 0 then return active_pawn_classes end
    local found = {}
    for _, name in ipairs(C.NPCClassNames or PAWN_CANDIDATES) do
        local list = find_all(name)
        local n = list and #list or 0
        class_hits[name] = n
        if n > 0 then found[#found + 1] = name end
    end
    if #found > 0 then
        active_pawn_classes = found
        U.log("director: NPC pawn classes in use -> " .. table.concat(found, ", "))
    end
    return found
end

--------------------------------------------------------------------------
-- world / helper objects
--------------------------------------------------------------------------

function D.world()
    if U.valid(world_obj) then return world_obj end
    local ok, w = pcall(function() return FindFirstOf("World") end)
    if ok and U.valid(w) then world_obj = w; return w end
    return nil
end

function D.aihelper()
    if U.valid(aihelper) then return aihelper end
    for _, p in ipairs({
        "/Script/AIModule.Default__AIBlueprintHelperLibrary",
        "/Script/AIModule.AIBlueprintHelperLibrary",
    }) do
        local ok, o = pcall(function() return StaticFindObject(p) end)
        if ok and U.valid(o) then aihelper = o; return o end
    end
    return nil
end

function D.navsys()
    if U.valid(navsys) then return navsys end
    for _, p in ipairs({
        "/Script/NavigationSystem.Default__NavigationSystemV1",
        "/Script/NavigationSystem.NavigationSystemV1",
    }) do
        local ok, o = pcall(function() return StaticFindObject(p) end)
        if ok and U.valid(o) then navsys = o; return o end
    end
    local ok, o = pcall(function() return FindFirstOf("NavigationSystemV1") end)
    if ok and U.valid(o) then navsys = o; return o end
    return nil
end

-- Project a map point onto the navmesh so spawned NPCs land on walkable ground
-- rather than inside a rock or 40 m above a field.
function D.project_to_nav(p)
    local nav = D.navsys()
    local world = D.world()
    if not nav or not world then return nil, "no-navsystem" end
    local extent = { X = 20000, Y = 20000, Z = 250000 }
    local point = { X = p.x, Y = p.y, Z = p.z or B.ground_at(p, 0) or 0 }
    local out = { X = 0, Y = 0, Z = 0 }

    local ok = pcall(function()
        return nav:K2_ProjectPointToNavigation(world, point, out, nil, nil, extent)
    end)
    if not ok then
        out = { X = 0, Y = 0, Z = 0 }
        ok = pcall(function()
            return nav:K2_ProjectPointToNavigation(world, point, out, nil, nil, extent, false)
        end)
    end
    if not ok then return nil, "projection-call-failed" end
    local v = U.vec(out)
    if not v or not U.pos_sane(v) then return nil, "projection-empty" end
    return { x = v.x, y = v.y, z = v.z + 60 }
end

--------------------------------------------------------------------------
-- registry
--------------------------------------------------------------------------

function D.forget(key)
    if D.npcs[key] then
        D.npcs[key] = nil
        D.npc_count = max(0, D.npc_count - 1)
    end
end

local function make_rec(actor)
    local key = U.key(actor)
    if not key then return nil end
    local pos = U.actor_pos(actor)
    if not U.pos_sane(pos) then return nil end
    local rec = {
        key = key,
        actor = actor,
        short = U.shortname(actor),
        pos = pos,
        pos_at = U.now(),
        gait = "walk",
        adopted_at = U.now(),
    }
    rec.class = rec.short:gsub("_C_%d+$", ""):gsub("_%d+$", "")
    return rec
end

--------------------------------------------------------------------------
-- discovery
--------------------------------------------------------------------------

function D.discover()
    discovery_round = discovery_round + 1
    local classes = D.resolve_pawn_classes()
    if #classes == 0 then
        if discovery_round % 10 == 1 then
            U.log("director: no armed NPC class found yet (server may still be loading)")
        end
        return 0
    end

    local seen, fresh = {}, {}
    for _, name in ipairs(classes) do
        local list = find_all(name)
        if list then
            for _, a in ipairs(list) do
                local key = U.key(a)
                if key and not seen[key] then
                    seen[key] = true
                    if not D.npcs[key] then
                        -- A newly constructed pawn is not usable yet; wait for it
                        -- to appear in a second scan with a sane transform.
                        local pos = U.actor_pos(a)
                        if U.pos_sane(pos) then
                            fresh[#fresh + 1] = a
                        end
                    else
                        D.npcs[key].seen_at = U.now()
                    end
                end
            end
        end
    end

    local added = 0
    for _, a in ipairs(fresh) do
        if D.npc_count >= C.MaxManagedNPCs then break end
        local rec = make_rec(a)
        if rec then
            D.npcs[rec.key] = rec
            D.npc_count = D.npc_count + 1
            rec.seen_at = U.now()
            added = added + 1
        end
    end

    if added > 0 then D.group_loose_npcs() end
    return added
end

-- Any managed NPC without a squad joins the nearest squad within reach, or
-- forms a new one.  This is how natively spawned NPCs enter the living world.
function D.group_loose_npcs()
    local loose = {}
    for _, rec in pairs(D.npcs) do
        if not rec.squad_id and U.valid(rec.actor) then loose[#loose + 1] = rec end
    end
    if #loose == 0 then return end

    for _, rec in ipairs(loose) do
        -- Only adopt what is actually in play.  An NPC far from every player is
        -- left to SCUM; we would have no way to make its body walk anyway.
        if not rec.squad_id and D.nearest_player_dist(rec.pos) < C.MaterializeDistanceUU then
            local host = nil
            for _, sq in pairs(D.squads) do
                -- A virtual squad must never gain a body: it is a dot on the map
                -- with no pawns by definition, and one stray member would leave
                -- an NPC standing in a field forever.
                if not sq.virtual and not sq.pending_spawn
                   and #sq.members < C.SquadSizeMax and sq.pos then
                    if U.dist2(sq.pos, rec.pos) < 6000 then host = sq; break end
                end
            end
            if not host then
                host = Q.new({ pos = rec.pos, native = true })
                D.squads[host.id] = host
                host.virtual = false
            end
            host:add_member(rec)
            host:refresh_pos()
        end
    end
end

--------------------------------------------------------------------------
-- players
--------------------------------------------------------------------------

local PLAYER_CLASSES = { "ConZPlayerController", "PlayerController" }
local player_pawn_cache = {}

function D.scan_players()
    local out = {}
    for _, cls in ipairs(PLAYER_CLASSES) do
        local list = find_all(cls)
        if list and #list > 0 then
            for _, pc in ipairs(list) do
                local pawn = U.resolve(U.get(pc, "Pawn", nil))
                if not pawn then
                    local ok, p = U.call(pc, "K2_GetPawn")
                    if ok then pawn = U.resolve(p) end
                end
                if pawn then
                    local pos = U.actor_pos(pawn)
                    if U.pos_sane(pos) then
                        B.learn_ground(pos)
                        out[#out + 1] = { x = pos.x, y = pos.y, z = pos.z, sector = W.sector(pos) }
                    end
                end
            end
            if #out > 0 then break end
        end
    end
    D.players = out
    return #out
end

function D.nearest_player_dist(p)
    if not p or #D.players == 0 then return math.huge end
    local best = math.huge
    for _, pl in ipairs(D.players) do
        local d = U.dist2sq(p, pl)
        if d < best then best = d end
    end
    return math.sqrt(best)
end

--------------------------------------------------------------------------
-- spawning
--------------------------------------------------------------------------

function D.harvest_spawn_class()
    -- The cheapest reliable source of a spawnable UClass is a pawn the game
    -- already created: ask an adopted NPC for its class.
    for _, rec in pairs(D.npcs) do
        local a = U.resolve(rec.actor)
        if a then
            local ok, cls = U.call(a, "GetClass")
            if ok and U.valid(cls) then
                local nm = U.shortname(cls)
                if not spawn_classes[nm] then
                    spawn_classes[nm] = cls
                end
            end
        end
    end
    -- Also try to resolve the documented spawnables directly.
    for _, nm in ipairs(SPAWNABLE_NAMES) do
        if not spawn_classes[nm] then
            local ok, o = pcall(function() return FindFirstOf(nm) end)
            if ok and U.valid(o) then
                local ok2, cls = U.call(o, "GetClass")
                if ok2 and U.valid(cls) then spawn_classes[nm] = cls end
            end
        end
    end
    local n = 0
    for _ in pairs(spawn_classes) do n = n + 1 end
    return n
end

function D.pick_spawn_class()
    local names = {}
    for nm in pairs(spawn_classes) do names[#names + 1] = nm end
    if #names == 0 then return nil end
    table.sort(names)
    return spawn_classes[names[U.rand_int(1, #names)]], names[1]
end

function D.spawn_one(pos)
    local helper = D.aihelper()
    local world = D.world()
    if not helper or not world then return nil, "no-helper" end
    local cls = D.pick_spawn_class()
    if not cls then return nil, "no-class" end

    local navp = D.project_to_nav(pos)
    local where = navp or { x = pos.x, y = pos.y, z = (B.ground_at(pos, nil) or 0) + 120 }

    local ok, res = pcall(function()
        return helper:SpawnAIFromClass(
            world, cls, nil,
            { X = where.x, Y = where.y, Z = where.z },
            { Pitch = 0, Yaw = U.rand_int(0, 359), Roll = 0 },
            true, nil)
    end)
    if not ok then return nil, "spawn-call-failed:" .. tostring(res) end
    local actor = U.resolve(res)
    if not actor then return nil, "spawn-returned-nothing" end
    return actor
end

-- Create one new squad somewhere far from every player.
function D.spawn_squad()
    local anchors = W.pois.anchors
    if #anchors == 0 then return false, "no-anchors" end

    local origin = nil
    for _ = 1, 25 do
        local a = U.pick(anchors)
        local p = W.random_point(a, 8000, 80000, W.main_component())
        if p and D.nearest_player_dist(p) > C.SpawnMinPlayerDistanceUU then
            origin = p
            break
        end
    end
    if not origin then return false, "no-safe-origin" end

    local arch = T.pick_archetype()
    local lo = max(C.SquadSizeMin, arch.size and arch.size[1] or C.SquadSizeMin)
    local hi = min(C.SquadSizeMax, arch.size and arch.size[2] or C.SquadSizeMax)
    local want = U.rand_int(lo, max(lo, hi))

    local sq = Q.new({ pos = origin, archetype = arch })
    sq.virtual = true
    sq.pending_spawn = want
    D.squads[sq.id] = sq
    S.telemetry.event("SPAWN_SQUAD", sq.id, string.format("%s x%d at %s",
        arch.label, want, W.sector(origin)))
    return true
end

-- Virtual squads carry a "pending_spawn" head-count.  Bodies are only created
-- at the moment the squad materialises, so an empty map costs nothing.
function D.materialize_squad(sq)
    local want = sq.pending_spawn or 0
    local created = 0
    for i = 1, want do
        if D.npc_count >= C.MaxManagedNPCs then break end
        local jitter = {
            x = sq.pos.x + U.rand_range(-600, 600),
            y = sq.pos.y + U.rand_range(-600, 600),
            z = sq.pos.z,
        }
        local actor, why = D.spawn_one(jitter)
        if actor then
            local rec = make_rec(actor)
            if rec then
                rec.owned = true
                D.npcs[rec.key] = rec
                D.npc_count = D.npc_count + 1
                rec.seen_at = U.now()
                sq:add_member(rec)
                created = created + 1
            end
        else
            sq.spawn_fail = (sq.spawn_fail or 0) + 1
            if sq.spawn_fail <= 2 then
                S.telemetry.event("SPAWN_FAIL", sq.id, tostring(why))
            end
            break
        end
    end
    if created > 0 then
        sq.pending_spawn = nil
        sq:on_materialize()
        return true
    end
    return false
end

--------------------------------------------------------------------------
-- body lifecycle
--------------------------------------------------------------------------

function D.destroy_actor(rec)
    local a = U.resolve(rec.actor)
    if not a then return true end
    local ok = select(1, U.call(a, "K2_DestroyActor"))
    if not ok then U.call(a, "Destroy") end
    return ok
end

-- Remove every body of a squad.  Pawns SmartNPC created are destroyed; pawns
-- the game created are only released, so SCUM keeps owning its own population.
function D.despawn_squad_bodies(sq)
    local n = 0
    for _, m in ipairs(sq.members) do
        B.release(m)
        if m.owned then D.destroy_actor(m) end
        D.forget(m.key)
        n = n + 1
    end
    sq.members = {}
    sq.leader = nil
    return n
end

--------------------------------------------------------------------------
-- bubble
--------------------------------------------------------------------------

function D.update_bubble(sq)
    if not sq.pos then return end
    local d = D.nearest_player_dist(sq.pos)
    sq.player_dist = d

    if sq.virtual then
        if d < C.MaterializeDistanceUU then
            if sq.pending_spawn then
                if C.SpawnOwnPopulation then D.materialize_squad(sq) end
            elseif sq:member_count() > 0 then
                sq:on_materialize()
            end
        end
    else
        if d > C.VirtualizeDistanceUU then
            local n = sq:member_count()
            sq:on_virtualize()
            D.despawn_squad_bodies(sq)
            if sq.native then
                -- A squad built out of the game's own NPCs simply dissolves when
                -- nobody is around; the same NPCs get picked up again next time
                -- a player comes near them.
                sq.dead = true
            else
                sq.pending_spawn = max(1, n)
            end
        end
    end
end

--------------------------------------------------------------------------
-- housekeeping
--------------------------------------------------------------------------

function D.cleanup()
    local dead = {}
    for id, sq in pairs(D.squads) do
        sq:remove_dead()
        local has_pending = (sq.pending_spawn or 0) > 0
        if sq.dead or (not has_pending and #sq.members == 0) then
            dead[#dead + 1] = id
        elseif sq.retiring and sq.virtual then
            -- Retire quietly, far from anybody, then let the population
            -- controller start a fresh squad elsewhere.
            if (sq.player_dist or math.huge) > C.SpawnMinPlayerDistanceUU then
                for _, m in ipairs(sq.members) do
                    B.release(m)
                    D.forget(m.key)
                end
                dead[#dead + 1] = id
                S.telemetry.event("RETIRE", id, "lifetime reached")
            end
        end
    end
    for _, id in ipairs(dead) do D.squads[id] = nil end

    -- drop registry entries whose actor is gone
    for key, rec in pairs(D.npcs) do
        if not U.valid(rec.actor) then D.forget(key) end
    end
end

function D.squad_count()
    local n = 0
    for _ in pairs(D.squads) do n = n + 1 end
    return n
end

-- Squads SmartNPC owns, i.e. the ones the population target applies to.
function D.owned_squad_count()
    local n = 0
    for _, sq in pairs(D.squads) do
        if not sq.native then n = n + 1 end
    end
    return n
end

function D.maintain_population()
    if not C.SpawnOwnPopulation then return end
    local now = U.now()
    if now - last_spawn_at < C.SpawnIntervalSec then return end
    last_spawn_at = now
    if D.harvest_spawn_class() == 0 then return end
    if D.owned_squad_count() >= C.TargetSquadCount then return end
    if D.npc_count >= C.MaxManagedNPCs then return end
    D.spawn_squad()
end

--------------------------------------------------------------------------
-- state persistence
--------------------------------------------------------------------------

-- State is a plain TSV, not JSON: it has to survive being written by one build
-- and read by the next, and a line-based format cannot be broken by key order.
function D.save_state()
    local lines = { "# SmartNPC state v1\tid\tarch\tx\ty\tz\tmembers\ttask" }
    for id, sq in pairs(D.squads) do
        if sq.pos and not sq.native then
            lines[#lines + 1] = table.concat({
                id,
                sq.archetype.id,
                string.format("%.0f", sq.pos.x),
                string.format("%.0f", sq.pos.y),
                string.format("%.0f", sq.pos.z or 0),
                tostring(sq:member_count() + (sq.pending_spawn or 0)),
                tostring(sq.task or "-"),
            }, "\t")
        end
    end
    U.write_atomic(S.DIR_STATE .. S.SEP .. "squads.tsv", table.concat(lines, "\n") .. "\n")
end

function D.restore_state()
    local txt = U.read_file(S.DIR_STATE .. S.SEP .. "squads.tsv")
    if not txt then return 0 end
    local n = 0
    for line in txt:gmatch("[^\r\n]+") do
        if line:sub(1, 1) ~= "#" then
            local f = {}
            for field in line:gmatch("[^\t]+") do f[#f + 1] = field end
            if #f >= 6 then
                local pos = { x = tonumber(f[3]), y = tonumber(f[4]), z = tonumber(f[5]) or 0 }
                local members = tonumber(f[6]) or C.SquadSizeMin
                if pos.x and pos.y and W.component(pos) ~= 0 then
                    local sq = Q.new({ pos = pos, archetype = T.archetype(f[2]) })
                    sq.virtual = true
                    sq.pending_spawn = math.max(C.SquadSizeMin,
                        math.min(C.SquadSizeMax, math.floor(members)))
                    D.squads[sq.id] = sq
                    n = n + 1
                    if n >= C.TargetSquadCount then break end
                end
            end
        end
    end
    if n > 0 then U.log("director: restored " .. n .. " squad positions from state") end
    return n
end

--------------------------------------------------------------------------
-- diagnostics
--------------------------------------------------------------------------

function D.diagnostics()
    local phys, virt = 0, 0
    for _, sq in pairs(D.squads) do
        if sq.virtual then virt = virt + 1 else phys = phys + 1 end
    end
    local moving, stalled, cmds = 0, 0, 0
    for _, rec in pairs(D.npcs) do
        if (rec.speed or 0) > 40 then moving = moving + 1 end
        stalled = stalled + (rec.stall_total or 0)
        cmds = cmds + (rec.move_commands or 0)
    end
    return {
        npcs = D.npc_count,
        squads = D.squad_count(),
        physical = phys,
        virtual = virt,
        players = #D.players,
        moving = moving,
        stalls = stalled,
        commands = cmds,
        ground = B.ground_samples(),
        classes = class_hits,
        spawnClasses = (function()
            local t = {}
            for k in pairs(spawn_classes) do t[#t + 1] = k end
            table.sort(t)
            return t
        end)(),
    }
end

return D
