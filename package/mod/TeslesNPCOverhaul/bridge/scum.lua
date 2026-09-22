-- The only file that talks to UE4SS and SCUM.
--
-- Everything here is wrapped: a missing class, a changed signature or a bad
-- object must degrade the subsystem, never kill the director tick. Each
-- capability reports OK / PENDING / DEGRADED so the live map can say what is
-- actually proven on this server instead of implying success.
local U = require("core.util")

local B = {}

B.health = {}
B.stats = { spawns = 0, spawn_fail = 0, moves = 0, move_reject = 0,
            despawns = 0, position_reads = 0 }

local CLASS_ROOT = "/Game/ConZ_Files/Characters/NPCs/Armed_NPCs/Blueprint/Drifter/"
local CONTROLLER_CLASSES = {
    "NPCDrifterAIController", "NPCGuardAIController", "ArmedNPCBaseAIController",
}
local ZOMBIE_CLASSES = { "BP_Puppet_C", "BP_Zombie_C", "PuppetCharacter" }

local world_cache = nil
-- Reflection scans are the expensive part of every tick. Each cache holds a
-- result for a short window so a busy world does not re-scan GUObjectArray
-- several times inside one frame.
local scan_cache = { players = { t = 0, v = {} }, zombies = {} }
local CATALOG_RETRY_SEC = 45
local aihelper_cache = nil
local controller_cache = setmetatable({}, { __mode = "k" })
local class_cache = {}
local handles = {}
local next_handle = 1

-- -------------------------------------------------------------- helpers ----

local function have(name) return type(_G[name]) == "function" end

-- Reflection scans are what made the engine call this mod a hung game thread.
-- FindAllOf walks the object array - 258,622 actors on this server - and it
-- costs the same walk whether or not the class exists. The tick runs on the
-- game thread, so a few of those in one tick is the difference between a five
-- millisecond tick and a server that misses its heartbeat for ten seconds.
--
-- So: at most one scan per tick, and a class that comes back empty is not asked
-- about again until its backoff expires. A class that is simply not in this
-- build is then asked about once every fifteen minutes instead of every tick.
local SCANS_PER_TICK = 1
local MISS_BACKOFF = { 5, 15, 60, 300, 900 }
local scan_budget = 0
local scan_misses = {}

B.api_errors = {}
B.scan = { calls = 0, skipped_budget = 0, skipped_backoff = 0,
           slowest_ms = 0, slowest_name = "" }

-- One line per distinct failing call site: the same error every tick tells us
-- nothing new, and the first one tells us everything.
local function note_api_error(where, err)
    if B.api_errors[where] then
        B.api_errors[where].count = B.api_errors[where].count + 1
        return false
    end
    B.api_errors[where] = { count = 1, err = tostring(err) }
    if B.on_api_error then pcall(B.on_api_error, where, tostring(err)) end
    return true
end
B.note_api_error = note_api_error

function B.begin_tick(now)
    scan_budget = SCANS_PER_TICK
    B.tick_now = now or os.time()
end

