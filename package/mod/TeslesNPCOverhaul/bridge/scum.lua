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
-- Full names of the actors this mod spawned. Everything else of an armed NPC
-- class is SCUM's own encounter spawn and is removed by cleanup_vanilla.
local owned_names = {}
B.owned_names = owned_names

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

-- Breadcrumb for engine calls that change the world. The line is on disk
-- BEFORE the call is made, so when the server dies inside SCUM's own code the
-- file names the call that took it there. main.lua supplies the writer.
local crumb_ring = {}
local function crumb(text)
    crumb_ring[#crumb_ring + 1] = os.date("%H:%M:%S") .. "  " .. text
    if #crumb_ring > 12 then table.remove(crumb_ring, 1) end
    if B.write_crumbs then pcall(B.write_crumbs, crumb_ring) end
end
B.crumb = crumb

-- The island spans roughly +-1,000,000 UU. A pawn in the join transition, or a
-- struct read back wrong, reports numbers far outside that; acting on them
-- puts actors into the engine's spatial trees at 6e10 and worse.
local WORLD_LIMIT_UU = 1500000
local function sane(v)
    return v and math.abs(v.X) < WORLD_LIMIT_UU and math.abs(v.Y) < WORLD_LIMIT_UU
        and math.abs(v.Z) < 500000
end
B.sane = sane

function B.begin_tick(now)
    scan_budget = SCANS_PER_TICK
    B.tick_now = now or os.time()
end

local function find_all(cname, now, always)
    now = now or B.tick_now or os.time()
    local m = scan_misses[cname]
    if not always then
        if m and now < m.next_try then
            B.scan.skipped_backoff = B.scan.skipped_backoff + 1
            return nil
        end
        if scan_budget <= 0 then
            B.scan.skipped_budget = B.scan.skipped_budget + 1
            return nil
        end
        scan_budget = scan_budget - 1
    end
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
    if always then return nil end
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

-- Two bodies, as in the build's own #SpawnArmedNPC list: BP_Drifter_Lvl_N and
-- BP_Guard_Lvl_N, each with the same variants - plain for levels 1-5,
-- Radiation for 3-5, AbandonedBunker for 4-5.
local FAMILIES = { "Drifter", "Guard" }
local ARMED_ROOT = "/Game/ConZ_Files/Characters/NPCs/Armed_NPCs/Blueprint/"
-- The Drifter folder is proven. The Guard folder is not: the candidates are
-- tried once, on the level 1 class, and the first that loads is kept for the
-- whole family.
local FOLDER_CANDIDATES = {
    Drifter = { "Drifter/" },
    Guard = { "Guard/", "Guards/", "Drifter/", "", "Guard_NPC/", "Bunker_Guard/" },
}
local family_folder = { Drifter = "Drifter/" }
local family_dead = {}

local function clamp_level(level)
    return math.max(1, math.min(5, math.floor(tonumber(level) or 1)))
end

local function short_name(family, level, variant)
    local s = "BP_" .. family .. "_Lvl_" .. clamp_level(level)
    if variant then s = s .. "_" .. variant end
    return s
end

local function class_path(family, level, variant, folder)
    local s = short_name(family, level, variant)
    return ARMED_ROOT .. folder .. s .. "." .. s .. "_C"
end

local function class_is_valid(c)
    if not valid(c) then return false end
    local n = full_name(c)
    return type(n) == "string" and (n:find("Drifter") ~= nil or n:find("Guard") ~= nil)
end

-- Finds, and if needed loads, the NPC classes. A Blueprint class is not in
-- memory until something uses it; LoadAsset (UE4SS, game thread only - where
-- the tick runs) loads the package, then the class is found by path. At most
-- one load per tick: each is disk and CPU work on the game thread.
local catalog_order = {}
for _, family in ipairs(FAMILIES) do
    for level = 1, 5 do catalog_order[#catalog_order + 1] = { family = family, level = level } end
    for level = 3, 5 do
        catalog_order[#catalog_order + 1] = { family = family, level = level, variant = "Radiation" }
    end
    for level = 4, 5 do
        catalog_order[#catalog_order + 1] = { family = family, level = level, variant = "AbandonedBunker" }
    end
end
local catalog_failed = {}

local function ckey(family, level, variant)
    return family .. clamp_level(level) .. (variant or "")
end

local function find_class(path)
    local ok, c = pcall(function() return StaticFindObject(path) end)
    if ok and class_is_valid(c) then return c end
    return nil
end

local function load_path(path, label)
    local c = find_class(path)
    if c then return c, "found" end
    if not have("LoadAsset") then return nil, "LoadAsset unavailable" end
    crumb("LoadAsset " .. path)
    local ok, err = pcall(function() LoadAsset(path) end)
    if not ok then note_api_error("LoadAsset(" .. label .. ")", err) end
    c = find_class(path)
    if c then return c, "loaded" end
    return nil, ok and "not found after load" or tostring(err)
end

local function load_class(family, level, variant)
    if family_dead[family] then return nil, family .. " folder not found" end
    local label = short_name(family, level, variant)
    local folder = family_folder[family]
    if folder then return load_path(class_path(family, level, variant, folder), label) end
    -- Folder unknown: probe the candidates with this class.
    for _, f in ipairs(FOLDER_CANDIDATES[family] or {}) do
        local c, how = load_path(class_path(family, level, variant, f), label)
        if c then
            family_folder[family] = f
            if B.on_catalog then pcall(B.on_catalog, family .. " folder", ARMED_ROOT .. f) end
            return c, how
        end
    end
    family_dead[family] = true
    return nil, "no " .. family .. " folder among " .. #(FOLDER_CANDIDATES[family] or {}) .. " candidates"
end

function B.refresh_catalog(max_loads)
    max_loads = max_loads or 1
    local loads = 0
    for _, e in ipairs(catalog_order) do
        local key = ckey(e.family, e.level, e.variant)
        local cached = class_cache[key]
        if not (cached and valid(cached)) and not catalog_failed[key] and loads < max_loads then
            loads = loads + 1
            local c, how = load_class(e.family, e.level, e.variant)
            if c then
                class_cache[key] = c
                if B.on_catalog then pcall(B.on_catalog, short_name(e.family, e.level, e.variant), how) end
            else
                catalog_failed[key] = how
                if B.on_catalog then
                    pcall(B.on_catalog, short_name(e.family, e.level, e.variant), "FAILED: " .. tostring(how))
                end
            end
        end
    end

    local found, missing, pending = 0, {}, 0
    for level = 1, 5 do
        if class_cache[ckey("Drifter", level)] then found = found + 1
        else missing[#missing + 1] = "L" .. level end
    end
    local guards = 0
    for level = 1, 5 do
        if class_cache[ckey("Guard", level)] then guards = guards + 1 end
    end
    for _, e in ipairs(catalog_order) do
        local key = ckey(e.family, e.level, e.variant)
        if not class_cache[key] and not catalog_failed[key] then pending = pending + 1 end
    end
    B.catalog_found = found
    B.catalog_pending = pending
    local detail = string.format("Drifter %d/5, Guard %d/5", found, guards)
    if found >= 5 and pending == 0 then
        set_health("spawnCatalog", guards >= 5 and "OK" or "DEGRADED", detail)
    elseif pending > 0 then
        set_health("spawnCatalog", "PENDING", detail .. ", " .. pending .. " still to load")
    else
        set_health("spawnCatalog", "DEGRADED", detail .. ", missing " .. table.concat(missing, ","))
    end
    return found
end

function B.maybe_refresh_catalog(now)
    if (B.catalog_pending or 1) == 0 then return false end
    local before = B.catalog_found or 0
    B.refresh_catalog(1)
    return (B.catalog_found or 0) > before
end

-- Picks the class for a request. A missing variant falls back to the plain
-- body of the same family, a missing family to Drifter: an NPC in the wrong
-- clothes beats no NPC.
-- The Blueprint classes are loaded at startup, but nothing in the world uses
-- them until the first spawn, and the engine's garbage collector frees an
-- unused class within a minute or two. The 1.4.0 log shows exactly that: all
-- twenty classes loaded at 17:06, the player joined at 17:08, ground was found
-- and not a single spawn was even attempted - every cached class had gone
-- invalid. A class that has gone is loaded again right when it is needed.
local reload_after = {}
B.class_reloads = 0
local function resolve_class(family, level, variant)
    local key = ckey(family, level, variant)
    local c = class_cache[key]
    if c and valid(c) then return c end
    if catalog_failed[key] then return nil end
    local known = false
    for _, e in ipairs(catalog_order) do
        if ckey(e.family, e.level, e.variant) == key then known = true break end
    end
    if not known then return nil end
    local now = os.time()
    if (reload_after[key] or 0) > now then return nil end
    reload_after[key] = now + 5
    local nc, how = load_class(family, level, variant)
    if nc then
        class_cache[key] = nc
        B.class_reloads = B.class_reloads + 1
        if B.on_debug and B.class_reloads <= 10 then
            pcall(B.on_debug, string.format("npc class %s reloaded (%s): the engine had freed it",
                short_name(family, level, variant), tostring(how)))
        end
        return nc
    end
    class_cache[key] = nil
    return nil
end

function B.class_for(level, variant, family)
    family = family or "Drifter"
    local c = resolve_class(family, level, variant)
    if c then return c, family, variant end
    if variant then return B.class_for(level, nil, family) end
    if family ~= "Drifter" then return B.class_for(level, nil, "Drifter") end
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

local join_seen = {}

function B.player_positions()
    local now = os.time()
    local c = scan_cache.players
    if c.t and (now - c.t) < (B.cfg and B.cfg.PlayerScanIntervalSec or 2) then
        return c.v
    end
    local out = {}
    -- Players are scanned every PlayerScanIntervalSec, always, outside the
    -- scan budget and without the empty-result backoff. With the backoff an
    -- empty server taught the bridge to wait up to 15 minutes before asking
    -- again, so a player who joined was not seen for that long - the reason
    -- the 1.2.0 log has no player line at all. The scan costs ~2 ms.
    local list = find_all("ConZPlayerController", now, true)
    if not list then
        c.t, c.v = now, out
        local shape = "0/0/0/0"
        if shape ~= B.last_player_shape then
            B.last_player_shape = shape
            if B.on_debug then pcall(B.on_debug, "player scan: no player controllers") end
        end
        return out
    end
    -- A player counts only after their pawn has stood at a sane position for
    -- JoinGraceSec. The server died the moment a player joined: during the
    -- join the controller exists while the pawn is still being built in the
    -- transition map, and that is no moment to spawn NPCs next to it.
    local grace = (B.cfg and B.cfg.JoinGraceSec) or 3
    local seen = {}
    local n_pc, n_pawn, n_sane = 0, 0, 0
    local sample = nil
    for _, pc in ipairs(list) do
        if valid(pc) then
            n_pc = n_pc + 1
            local okp, pawn = pcall(function() return pc:K2_GetPawn() end)
            if okp and valid(pawn) then
                n_pawn = n_pawn + 1
                local okl, loc = pcall(function() return pawn:K2_GetActorLocation() end)
                local v = okl and vec(loc) or nil
                if not sample then
                    sample = v and string.format("%.0f %.0f %.0f", v.X, v.Y, v.Z)
                             or ("unreadable: " .. tostring(okl and loc))
                end
                if sane(v) then
                    n_sane = n_sane + 1
                    -- Keyed by the controller's full name. tostring() of a
                    -- UE4SS object is the address of a fresh Lua wrapper on
                    -- every FindAllOf, so a key built from it never
                    -- survived one scan and the grace period never ended.
                    local key = full_name(pc)
                    seen[key] = true
                    local first = join_seen[key] or now
                    join_seen[key] = first
                    if now - first >= grace then out[#out + 1] = v end
                end
            end
        end
    end
    for key in pairs(join_seen) do
        if not seen[key] then join_seen[key] = nil end
    end
    -- Say what the scan saw whenever the answer changes, so "no players" can
    -- be told apart from "no pawn", "position unreadable" and "still in grace".
    local summary = string.format("player scan: %d controllers, %d pawns, %d in-world, %d counted%s",
        n_pc, n_pawn, n_sane, #out, sample and (" (first pawn at " .. sample .. ")") or "")
    local shape = n_pc .. "/" .. n_pawn .. "/" .. n_sane .. "/" .. #out
    if shape ~= B.last_player_shape then
        B.last_player_shape = shape
        if B.on_debug then pcall(B.on_debug, summary) end
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

-- The simulation is 2D: a virtual group's Z is 0. The island's ground is
-- tens of thousands of UU above that (the player stood at Z 36,726), and the
-- probe only searched +-4,000 UU around the given height, so every probe
-- missed and every spawn was refused as NO_GROUND_PROOF - the reason nothing
-- materialised next to a player in 1.1.7.
--
-- A group only materialises within a few hundred metres of a player, so the
-- nearest player's height is a good starting guess; the vertical search is
-- then +-30,000 UU, enough for any hill between the two.
local ground_logged = 0

local function height_hint(pos)
    if pos.Z and math.abs(pos.Z) > 1 then return pos.Z end
    local best, bd = nil, nil
    for _, p in ipairs(scan_cache.players.v or {}) do
        local dx, dy = p.X - pos.X, p.Y - pos.Y
        local d = dx * dx + dy * dy
        if not bd or d < bd then best, bd = p, d end
    end
    return best and best.Z or 20000
end

local kismet_cache = nil
local function get_kismet()
    if kismet_cache and valid(kismet_cache) then return kismet_cache end
    local ok, o = pcall(function()
        return StaticFindObject("/Script/Engine.Default__KismetSystemLibrary")
    end)
    if ok and valid(o) then kismet_cache = o; return o end
    return nil
end

-- Navigation projection, the precise answer, only works where the server has
-- built navmesh. On this server it had none next to the player: every probe in
-- the 1.1.8 log came back "no navmesh". SCUM builds navigation around AI that
-- already exists, so the first NPC of an area could never prove its ground.
--
-- The fallback asks the landscape directly: a visibility line trace straight
-- down from well above the guess. The terrain has collision whether or not it
-- has navmesh, and the NPC then generates navigation around itself.
local function nav_ground(pos, z0)
    local nav = get_navsys()
    if not nav then return nil, "no nav system" end
    local okp, projected, hit = pcall(function()
        local out = {}
        local r = nav:K2_ProjectPointToNavigation(
            B.get_world(),
            { X = pos.X, Y = pos.Y, Z = z0 },
            out, nil, nil,
            { X = 800.0, Y = 800.0, Z = 30000.0 })
        return out, r
    end)
    if not okp then return nil, "error: " .. tostring(projected) end
    if hit == false then return nil, "no navmesh" end
    local v = vec(projected)
    if sane(v) then return v.Z end
    return nil, "no navmesh"
end

local function trace_ground(pos, z0)
    local k = get_kismet()
    if not k then return nil, "no KismetSystemLibrary" end
    crumb(string.format("LineTraceSingle %.0f %.0f %.0f..%.0f", pos.X, pos.Y, z0 + 40000, z0 - 40000))
    local ok, out, hit = pcall(function()
        local o = {}
        local r = k:LineTraceSingle(
            B.get_world(),
            { X = pos.X, Y = pos.Y, Z = z0 + 40000 },
            { X = pos.X, Y = pos.Y, Z = z0 - 40000 },
            0,        -- TraceTypeQuery1 = Visibility
            false,    -- simple collision
            {},       -- nothing to ignore
            0,        -- no debug drawing
            o,        -- OutHit
            true,     -- ignore self
            { R = 0, G = 0, B = 0, A = 0 }, { R = 0, G = 0, B = 0, A = 0 },
            0)
        return o, r
    end)
    if not ok then return nil, "error: " .. tostring(out) end
    if hit == false then return nil, "trace hit nothing" end
    local p = vec(out.ImpactPoint) or vec(out.Location)
    if sane(p) then return p.Z + 60 end
    return nil, "trace result unreadable"
end

function B.ground_at(pos)
    if not sane(pos) then return nil end
    local z0 = height_hint(pos)
    crumb(string.format("K2_ProjectPointToNavigation %.0f %.0f %.0f", pos.X, pos.Y, z0))
    local z, why = nav_ground(pos, z0)
    local how = "navmesh"
    if not z then
        local why_nav = why
        z, why = trace_ground(pos, z0)
        how = "line trace (navmesh: " .. tostring(why_nav) .. ")"
    end
    if ground_logged < 6 and B.on_debug then
        ground_logged = ground_logged + 1
        pcall(B.on_debug, string.format("ground at %.0f %.0f from Z %.0f -> %s via %s",
            pos.X, pos.Y, z0, z and string.format("%.0f", z) or ("none: " .. tostring(why)), how))
    end
    return z
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
    local cls, used_family, used_variant = B.class_for(req.level, variant, req.family)
    if not cls then
        set_health("physicalVirtualization", "DEGRADED", "NPC_CLASS_UNAVAILABLE: "
            .. short_name(req.family or "Drifter", req.level, variant))
        B.stats.spawn_fail = B.stats.spawn_fail + 1
        return nil, "NPC_CLASS_UNAVAILABLE"
    end
    local helper = get_aihelper()
    if not helper then
        B.stats.spawn_fail = B.stats.spawn_fail + 1
        return nil, "AI_HELPER_MISSING"
    end

    local pos = req.position
    if not sane(pos) then
        B.stats.spawn_fail = B.stats.spawn_fail + 1
        return nil, "POSITION_OUT_OF_WORLD"
    end
    local rot = { Pitch = 0, Yaw = (req.yaw or 0), Roll = 0 }
    crumb(string.format("SpawnAIFromClass %s lvl %s at %.0f %.0f %.0f",
        tostring(req.variant or "base"), tostring(req.level), pos.X, pos.Y, pos.Z))
    local ok, actor = pcall(function()
        return helper:SpawnAIFromClass(world, cls, nil,
            { X = pos.X, Y = pos.Y, Z = pos.Z }, rot, true, nil)
    end)
    B.spawn_logged = (B.spawn_logged or 0) + 1
    if B.spawn_logged <= 5 and B.on_debug then
        pcall(B.on_debug, string.format("spawn %s L%s %s at %.0f %.0f %.0f -> %s",
            tostring(used_family), tostring(req.level), tostring(used_variant or "base"),
            pos.X, pos.Y, pos.Z,
            (ok and valid(actor)) and ("actor " .. full_name(actor))
            or ("FAILED: " .. tostring(actor))))
    end
    if not ok or not valid(actor) then
        B.stats.spawn_fail = B.stats.spawn_fail + 1
        set_health("physicalVirtualization", "DEGRADED",
            "spawn returned no actor: " .. U.json(tostring(actor)))
        return nil, "SPAWN_FAILED"
    end

    local h = next_handle
    next_handle = next_handle + 1
    local name = full_name(actor)
    owned_names[name] = true
    handles[h] = { actor = actor, npcId = req.npcId, group = req.group,
                   spawned_at = os.time(), name = name }
    B.stats.spawns = B.stats.spawns + 1
    set_health("physicalVirtualization", "OK",
        B.stats.spawns .. " actors materialized this session")
    return h
end

function B.despawn(handle)
    local rec = handles[handle]
    if not rec then return false end
    crumb("K2_DestroyActor h" .. tostring(handle))
    local c = B.controller(rec.actor)
    if c then pcall(function() c:StopMovement() end) end
    pcall(function() rec.actor:K2_DestroyActor() end)
    if rec.name then owned_names[rec.name] = nil end
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

-- opts.direct: walk straight at the point without asking for a navmesh path.
-- This server builds navigation only around AI that already exists, and the
-- 1.2.1 log shows every pathfinding request toward a route waypoint rejected.
-- The director only ever asks for short hops along a route that was already
-- checked against the terrain, so a straight walk is exactly what it wants.
function B.move_to(handle, dest, opts)
    opts = opts or {}
    local a = B.actor(handle)
    if not a or not dest then return false end
    local c = B.controller(a)
    if not c then return false end
    if not sane(dest) then return false end
    local direct = opts.direct == true
    crumb(string.format("MoveToLocation h%s %.0f %.0f %.0f%s", tostring(handle),
        dest.X, dest.Y, dest.Z, direct and " direct" or ""))
    local ok, res = pcall(function()
        return c:MoveToLocation(
            { X = dest.X, Y = dest.Y, Z = dest.Z },
            opts.radius or B.cfg.MoveAcceptanceRadiusUU or 150.0,
            false,          -- stop on overlap: no, followers brush each other
            not direct,     -- use pathfinding
            not direct,     -- project destination to navigation
            false,          -- can strafe: no, walk facing the way they go
            nil,            -- filter class
            true)           -- allow partial path
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
    crumb("take_ownership h" .. tostring(handle) .. " (StopMovement, StopLogic, bIsEncounterManaged)")
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

-- ------------------------------------------------------ vanilla cleanup --

-- Only the mod's own groups may walk the island. SCUM's encounter manager keeps
-- spawning its own armed NPCs next to players; no server setting turns those
-- off without also touching zombies, so they are removed here. One class is
-- scanned per interval (each FindAllOf walks the whole object array), only
-- while someone is online - with nobody online nothing is spawned anyway.
local VANILLA_CLASSES = { "ArmedNPCBaseAIController", "NPCDrifterAIController",
                          "NPCGuardAIController" }
for _, family in ipairs(FAMILIES) do
    for _, e in ipairs(catalog_order) do
        if e.family == family then
            VANILLA_CLASSES[#VANILLA_CLASSES + 1] = short_name(family, e.level, e.variant) .. "_C"
        end
    end
end
local vanilla = { i = 0, next_at = 0, miss = {} }
B.vanilla = { removed = 0, scans = 0 }

local function is_dead(a)
    local ok, hp = pcall(function() return a.Health end)
    return ok and type(hp) == "number" and hp <= 0
end

local function remove_foreign(obj, is_controller)
    local pawn, ctrl = obj, nil
    if is_controller then
        -- A controller: judge the pawn it drives.
        ctrl = obj
        local okp, p = pcall(function() return obj:K2_GetPawn() end)
        pawn = (okp and valid(p)) and p or nil
    end
    if pawn then
        if owned_names[full_name(pawn)] then return false end
        -- A corpse may be someone's loot; leave it to SCUM's own cleanup.
        if is_dead(pawn) then return false end
        crumb("vanilla cleanup: K2_DestroyActor " .. full_name(pawn))
        if ctrl then pcall(function() ctrl:StopMovement() end) end
        pcall(function() pawn:K2_DestroyActor() end)
        if ctrl then pcall(function() ctrl:K2_DestroyActor() end) end
        return true
    end
    return false
end

function B.cleanup_vanilla(now)
    if not (B.cfg and B.cfg.RemoveVanillaArmedNPCs) then
        set_health("vanillaCleanup", "PENDING", "disabled in config")
        return 0
    end
    now = now or os.time()
    if now < vanilla.next_at then return 0 end
    vanilla.next_at = now + (B.cfg.VanillaCleanupIntervalSec or 3)
    if #B.player_positions() == 0 then return 0 end

    -- Next class that is not resting after an empty scan. A class that is not
    -- loaded yet rests at most a minute: an encounter can load it any time.
    -- Once a controller base class has answered, it covers every armed NPC
    -- in one scan; the per-Blueprint rotation is only the fallback.
    local cname = vanilla.base
    for _ = 1, cname and 0 or #VANILLA_CLASSES do
        vanilla.i = vanilla.i % #VANILLA_CLASSES + 1
        local c = VANILLA_CLASSES[vanilla.i]
        if (vanilla.miss[c] or 0) <= now then cname = c break end
    end
    if not cname then return 0 end
    B.vanilla.scans = B.vanilla.scans + 1
    local list = find_all(cname, now, true)
    if not list then
        vanilla.miss[cname] = now + 60
        if vanilla.base == cname then vanilla.base = nil end
        return 0
    end
    if cname:find("Controller", 1, true) and not vanilla.base then vanilla.base = cname end
    local n = 0
    local is_controller = cname:find("Controller", 1, true) ~= nil
    for _, obj in ipairs(list) do
        if valid(obj) and remove_foreign(obj, is_controller) then n = n + 1 end
    end
    if n > 0 then
        B.vanilla.removed = B.vanilla.removed + n
        if B.on_debug then
            pcall(B.on_debug, string.format("vanilla cleanup: removed %d via %s (%d total)",
                n, cname, B.vanilla.removed))
        end
    end
    set_health("vanillaCleanup", "OK", string.format("%d SCUM armed NPCs removed, %d scans",
        B.vanilla.removed, B.vanilla.scans))
    return n
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
set_health("vanillaCleanup", "PENDING", "waiting for a player")
set_health("buildingSearch", "PENDING",
    "waiting for live proof: building_discovery, door_discovery, door_interaction, interior_navigation")

return B