local function find_all(cname, now)
    now = now or B.tick_now or os.time()
    local m = scan_misses[cname]
    if m and now < m.next_try then
        B.scan.skipped_backoff = B.scan.skipped_backoff + 1
        return nil
    end
    if scan_budget <= 0 then
        B.scan.skipped_budget = B.scan.skipped_budget + 1
        return nil
    end
    scan_budget = scan_budget - 1
    B.scan.calls = B.scan.calls + 1

    local t0 = os.clock()
    local ok, list = pcall(function() return FindAllOf(cname) end)
    local ms = (os.clock() - t0) * 1000
    if ms > B.scan.slowest_ms then
        B.scan.slowest_ms, B.scan.slowest_name = ms, cname
    end
    if not ok then
        note_api_error("FindAllOf(" .. cname .. ")", list)
        list = nil
    end

    if list and #list > 0 then
        scan_misses[cname] = nil
        return list
    end
    local n = (m and m.misses or 0) + 1
    scan_misses[cname] = {
        misses = n,
        next_try = now + MISS_BACKOFF[math.min(n, #MISS_BACKOFF)],
    }
    return nil
end
B.find_all = find_all

local function set_health(key, status, detail)
    B.health[key] = { status = status, detail = detail or "" }
end

local function valid(o)
    if o == nil then return false end
    if type(o) ~= "userdata" and type(o) ~= "table" then return false end
    local ok, v = pcall(function() return o:IsValid() end)
    if ok then return v == true end
    return true
end

local function full_name(o)
    local ok, s = pcall(function() return o:GetFullName() end)
    if ok and type(s) == "string" then return s end
    return tostring(o)
end

local function vec(v)
    if not v then return nil end
    local x = tonumber(v.X) or tonumber(v.x)
    local y = tonumber(v.Y) or tonumber(v.y)
    local z = tonumber(v.Z) or tonumber(v.z)
    if not (x and y and z) then return nil end
    if x ~= x or y ~= y or z ~= z then return nil end
    -- SCUM never legitimately reports the world origin for a live actor.
    if math.abs(x) < 1 and math.abs(y) < 1 and math.abs(z) < 1 then return nil end
    return { X = x, Y = y, Z = z }
end

-- ------------------------------------------------------------- lifecycle ---

function B.available()
    return B._ready == true
end

function B.init(cfg)
    B.cfg = cfg or {}
    B._ready = false

    if not have("FindFirstOf") or not have("StaticFindObject") then
        set_health("ue4ssCore", "DEGRADED", "UE4SS Lua globals missing")
        return false, "NO_UE4SS"
    end
    set_health("ue4ssCore", "OK", "UE4SS Lua API present")

    local w = B.get_world()
    if w then
        set_health("scumAdapter", "OK", "world object resolved")
        B._ready = true
    else
        set_health("scumAdapter", "PENDING", "waiting for the server world")
    end
    B.refresh_catalog()
    return B._ready
end

function B.get_world()
    if world_cache and valid(world_cache) then return world_cache end
    for _, short in ipairs({ "ConZGameMode", "GameModeBase", "PlayerController" }) do
        local ok, o = pcall(function() return FindFirstOf(short) end)
        if ok and valid(o) then
            local okw, w = pcall(function() return o:GetWorld() end)
            if okw and valid(w) then
                world_cache = w
                return w
            end
        end
    end
    return nil
end

-- --------------------------------------------------------------- catalog ---

local function level_short(level)
    level = math.max(1, math.min(5, math.floor(tonumber(level) or 1)))
    return "BP_Drifter_Lvl_" .. tostring(level)
end

local function level_path(level, variant)
    local s = level_short(level)
    if variant then
        return CLASS_ROOT .. s .. "_" .. variant .. "." .. s .. "_" .. variant .. "_C"
    end
    return CLASS_ROOT .. s .. "." .. s .. "_C"
end

local function class_is_valid(c)
    if not valid(c) then return false end
    local n = full_name(c)
    return type(n) == "string" and n ~= "" and n:find("Drifter") ~= nil
end

-- Finds and caches the NPC classes this server actually exposes. The guide is
-- explicit that a catalog hit is not proof of a successful spawn, so this only
-- reports what was found.
function B.refresh_catalog()
    local found, missing = 0, {}
    for level = 1, 5 do
        for _, variant in ipairs({ false, "Radiation" }) do
            local key = level .. (variant or "")
            if not class_cache[key] then
                local path = level_path(level, variant or nil)
                local ok, c = pcall(function() return StaticFindObject(path) end)
                if ok and class_is_valid(c) then
                    class_cache[key] = c
                    found = found + 1
                elseif not variant then
                    -- Fall back to a live instance's class if the asset path
                    -- has moved between game versions.
                    local ok2, o = pcall(function() return FindFirstOf(level_short(level) .. "_C") end)
                    if ok2 and valid(o) then
                        local okc, c2 = pcall(function() return o:GetClass() end)
                        if okc and class_is_valid(c2) then
                            class_cache[key] = c2
                            found = found + 1
                        end
                    end
                end
            else
                found = found + 1
            end
        end
    end
    for level = 1, 5 do
        if not class_cache[tostring(level)] and not class_cache[level] then
            missing[#missing + 1] = "L" .. level
        end
    end
    B.catalog_found = found
    if found >= 5 then
        set_health("spawnCatalog", "OK", found .. " NPC classes resolved")
    elseif found > 0 then
        set_health("spawnCatalog", "DEGRADED",
            found .. " classes, missing " .. table.concat(missing, ","))
    else
        set_health("spawnCatalog", "PENDING", "no SCUM NPC class catalog yet")
    end
    return found
end

-- Assets load as the server finishes starting, so a catalog that was empty at
-- boot is not permanently empty. Rescan on a backoff until classes appear,
-- then stop: repeating a successful scan is pure game-thread cost.
function B.maybe_refresh_catalog(now)
    if (B.catalog_found or 0) >= 5 then return false end
    now = now or os.time()
    if B.catalog_next_scan and now < B.catalog_next_scan then return false end
    B.catalog_next_scan = now + CATALOG_RETRY_SEC
    local before = B.catalog_found or 0
    B.refresh_catalog()
    return (B.catalog_found or 0) > before
end

function B.class_for(level, variant)
    local key = math.max(1, math.min(5, math.floor(level or 1))) .. (variant or "")
    local c = class_cache[key]
    if c and valid(c) then return c end
    if variant then return B.class_for(level, nil) end
    return nil
end

local function get_aihelper()
    if aihelper_cache and valid(aihelper_cache) then return aihelper_cache end
    for _, path in ipairs({
        "/Script/AIModule.Default__AIBlueprintHelperLibrary",
        "/Script/AIModule.AIBlueprintHelperLibrary",
    }) do
        local ok, o = pcall(function() return StaticFindObject(path) end)
        if ok and valid(o) then aihelper_cache = o; return o end
    end
    local ok, o = pcall(function() return FindFirstOf("AIBlueprintHelperLibrary") end)
    if ok and valid(o) then aihelper_cache = o; return o end
    return nil
end

-- --------------------------------------------------------------- players ---

function B.player_positions()
    local now = os.time()
    local c = scan_cache.players
    if c.t and (now - c.t) < (B.cfg and B.cfg.PlayerScanIntervalSec or 2) then
        return c.v
    end
    local out = {}
    local list = find_all("ConZPlayerController", now) or find_all("PlayerController", now)
    if not list then
        -- Keep the previous answer rather than reporting an empty server: a
        -- skipped scan is not proof that nobody is online.
        return c.v or out
    end
    for _, pc in ipairs(list) do
        if valid(pc) then
            local okp, pawn = pcall(function() return pc:K2_GetPawn() end)
            if okp and valid(pawn) then
                local okl, loc = pcall(function() return pawn:K2_GetActorLocation() end)
                local v = okl and vec(loc) or nil
                if v then out[#out + 1] = v end
            end
        end
    end
    c.t, c.v = now, out
    return out
end

-- ------------------------------------------------------------- spawn/kill --

-- Returns the navigable ground height, or nil when it cannot be proven. The
-- caller must treat nil as "do not spawn here": an actor placed at a guessed
-- height falls, and a falling NPC is a failed spawn, not a live one.
local navsys_cache = nil
local function get_navsys()
    if navsys_cache and valid(navsys_cache) then return navsys_cache end
    local ok, nav = pcall(function() return FindFirstOf("NavigationSystemV1") end)
    if not ok then note_api_error("FindFirstOf(NavigationSystemV1)", nav); return nil end
    if not valid(nav) then return nil end
    navsys_cache = nav
    return nav
end

function B.ground_at(pos)
    local nav = get_navsys()
    if not nav then return nil end
    local okp, projected = pcall(function()
        local out = {}
        nav:K2_ProjectPointToNavigation(
            B.get_world(),
            { X = pos.X, Y = pos.Y, Z = pos.Z },
            out, nil, nil,
            { X = 600.0, Y = 600.0, Z = 4000.0 })
        return out
    end)
    if okp then
        local v = vec(projected)
        if v then return v.Z end
    end
    return nil
end

-- Spawns one NPC. Exactly one native attempt per request: a failed return does
-- not prove no actor was created, so retrying with a different signature risks
-- duplicates.
function B.spawn_npc(req)
    local world = B.get_world()
    if not world then
        set_health("physicalVirtualization", "PENDING", "no world object")
        return nil, "NO_WORLD"
    end
    local variant = req.variant
    local cls = B.class_for(req.level, variant)
    if not cls then
        set_health("physicalVirtualization", "PENDING", "NPC_CLASS_UNAVAILABLE")
        B.stats.spawn_fail = B.stats.spawn_fail + 1
        return nil, "NPC_CLASS_UNAVAILABLE"
    end
    local helper = get_aihelper()
    if not helper then
        B.stats.spawn_fail = B.stats.spawn_fail + 1
        return nil, "AI_HELPER_MISSING"
    end

    local pos = req.position
    local rot = { Pitch = 0, Yaw = (req.yaw or 0), Roll = 0 }
    local ok, actor = pcall(function()
        return helper:SpawnAIFromClass(world, cls, nil,
            { X = pos.X, Y = pos.Y, Z = pos.Z }, rot, true, nil)
    end)
    if not ok or not valid(actor) then
        B.stats.spawn_fail = B.stats.spawn_fail + 1
        set_health("physicalVirtualization", "DEGRADED",
            "spawn returned no actor: " .. U.json(tostring(actor)))
        return nil, "SPAWN_FAILED"
    end

    local h = next_handle
    next_handle = next_handle + 1
    handles[h] = { actor = actor, npcId = req.npcId, group = req.group,
                   spawned_at = os.time() }
    B.stats.spawns = B.stats.spawns + 1
    set_health("physicalVirtualization", "OK",
        B.stats.spawns .. " actors materialized this session")
    return h
end

function B.despawn(handle)
    local rec = handles[handle]
    if not rec then return false end
    local c = B.controller(rec.actor)
    if c then pcall(function() c:StopMovement() end) end
    pcall(function() rec.actor:K2_DestroyActor() end)
    handles[handle] = nil
    B.stats.despawns = B.stats.despawns + 1
    return true
end

function B.actor(handle)
    local rec = handles[handle]
    if rec and valid(rec.actor) then return rec.actor end
    return nil
end

function B.is_alive(handle)
    local a = B.actor(handle)
    if not a then return false end
    local ok, hp = pcall(function() return a.Health end)
    if ok and type(hp) == "number" then return hp > 0 end
    return true
end

-- Named actor_health, not health: B.health is the subsystem status table and
-- the two must never be confused at a call site.
function B.actor_health(handle)
    local a = B.actor(handle)
    if not a then return nil end
    local ok, hp = pcall(function() return a.Health end)
    if ok and type(hp) == "number" then return hp end
    return nil
end

function B.actor_position(handle)
    local a = B.actor(handle)
    if not a then return nil end
    local ok, loc = pcall(function() return a:K2_GetActorLocation() end)
    if ok then
        local v = vec(loc)
        if v then
            B.stats.position_reads = B.stats.position_reads + 1
            return v
        end
    end
    return nil
end

-- ------------------------------------------------------------- movement ----

function B.controller(actor)
    if not valid(actor) then return nil end
    local cached = controller_cache[actor]
    if cached and valid(cached) then return cached end

    local ok, c = pcall(function() return actor:GetController() end)
    if ok and valid(c) then
        controller_cache[actor] = c
        return c
    end
    -- Fallback: scan controller classes and match the possessed pawn.
    for _, cname in ipairs(CONTROLLER_CLASSES) do
        local list = find_all(cname)
        if list then
            for _, cand in ipairs(list) do
                if valid(cand) then
                    local okp, pawn = pcall(function() return cand:K2_GetPawn() end)
                    if okp and pawn == actor then
                        controller_cache[actor] = cand
                        return cand
                    end
                end
            end
        end
    end
    return nil
end

-- EPathFollowingRequestResult: 0 Failed, 1 AlreadyAtGoal, 2 RequestSuccessful.
local function accepted_result(r)
    local n = tonumber(r)
    if n == nil then
        local s = tostring(r or "")
        n = tonumber(s:match("%-?%d+") or "")
    end
    if n == nil then return true end     -- unknown return: assume issued
    return n == 1 or n == 2
end

function B.move_to(handle, dest)
    local a = B.actor(handle)
    if not a or not dest then return false end
    local c = B.controller(a)
    if not c then return false end
    local ok, res = pcall(function()
        return c:MoveToLocation(
            { X = dest.X, Y = dest.Y, Z = dest.Z },
            B.cfg.MoveAcceptanceRadiusUU or 220.0,
            true,     -- stop on overlap
            true,     -- use pathfinding
            true,     -- project destination to navigation
            true,     -- can strafe
            nil,      -- filter class
            true)     -- allow partial path: a reachable prefix beats refusing
    end)
    if not ok then
        B.stats.move_reject = B.stats.move_reject + 1
        return false
    end
    local good = accepted_result(res)
    if good then B.stats.moves = B.stats.moves + 1
    else B.stats.move_reject = B.stats.move_reject + 1 end
    return good
end

function B.move_to_actor(handle, target_handle)
    local a, t = B.actor(handle), B.actor(target_handle)
    if not (a and t) then return false end
    local c = B.controller(a)
    if not c then return false end
    local ok, res = pcall(function()
        return c:MoveToActor(t, B.cfg.FollowerAcceptanceRadiusUU or 320,
            true, true, true, nil, false)
    end)
    if not ok then return false end
    return accepted_result(res)
end

function B.stop(handle)
    local a = B.actor(handle)
    if not a then return false end
    local c = B.controller(a)
    if not c then return false end
    return (pcall(function() c:StopMovement() end))
end

function B.set_speed(handle, uu_per_sec)
    local a = B.actor(handle)
    if not a then return false end
    local ok = pcall(function()
        local mc = a.CharacterMovement
        if mc then
            mc.MaxWalkSpeed = uu_per_sec
        end
    end)
    return ok
end

-- --------------------------------------------------------------- sensing ---

-- Zombie positions are collected once per interval and then answered from the
-- cache for every group that asks, instead of one full scan per group.
local function zombie_positions()
    local now = os.time()
    local c = scan_cache.zombies
    if c.t and (now - c.t) < (B.cfg and B.cfg.ZombieScanIntervalSec or 4) then
        return c.v
    end
    -- No players online means no physical NPCs, so nothing can meet a zombie.
    if #B.player_positions() == 0 then
        c.t, c.v = now, {}
        return c.v
    end
    local out = {}
    for _, cname in ipairs(ZOMBIE_CLASSES) do
        local list = find_all(cname, now)
        if list and #list > 0 then
            for _, z in ipairs(list) do
                if valid(z) then
                    local okl, loc = pcall(function() return z:K2_GetActorLocation() end)
                    local v = okl and vec(loc) or nil
                    if v then out[#out + 1] = v end
                end
            end
            break
        end
    end
    c.t, c.v = now, out
    return out
end

function B.nearby_zombies(pos, radius)
    local total = 0
    for _, v in ipairs(zombie_positions()) do
        if U.dist2d(v, pos) <= radius then total = total + 1 end
    end
    return total
end

-- Building search needs engine support that has not been demonstrated on this
-- server yet. Rather than fake a result, the capability reports PENDING and
-- the director falls back to open-area behaviour.
function B.find_buildings(pos, radius)
    if not B.cfg.EnableBuildingSearch then
        set_health("buildingSearch", "PENDING", "disabled in config")
        return nil
    end
    local list = find_all("ConZBuilding")
    if not list or #list == 0 then
        set_health("buildingSearch", "PENDING",
            "waiting for live proof: building_discovery")
        return nil
    end
    local out = {}
    for _, b in ipairs(list) do
        if valid(b) then
            local okl, loc = pcall(function() return b:K2_GetActorLocation() end)
            local v = okl and vec(loc) or nil
            if v and U.dist2d(v, pos) <= radius then
                out[#out + 1] = { id = full_name(b), position = v, object = b }
            end
        end
    end
    if #out > 0 then
        set_health("buildingSearch", "DEGRADED",
            "buildings found; door + interior steps unproven")
    end
    return out
end

-- ------------------------------------------------------------ combat aim ---

function B.aim_at(handle, pos)
    local a = B.actor(handle)
    if not a or not pos then return false end
    local c = B.controller(a)
    if not c then return false end
    local ok = pcall(function()
        c:SetFocalPoint({ X = pos.X, Y = pos.Y, Z = pos.Z }, 2)
    end)
    if ok then
        set_health("physicalCombat", "DEGRADED",
            "aim issued; weapon fire and damage unverified")
    end
    return ok
end

function B.start_fire(handle)
    local a = B.actor(handle)
    if not a then return false end
    return (pcall(function() a:StartFire() end))
end

function B.stop_fire(handle)
    local a = B.actor(handle)
    if not a then return false end
    return (pcall(function() a:StopFire() end))
end

-- --------------------------------------------------------------- takeover --

-- Stops SCUM's own encounter logic from re-commanding an actor the director
-- owns. Two authorities fighting over one pawn is the other half of the
-- stutter problem; the path follower cannot fix that on its own.
function B.take_ownership(handle)
    local a = B.actor(handle)
    if not a then return false, "NO_ACTOR" end
    local done = {}
    local c = B.controller(a)
    if c then
        if pcall(function() c:StopMovement() end) then done[#done + 1] = "stop" end
        if pcall(function()
            local bt = c.BrainComponent
            if bt then bt:StopLogic("TeslesDirector") end
        end) then done[#done + 1] = "brain" end
    end
    if pcall(function() a.bIsEncounterManaged = false end) then
        done[#done + 1] = "encounter"
    end
    if #done == 0 then
        set_health("takeover", "PENDING", "waiting for a Tesles-owned physical actor")
        return false, "NOT_EXPOSED"
    end
    set_health("takeover", "OK", "director owns " .. table.concat(done, "+"))
    return true
end

function B.handle_count()
    local n = 0
    for _ in pairs(handles) do n = n + 1 end
    return n
end

set_health("brain", "OK", "initialized")
set_health("spawnCatalog", "PENDING", "not scanned yet")
set_health("physicalVirtualization", "PENDING", "no materialization proof yet")
set_health("takeover", "PENDING", "waiting for a Tesles-owned physical actor")
set_health("physicalCombat", "PENDING", "waiting for an armed Tesles-owned actor")
set_health("buildingSearch", "PENDING",
    "waiting for live proof: building_discovery, door_discovery, door_interaction, interior_navigation")

return B
