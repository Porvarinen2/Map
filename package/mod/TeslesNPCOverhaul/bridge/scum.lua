-- The only file that talks to UE4SS and SCUM.
--
-- Everything here is wrapped: a missing class, a changed signature or a bad
-- object must degrade the subsystem, never kill the director tick. Each
-- capability reports OK / PENDING / DEGRADED so the live map can say what is
-- actually proven on this server instead of implying success.
local U = require("core.util")
local Weapons = require("npc.weapons")

local B = {}

B.health = {}
B.stats = { spawns = 0, spawn_fail = 0, moves = 0, move_reject = 0,
            despawns = 0, position_reads = 0 }

local CONTROLLER_CLASSES = {
    "NPCDrifterAIController", "NPCGuardAIController", "ArmedNPCBaseAIController",
}

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
-- Object addresses of the same actors: a second key that does not depend on
-- a name string. In the 1.4.4 log the cleanup destroyed three of the mod's
-- own NPCs one second after they spawned.
local owned_addr = {}
B.owned_addr = owned_addr


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

-- UE4SS hands arrays back in several shapes: a Lua table, a TArray, or a
-- RemoteUnrealParam wrapping one (1.7.3's survey printed the wrapper itself).
local function to_list(x)
    local out = {}
    if x == nil then return out end
    if type(x) == "table" and x.get == nil and x.ForEach == nil then
        for i = 1, #x do out[#out + 1] = x[i] end
        return out
    end
    local okg, inner = pcall(function() return x:get() end)
    if okg and inner ~= nil and inner ~= x then x = inner end
    local okf = pcall(function()
        x:ForEach(function(_, elem)
            local oke, v = pcall(function() return elem:get() end)
            out[#out + 1] = oke and v or elem
        end)
    end)
    if not okf and type(x) == "userdata" then
        pcall(function() for i = 1, #x do out[#out + 1] = x[i] end end)
    end
    return out
end
B.to_list = to_list

local function unwrap(x)
    if x == nil then return nil end
    local ok, v = pcall(function() return x:get() end)
    if ok and v ~= nil then return v end
    return x
end
B.unwrap = unwrap

-- Every property of an object's own (non-engine) classes, with its value
-- where it is a plain value or an object - for learning how SCUM stores
-- things like an NPC's outfit.
local function dump_props(obj, out, label, stop_at)
    local okc, cls = pcall(function() return obj:GetClass() end)
    if not (okc and cls) then return end
    local depth = 0
    while cls and valid(cls) and depth < 10 do
        depth = depth + 1
        local cn = full_name(cls)
        if stop_at and cn:find(stop_at, 1, true) then break end
        out[#out + 1] = label .. " class " .. cn
        pcall(function()
            cls:ForEachProperty(function(p)
                local n = "?"
                pcall(function() n = p:GetFName():ToString() end)
                local pt = ""
                pcall(function() pt = p:GetClass():GetFName():ToString() end)
                local val = ""
                pcall(function()
                    local v = obj[n]
                    local tv = type(v)
                    if tv == "number" or tv == "boolean" or tv == "string" then val = tostring(v)
                    elseif v ~= nil then
                        local okf, fnm = pcall(function() return v:GetFullName() end)
                        if okf and type(fnm) == "string" then val = fnm
                        else
                            local okt, st = pcall(function() return v:ToString() end)
                            val = okt and tostring(st) or tostring(v)
                        end
                    end
                end)
                if #val > 160 then val = val:sub(1, 160) .. "..." end
                out[#out + 1] = string.format("  %s : %s = %s", n, pt, val)
            end)
        end)
        local oks, sup = pcall(function() return cls:GetSuperStruct() end)
        if not (oks and sup) then break end
        cls = sup
    end
end
B.dump_props = dump_props

local function fmt_value(v)
    local tv = type(v)
    if tv == "number" or tv == "boolean" or tv == "string" then return tostring(v) end
    if v == nil then return "nil" end
    local okf, fnm = pcall(function() return v:GetFullName() end)
    if okf and type(fnm) == "string" then return fnm end
    local okt, st = pcall(function() return v:ToString() end)
    if okt and st ~= nil then return tostring(st) end
    return tostring(v)
end

-- A data object dumped with its arrays and structs opened up (and the data
-- objects it points to), e.g. the NPC common data that holds the outfit list.
local SKIP_ASSET = { "SkeletalMesh ", "StaticMesh ", "Material", "Texture", "AkAudio", "Anim",
                     "Curve", "PhysicsAsset", "BlueprintGeneratedClass", "Class ", "Sound", "Particle" }
local function dump_field(out, indent, name, prop, v, depth, seen)
    if #out > 1500 then return end
    local pt = "?"
    pcall(function() pt = prop:GetClass():GetFName():ToString() end)
    if pt == "ArrayProperty" then
        local inner = nil
        pcall(function() inner = prop:GetInner() end)
        local items = {}
        pcall(function() v:ForEach(function(_, e) items[#items + 1] = unwrap(e) end) end)
        out[#out + 1] = string.format("%s%s : Array[%d]", indent, name, #items)
        if inner and depth < 5 then
            for i, e in ipairs(items) do
                if i > 40 then out[#out + 1] = indent .. "  ..."; break end
                dump_field(out, indent .. "  ", "[" .. (i - 1) .. "]", inner, e, depth + 1, seen)
            end
        end
    elseif pt == "StructProperty" then
        local st = nil
        pcall(function() st = prop:GetStruct() end)
        out[#out + 1] = string.format("%s%s : struct %s", indent, name, st and fmt_value(st) or "?")
        if st and depth < 5 then
            pcall(function()
                st:ForEachProperty(function(fp)
                    local fn = "?"
                    pcall(function() fn = fp:GetFName():ToString() end)
                    local fv = nil
                    pcall(function() fv = v[fn] end)
                    dump_field(out, indent .. "  ", fn, fp, fv, depth + 1, seen)
                end)
            end)
        end
    else
        local txt = fmt_value(v)
        if #txt > 200 then txt = txt:sub(1, 200) .. "..." end
        out[#out + 1] = string.format("%s%s : %s = %s", indent, name, pt, txt)
        if pt == "ObjectProperty" and depth < 3 and v ~= nil and valid(v) and not seen[txt] then
            local skip = txt:find("PersistentLevel", 1, true) ~= nil
            for _, k in ipairs(SKIP_ASSET) do if txt:sub(1, #k) == k then skip = true end end
            if not skip then
                seen[txt] = true
                B.dump_deep(v, out, indent .. "    ", depth + 1, seen)
            end
        end
    end
end
function B.dump_deep(obj, out, indent, depth, seen)
    seen = seen or {}
    indent = indent or ""
    local okc, cls = pcall(function() return obj:GetClass() end)
    if not (okc and cls) then return end
    local level = 0
    while cls and valid(cls) and level < 8 do
        level = level + 1
        local cn = full_name(cls)
        if cn:find("/Script/Engine.DataAsset", 1, true) or cn:find("/Script/CoreUObject.Object", 1, true)
            or cn:find("/Script/Engine.Actor", 1, true) then break end
        out[#out + 1] = indent .. "class " .. cn
        pcall(function()
            cls:ForEachProperty(function(p)
                local n = "?"
                pcall(function() n = p:GetFName():ToString() end)
                local v = nil
                pcall(function() v = obj[n] end)
                dump_field(out, indent .. "  ", n, p, v, depth or 0, seen)
            end)
        end)
        local oks, sup = pcall(function() return cls:GetSuperStruct() end)
        if not (oks and sup) then break end
        cls = sup
    end
end

local function address_of(o)
    local ok, a = pcall(function() return o:GetAddress() end)
    if ok and a then return tostring(a) end
    return nil
end
local function is_ours(o)
    if owned_names[full_name(o)] then return true end
    local a = address_of(o)
    return a ~= nil and owned_addr[a] == true
end
B.is_ours = is_ours

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
    -- The surface first: a navmesh probe with a tall search box snapped a
    -- map spawn to navigation deep under the ground (a bunker below a base)
    -- and the squad fell through the world (1.9.19). The navmesh is asked
    -- only when the trace finds nothing.
    local z, why = trace_ground(pos, z0)
    local how = "line trace"
    if not z then
        local why_tr = why
        z, why = nav_ground(pos, z0)
        how = "navmesh (line trace: " .. tostring(why_tr) .. ")"
    end
    if ground_logged < 30 and B.on_debug then
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
    -- The NPC's weapon, given before it exists (see B.preset_weapon).
    local wanted = nil
    if req.weapons and B.preset_weapon then
        local okp, w = pcall(B.preset_weapon, cls, req.weapons)
        if okp then wanted = w end
    end
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
    local addr = address_of(actor)
    if addr then owned_addr[addr] = true end
    B.last_spawn_at = os.time()
    handles[h] = { actor = actor, npcId = req.npcId, group = req.group,
                   spawned_at = os.time(), name = name, addr = addr, wanted = wanted }
    B.last_spawn = { handle = h, at = os.clock(), t = os.time() }
    B.stats.spawns = B.stats.spawns + 1
    if not B.api_dumped then pcall(B.dump_api_once, h) end
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
    B.pending_weapons[handle] = nil
    B.weapon_chosen[handle] = nil
    B.body_watch[handle] = nil
    -- Gear the mod put on this NPC goes with it.
    for _, x in ipairs(rec.extras or {}) do pcall(function() x:K2_DestroyActor() end) end
    if rec.name then owned_names[rec.name] = nil end
    if rec.addr then owned_addr[rec.addr] = nil end
    handles[handle] = nil
    B.stats.despawns = B.stats.despawns + 1
    return true
end

function B.actor(handle)
    local rec = handles[handle]
    if rec and valid(rec.actor) then return rec.actor end
    return nil
end

-- Is an NPC dead? SCUM's armed NPCs do not expose a plain Health number, so
-- 1.4.1 took every one of them for alive: two killed squad members stood up
-- again on the next materialise. Several signals are read; the first that
-- answers decides, and which one it was is logged once so the log proves it.
local death_logged = {}
local function note_death(how)
    if not death_logged[how] and B.on_debug then
        death_logged[how] = true
        pcall(B.on_debug, "npc death detected via " .. how)
    end
end

local function read_bool(a, name, as_method)
    local ok, v = pcall(function()
        if as_method then return a[name](a) end
        return a[name]
    end)
    if ok and type(v) == "boolean" then return v end
    return nil
end

function B.is_dead_actor(a)
    if not valid(a) then return true, "actor gone" end
    local v = read_bool(a, "IsDead", true)
    if v ~= nil then if v then return true, "IsDead()" end return false end
    v = read_bool(a, "IsAlive", true)
    if v ~= nil then if not v then return true, "IsAlive()" end return false end
    v = read_bool(a, "bIsDead")
    if v then return true, "bIsDead" end
    for _, prop in ipairs({ "Health", "CurrentHealth", "HP" }) do
        local ok, hp = pcall(function() return a[prop] end)
        if ok and type(hp) == "number" then
            if hp <= 0 then return true, prop .. " <= 0" end
            return false
        end
    end
    -- A ragdoll: the body mesh has gone to physics simulation.
    local okm, sim = pcall(function() return a.Mesh:IsSimulatingPhysics() end)
    if okm and sim == true then return true, "ragdoll mesh" end
    -- A dead pawn is unpossessed; a live one keeps its AI controller.
    local okc, c = pcall(function() return a:GetController() end)
    if okc and not valid(c) then return true, "no controller" end
    return false
end

function B.is_alive(handle)
    local rec = handles[handle]
    if not rec then return false end
    local dead, how = B.is_dead_actor(rec.actor)
    if dead then
        -- The first seconds after a spawn the pawn may not be possessed yet.
        if how == "no controller" and os.time() - (rec.spawned_at or 0) < 6 then return true end
        note_death(how)
        if rec.ghost and not rec.ghost.dropped and B.ghost_drop then pcall(B.ghost_drop, handle) end
        return false
    end
    return true
end

-- Named actor_health, not health: B.health is the subsystem status table and
-- the two must never be confused at a call site.
function B.actor_health(handle)
    local a = B.actor(handle)
    if not a then return nil end
    -- ArmedNPCBase keeps its health in _health (npc_api.txt, 1.4.5).
    for _, prop in ipairs({ "_health", "Health" }) do
        local ok, hp = pcall(function() return a[prop] end)
        if ok and type(hp) == "number" then return hp end
    end
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
-- An NPC in a fight with a player is SCUM's own again (see B.set_native):
-- the director's orders are held back until the fight is over.
local function in_native(handle)
    local rec = handles[handle]
    return rec ~= nil and rec.native == true
end
B.in_native = in_native

function B.move_to(handle, dest, opts)
    if in_native(handle) then return true end
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
    if in_native(handle) then return true end
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
    if in_native(handle) then return true end
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

-- Census of the characters around players: zombies, animals and anything
-- else SCUM has walking about. One scan of ConZCharacter (the base class of
-- every character in SCUM) per interval, classified by the object's path.
-- The first appearance of each class is logged, so the log tells exactly what
-- SCUM calls its zombies on this build. Earlier versions looked for three
-- guessed class names, found nothing, and no NPC ever felt a zombie.
local census_seen = {}
local function classify(name)
    local n = name:lower()
    if n:find("armed_npcs", 1, true) or n:find("armednpc", 1, true)
        or n:find("^bp_drifter_lvl") or n:find("^bp_guard_lvl") then return "npc" end
    if n:find("zombie", 1, true) or n:find("puppet", 1, true) then return "zombie" end
    if n:find("animal", 1, true) or n:find("wolf", 1, true) or n:find("bear", 1, true)
        or n:find("boar", 1, true) or n:find("deer", 1, true) or n:find("horse", 1, true)
        or n:find("goat", 1, true) or n:find("chicken", 1, true) or n:find("rabbit", 1, true)
        or n:find("donkey", 1, true) or n:find("cow", 1, true) or n:find("razorback", 1, true) then
        return "animal"
    end
    if n:find("prisoner", 1, true) or n:find("player", 1, true) then return "player" end
    return "other"
end
B.classify_character = classify

function B.census(now)
    now = now or os.time()
    local c = scan_cache.zombies
    if c.t and (now - c.t) < (B.cfg and B.cfg.ZombieScanIntervalSec or 4) then
        return c.v
    end
    local out = { zombie = {}, animal = {}, other = {} }
    local players = B.player_positions()
    if #players == 0 then
        c.t, c.v = now, out
        return out
    end
    local list = find_all("ConZCharacter", now, true)
    for _, o in ipairs(list or {}) do
        if valid(o) then
            local okl, loc = pcall(function() return o:K2_GetActorLocation() end)
            local v = okl and vec(loc) or nil
            if v then
                local near = false
                for _, p in ipairs(players) do
                    if U.dist2d(p, v) <= 35000 then near = true; break end
                end
                if near then
                    local name = full_name(o)
                    local kind = classify(name)
                    local cls = name:match("^(%S+)") or name
                    if not census_seen[cls] then
                        census_seen[cls] = true
                        local n = 0
                        for _ in pairs(census_seen) do n = n + 1 end
                        if n <= 25 and B.on_debug then
                            pcall(B.on_debug, "census: " .. cls .. " -> " .. kind)
                        end
                    end
                    if (kind == "zombie" or kind == "animal") and not B.is_dead_actor(o) then
                        table.insert(out[kind], { pos = v, actor = o })
                    end
                end
            end
        end
    end
    c.t, c.v = now, out
    return out
end

local function zombie_positions()
    local out = {}
    for _, z in ipairs(B.census().zombie) do out[#out + 1] = z.pos end
    return out
end

-- Zombies (with their actors) within radius of a point.
function B.zombies_near(pos, radius)
    local out = {}
    for _, z in ipairs(B.census().zombie) do
        if U.dist2d(z.pos, pos) <= radius then out[#out + 1] = z end
    end
    return out
end

-- Zombies and animals within radius of a point: { pos, kind }.
function B.creatures_near(pos, radius)
    local out = {}
    local c = B.census()
    for _, kind in ipairs({ "zombie", "animal" }) do
        for _, z in ipairs(c[kind] or {}) do
            if U.dist2d(z.pos, pos) <= radius then out[#out + 1] = { pos = z.pos, kind = kind } end
        end
    end
    return out
end

-- Damage to any actor the census found (a zombie, an animal).
function B.damage_actor(actor, amount, from_handle)
    if not valid(actor) then return false end
    local gs = StaticFindObject and (function()
        local ok, o = pcall(function() return StaticFindObject("/Script/Engine.Default__GameplayStatics") end)
        return ok and o or nil
    end)() or nil
    if not (gs and valid(gs)) then return false end
    local src = from_handle and B.actor(from_handle) or nil
    local inst = src and B.controller(src) or nil
    local ok = pcall(function() gs:ApplyDamage(actor, amount, inst, src, nil) end)
    return ok
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

-- SCUM's own combat AI for a fight with a player. The director keeps the
-- NPC's brain stopped so it walks the director's routes; with the brain
-- stopped it never aims or fires either. When a player comes within reach
-- of the NPC's weapon the brain is started again and SCUM's AI fights with
-- the weapon, magazine and weapon manual the NPC carries; when the player
-- is gone the director takes the NPC back.
-- Does the NPC see a spot: in front of it (within half_angle degrees of
-- where it faces) and with nothing solid between its eyes and the spot?
function B.sees(handle, target, half_angle)
    local a = B.actor(handle)
    if not a then return false end
    local p = nil
    pcall(function() p = vec(a:K2_GetActorLocation()) end)
    if not (p and sane(target)) then return false end
    local yaw = nil
    pcall(function() yaw = tonumber(a:K2_GetActorRotation().Yaw) end)
    if yaw then
        local ang = math.deg(math.atan(target.Y - p.Y, target.X - p.X))
        local diff = math.abs(((ang - yaw + 540) % 360) - 180)
        if diff > (half_angle or 60) then return false end
    end
    local k = get_kismet()
    if not k then return true end
    -- From just outside the NPC's own body towards the spot. No actor list
    -- to ignore: handing UE4SS an actor inside that list crashed the server
    -- (1.9.28, on join).
    local dx, dy = target.X - p.X, target.Y - p.Y
    local len = math.sqrt(dx * dx + dy * dy)
    if len < 1 then return true end
    local from = { X = p.X + dx / len * 80, Y = p.Y + dy / len * 80, Z = p.Z + 70 }
    local to = { X = target.X, Y = target.Y, Z = (target.Z or p.Z) + 40 }
    crumb(string.format("LineTraceSingle sees %.0f %.0f -> %.0f %.0f", from.X, from.Y, to.X, to.Y))
    local ok, out, hit = pcall(function()
        local o = {}
        local r = k:LineTraceSingle(B.get_world(), from, to, 0, false, {}, 0, o, true,
            { R = 0, G = 0, B = 0, A = 0 }, { R = 0, G = 0, B = 0, A = 0 }, 0)
        return o, r
    end)
    if not ok then return true end
    if hit == false then return true end
    local ip = vec(out.ImpactPoint) or vec(out.Location)
    if not sane(ip) then return true end
    local total = math.sqrt((to.X - from.X) ^ 2 + (to.Y - from.Y) ^ 2 + (to.Z - from.Z) ^ 2)
    local got = math.sqrt((ip.X - from.X) ^ 2 + (ip.Y - from.Y) ^ 2 + (ip.Z - from.Z) ^ 2)
    -- Hitting the player (or right next to them) is seeing them.
    return got >= total - 150
end

-- SCUM's own sight for an NPC handed a fight: as far as the mod's detection
-- (config NPCDetectRangeM) and only to the front (NPCViewAngleDeg). The
-- sight settings are plain values on the controller's sense configs; the
-- perception system reads them again on RequestStimuliListenerUpdate.
local sight_logged = false
local function tune_sight(a)
    local c = B.controller(a)
    if not c then return end
    local radius = (tonumber(B.cfg and B.cfg.NPCDetectRangeM) or 300) * 100
    local angle = tonumber(B.cfg and B.cfg.NPCViewAngleDeg) or 45
    local before = nil
    local function set(cfg)
        if not (cfg and valid(cfg)) then return end
        pcall(function()
            before = before or string.format("%.0f/%.0f/%.0f", cfg.SightRadius, cfg.LoseSightRadius,
                cfg.PeripheralVisionAngleDegrees)
        end)
        pcall(function() cfg.SightRadius = radius end)
        pcall(function() cfg.LoseSightRadius = radius + 2000 end)
        pcall(function() cfg.PeripheralVisionAngleDegrees = angle end)
    end
    local perc = nil
    pcall(function() perc = c.PerceptionComponent end)
    if perc and valid(perc) then
        pcall(function()
            perc.SensesConfig:ForEach(function(_, e)
                local cfg = unwrap(e)
                if cfg and valid(cfg) and full_name(cfg:GetClass()):find("Sight") then set(cfg) end
            end)
        end)
    end
    pcall(function() set(c._sightSenseConfigCombat) end)
    local upd = perc and valid(perc) and pcall(function() perc:RequestStimuliListenerUpdate() end)
    if not sight_logged then
        sight_logged = true
        B.loadout_note(string.format("NPC:n nako: ennen %s (sade/katoaa/kulma), nyt %.0f/%.0f/%.0f, paivitys %s",
            tostring(before), radius, radius + 2000, angle, tostring(upd)))
    end
end

function B.set_native(handle, on)
    local rec = handles[handle]
    local a = B.actor(handle)
    if not (rec and a) then return false end
    if (rec.native == true) == (on == true) then return true end
    local c = B.controller(a)
    local ok = false
    if on then
        if not rec.sight_tuned then
            rec.sight_tuned = true
            pcall(tune_sight, a)
        end
        pcall(function() c:ClearFocus(0) end)
        ok = pcall(function()
            local bt = c.BrainComponent
            if not pcall(function() bt:RestartLogic() end) then bt:StartLogic() end
        end)
        rec.native = true
        crumb("set_native h" .. tostring(handle) .. " on " .. tostring(ok))
    else
        rec.native = false
        pcall(function() c:StopMovement() end)
        ok = pcall(function() c.BrainComponent:StopLogic("TeslesDirector") end)
        crumb("set_native h" .. tostring(handle) .. " off " .. tostring(ok))
    end
    B.native_switches = (B.native_switches or 0) + 1
    return ok
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
    return (B.is_dead_actor(a))
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
        if is_ours(pawn) then return false end
        -- Last check against every live handle, by object identity.
        for _, rec in pairs(handles) do
            if rec.actor == pawn then return false end
        end
        -- A corpse may be someone's loot; leave it to SCUM's own cleanup.
        if is_dead(pawn) then return false end
        crumb("vanilla cleanup: K2_DestroyActor " .. full_name(pawn))
        B.vanilla_log = (B.vanilla_log or 0) + 1
        if B.vanilla_log <= 15 and B.on_debug then
            pcall(B.on_debug, "vanilla cleanup removes " .. full_name(pawn)
                .. " (mod owns " .. B.handle_count() .. " actors)")
        end
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
    -- Never right after one of our own spawns: a pawn that has just been
    -- created is the one most likely to be misjudged.
    if B.last_spawn_at and now - B.last_spawn_at < 8 then return 0 end
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

-- SCUM's behaviour tree restarts on its own (a perception event is enough),
-- and then two authorities steer one pawn - the zig-zag. Called every few
-- seconds per actor: a running brain is stopped again.
B.brain_restarts = 0
function B.keep_ownership(handle)
    local a = B.actor(handle)
    if not a then return false end
    local c = B.controller(a)
    if not c then return false end
    local ok, running = pcall(function()
        local bt = c.BrainComponent
        return bt and bt:IsRunning()
    end)
    if ok and running == true then
        pcall(function() c.BrainComponent:StopLogic("TeslesDirector") end)
        B.brain_restarts = B.brain_restarts + 1
        if B.brain_restarts <= 3 and B.on_debug then
            pcall(B.on_debug, "SCUM AI had restarted on h" .. tostring(handle) .. "; stopped again")
        end
        return true
    end
    return false
end

-- Follow another actor: the engine tracks the moving goal itself, so the
-- follower walks a continuous curve instead of hopping between points.
function B.follow(handle, target_handle, radius)
    if in_native(handle) then return true end
    local a, t = B.actor(handle), B.actor(target_handle)
    if not (a and t) then return false end
    local c = B.controller(a)
    if not c then return false end
    crumb("MoveToActor h" .. tostring(handle) .. " -> h" .. tostring(target_handle))
    local ok, res = pcall(function()
        return c:MoveToActor(t, radius or 300,
            false,   -- stop on overlap
            false,   -- no pathfinding: there is rarely navmesh out here
            false,   -- no strafing
            nil,
            true)
    end)
    if not ok then return false end
    return accepted_result(res)
end

-- Walking speed actually in effect, read back from the movement component.
function B.walk_speed(handle)
    local a = B.actor(handle)
    if not a then return nil end
    local ok, v = pcall(function() return a.CharacterMovement.MaxWalkSpeed end)
    if ok and type(v) == "number" then return v end
    return nil
end

-- ---------------------------------------------------------------- damage --

-- Damage between the mod's squads goes through the engine's own ApplyDamage,
-- so SCUM's character takes it like any other hit (and dies, drops loot,
-- ragdolls). Whether SCUM honours it is logged once.
local gameplay_statics = nil
local function get_statics()
    if gameplay_statics and valid(gameplay_statics) then return gameplay_statics end
    local ok, o = pcall(function()
        return StaticFindObject("/Script/Engine.Default__GameplayStatics")
    end)
    if ok and valid(o) then gameplay_statics = o; return o end
    return nil
end

function B.apply_damage(handle, amount, from_handle)
    local a = B.actor(handle)
    if not a then return false end
    local gs = get_statics()
    if not gs then return false end
    local src = from_handle and B.actor(from_handle) or nil
    local inst = src and B.controller(src) or nil
    crumb(string.format("ApplyDamage h%s %.0f", tostring(handle), amount))
    local ok, err = pcall(function()
        gs:ApplyDamage(a, amount, inst, src, nil)
    end)
    if not ok then note_api_error("ApplyDamage", err) end
    return ok
end

-- The last resort when a killed NPC's body will not die: it is removed, so no
-- dead man keeps walking.
B.kill_log = {}
function B.note_kill_result(how)
    if not B.kill_log[how] and B.on_debug then
        B.kill_log[how] = true
        pcall(B.on_debug, "npc kill: " .. how)
    end
end

-- Faces an actor at a point without moving it.
function B.face(handle, pos)
    if in_native(handle) then return true end
    local a = B.actor(handle)
    if not (a and pos) then return false end
    local c = B.controller(a)
    if not c then return false end
    return (pcall(function() c:SetFocalPoint({ X = pos.X, Y = pos.Y, Z = pos.Z }, 2) end))
end

function B.clear_focus(handle)
    if in_native(handle) then return true end
    local a = B.actor(handle)
    if not a then return false end
    local c = B.controller(a)
    if not c then return false end
    return (pcall(function() c:ClearFocus(2) end))
end

-- Tries the likely weapon-fire entry points once each and remembers which
-- one the engine accepts. Visual only: damage is applied separately.
local fire_fn = nil
local FIRE_CANDIDATES = {
    function(a) a:StartFire() end,
    function(a) a:Fire() end,
    function(a) a:FireWeapon() end,
    function(a) a.EquippedWeapon:StartFire() end,
    function(a) a:GetEquippedWeapon():StartFire() end,
}
function B.fire_once(handle)
    local a = B.actor(handle)
    if not a then return false end
    if fire_fn == false then return false end
    if fire_fn then return (pcall(fire_fn, a)) end
    for i, f in ipairs(FIRE_CANDIDATES) do
        if pcall(f, a) then
            fire_fn = f
            if B.on_debug then pcall(B.on_debug, "npc weapon fire works via candidate " .. i) end
            return true
        end
    end
    fire_fn = false
    if B.on_debug then pcall(B.on_debug, "npc weapon fire: no known entry point on this build") end
    return false
end

-- ------------------------------------------------------------- api dump ---

-- Writes what an NPC actor and its controller expose (functions and
-- properties whose names matter for movement, animation and combat) to
-- output/npc_api.txt, once per session. It is how the next version learns
-- SCUM's real names instead of guessing them.
local API_WORDS = { "move", "speed", "gait", "stance", "walk", "run", "sprint", "anim",
    "fire", "shoot", "weapon", "aim", "target", "enemy", "attack", "combat", "damage",
    "health", "dead", "die", "kill", "alive", "team", "faction", "hostile", "attitude",
    "perception", "sense", "state", "mode", "alert", "encounter", "behavior", "brain",
    "item", "inventory", "equip", "cloth", "wear", "slot", "gear", "loadout", "attach",
    "holster", "hand", "strip", "remove", "drop", "container", "backpack", "vest" }
local function interesting(name)
    local n = name:lower()
    for _, w in ipairs(API_WORDS) do if n:find(w, 1, true) then return true end end
    return false
end

local function dump_class(obj, out, label)
    local okc, cls = pcall(function() return obj:GetClass() end)
    if not (okc and cls and valid(cls)) then return end
    local depth = 0
    while cls and valid(cls) and depth < 12 do
        depth = depth + 1
        out[#out + 1] = label .. " class " .. full_name(cls)
        pcall(function()
            cls:ForEachFunction(function(f)
                local okn, n = pcall(function() return f:GetFName():ToString() end)
                if okn and n and interesting(n) then out[#out + 1] = "  fn   " .. n end
            end)
        end)
        pcall(function()
            cls:ForEachProperty(function(p)
                local okn, n = pcall(function() return p:GetFName():ToString() end)
                if okn and n and interesting(n) then out[#out + 1] = "  prop " .. n end
            end)
        end)
        local oks, sup = pcall(function() return cls:GetSuperStruct() end)
        if not (oks and sup and valid(sup)) then break end
        local sn = full_name(sup)
        if sn:find("/Script/Engine.Actor", 1, true) or sn:find("/Script/CoreUObject", 1, true) then break end
        cls = sup
    end
end

function B.dump_api_once(handle)
    if B.api_dumped or not B.write_file then return end
    local a = B.actor(handle)
    if not a then return end
    B.api_dumped = true
    local out = { "TESLES NPC OVERHAUL - SCUM NPC API (" .. os.date("%Y-%m-%d %H:%M:%S") .. ")" }
    dump_class(a, out, "pawn")
    local c = B.controller(a)
    if c then dump_class(c, out, "controller") end
    -- Components: inventory and equipment live in components on most UE
    -- characters, not on the pawn itself.
    pcall(function()
        local ac = StaticFindObject("/Script/Engine.ActorComponent")
        local comps = a:K2_GetComponentsByClass(ac)
        local seen = {}
        for i = 1, #comps do
            local comp = comps[i]
            local ok, cls = pcall(function() return comp:GetClass() end)
            local cn = ok and full_name(cls) or "?"
            if not seen[cn] then
                seen[cn] = true
                dump_class(comp, out, "component")
            end
        end
    end)
    pcall(B.write_file, "npc_api.txt", table.concat(out, "\n") .. "\n")
    if B.on_debug then pcall(B.on_debug, "npc api written: " .. #out .. " lines") end
end

-- -------------------------------------------------------------- loadouts ---

-- Custom gear for the mod's squads (config Loadouts). Every step reports to
-- output/npc_loadout.txt, because SCUM's own equipment calls are not known
-- yet: the first session with a loadout configured shows which step works.
--   1. find the item's class from its spawn name (#SpawnItem name)
--   2. spawn the item next to the NPC
--   3. hand it to the NPC through whichever equip call SCUM exposes
local loadout_log = {}
-- The header (what varusteet.lua configures) is written at boot and kept at
-- the top, so the file exists and says something even before any spawn.
B.loadout_header = B.loadout_header or {}
function B.write_loadout_log()
    if not B.write_file then return end
    local lines = {}
    for _, l in ipairs(B.loadout_header) do lines[#lines + 1] = l end
    lines[#lines + 1] = ""
    lines[#lines + 1] = "--- attempts ---"
    if #loadout_log == 0 then
        lines[#lines + 1] = "(none yet: no NPC with gear has materialised this session)"
    end
    for _, l in ipairs(loadout_log) do lines[#lines + 1] = l end
    pcall(B.write_file, "npc_loadout.txt", table.concat(lines, "\n") .. "\n")
end
local function lnote(text)
    loadout_log[#loadout_log + 1] = os.date("%H:%M:%S") .. "  " .. text
    if #loadout_log > 400 then table.remove(loadout_log, 1) end
    B.write_loadout_log()
end
B.loadout_note = lnote

local item_index = nil
local item_class_cache = {}
local function build_item_index()
    item_index = {}
    local n = 0
    local list = find_all("BlueprintGeneratedClass", nil, true) or {}
    for _, c in ipairs(list) do
        local name = full_name(c)
        local path = name:match("%s(%S+)$") or name
        if path:find("/Items/", 1, true) or path:find("/Weapons/", 1, true)
            or path:find("/Clothes/", 1, true) or path:find("/Cloth", 1, true) then
            local short = path:match("%.([^%.]+)$") or path
            short = short:gsub("_C$", ""):lower()
            item_index[short] = c
            item_index[short:gsub("^bp_", "")] = c
            n = n + 1
        end
    end
    lnote("item index: " .. n .. " loaded item classes")
end

-- Item classes learned from items seen in the world: spawn name (lower
-- case) -> object path of the class. The Blueprint class list cannot be
-- searched on this build (1.7.3: "loaded Blueprint classes: 0"), but every
-- item lying in the world, or spawned with #SpawnItem, tells its class. The
-- list is kept in output/item_classes.txt and read back at boot, so a class
-- learned once is known in later sessions too.
B.item_paths = B.item_paths or {}
local guess_failed = {}
local GUESS_FOLDERS = {
    "Clothes/Underwear_Pants", "Clothes/Tops_And_T_Shirts", "Clothes/Jackets_Coats",
    "Clothes/Footwear", "Clothes/Headgear", "Clothes/Helmets", "Clothes/Vests_Armor",
    "Clothes/Gloves", "Clothes/Masks", "Clothes/Backpacks", "Clothes/Belts",
    "Clothes/Ghillie_Suits/Military", "Clothes/Sweaters", "Clothes/Glasses", "Clothes",
    "Weapons/Ranged_Weapons", "Weapons/New_Melee", "Weapons",
    "Weapons/Weapon_Clips", "Weapons/Attachments/Scope", "Weapons/Attachments/Rail",
    "Ammunition",
}
-- LoadAsset wants the object path: /Game/.../Name.Name_C (as the NPC classes
-- are loaded). Up to 1.8.4 it got the package path only, which never loaded
-- anything: an item class was found only while one existed in the world.
local function load_item_class(op)
    local c = nil
    pcall(function() c = StaticFindObject(op) end)
    if c and valid(c) then return c end
    if not have("LoadAsset") then return nil end
    local pkg = op:match("^(.-)%.") or op
    local short = pkg:match("([^/]+)$") or ""
    for _, p in ipairs({ op, pkg .. "." .. short }) do
        pcall(function() LoadAsset(p) end)
        pcall(function() c = StaticFindObject(op) end)
        if c and valid(c) then return c end
    end
    return nil
end
local function remember_item_class(cls)
    local cn = full_name(cls)
    local path = cn:match("%s(%S+)$") or cn
    local short = (path:match("%.([^%.]+)$") or path):gsub("_C$", "")
    local key = short:lower()
    if B.item_paths[key] ~= path then
        B.item_paths[key] = path
        B.item_paths_dirty = true
        return true
    end
    return false
end

function B.learn_items(now)
    now = now or os.time()
    if B.learn_at and now < B.learn_at then return end
    B.learn_at = now + 30
    if #B.player_positions() == 0 then return end
    local learned = 0
    for _, base in ipairs({ "Item" }) do
        for _, it in ipairs(find_all(base, now, true) or {}) do
            local okc, cls = pcall(function() return it:GetClass() end)
            if okc and cls and valid(cls) and remember_item_class(cls) then learned = learned + 1 end
        end
    end
    if B.item_paths_dirty and B.write_file then
        B.item_paths_dirty = false
        local keys = {}
        for k in pairs(B.item_paths) do keys[#keys + 1] = k end
        table.sort(keys)
        local lines = {}
        for _, k in ipairs(keys) do lines[#lines + 1] = k .. "\t" .. B.item_paths[k] end
        -- Names SCUM does not have: kept so they are never searched again.
        local miss = {}
        for k in pairs(guess_failed) do if not k:find("^path:") and not B.item_paths[k] then miss[#miss + 1] = k end end
        table.sort(miss)
        for _, k in ipairs(miss) do lines[#lines + 1] = k .. "\t-" end
        pcall(B.write_file, "item_classes.txt", table.concat(lines, "\n") .. "\n")
    end
    if learned > 0 then lnote("learned " .. learned .. " item classes from the world (item_classes.txt)") end
end

function B.load_item_paths(text)
    for line in tostring(text or ""):gmatch("[^\r\n]+") do
        local k, p = line:match("^(%S+)\t(%S+)$")
        if k and p == "-" then guess_failed[k] = true
        elseif k then B.item_paths[k] = p end
    end
end

function B.find_item_class(spawn_name)
    local key = tostring(spawn_name):lower()
    local c = item_class_cache[key]
    if c and valid(c) then return c end
    local path = B.item_paths[key]
    if path then
        c = load_item_class(path)
        if c and valid(c) then
            item_class_cache[key] = c
            return c
        end
        if not guess_failed["path:" .. key] then
            guess_failed["path:" .. key] = true
            lnote(spawn_name .. ": known class path " .. path .. " would not load")
        end
    end
    -- Not seen in the world yet: SCUM keeps items in
    -- /Game/ConZ_Files/Items/<category>/<Name>.<Name>_C (item_classes.txt,
    -- 1.7.4), so the usual categories are tried once each.
    B.last_find_deferred = false
    if not guess_failed[key] and (B.probe_budget or 1) <= 0 then
        -- A class search costs failed LoadAsset calls (1.9.11: 18-22 s
        -- freezes when many NPCs asked at once). One new name per tick.
        B.last_find_deferred = true
        return nil
    end
    if not guess_failed[key] then
        B.probe_budget = (B.probe_budget or 1) - 1
        local name = tostring(spawn_name)
        -- Weapons and their parts live in a handful of folders (item_classes.txt
        -- of the test server): only those are tried for them.
        local folders = GUESS_FOLDERS
        local low = name:lower()
        if low:find("^magazine_") then folders = { "Weapons/Weapon_Clips" }
        elseif low:find("^weaponscope_") or low:find("^weaponsights_") then folders = { "Weapons/Attachments/Scope" }
        elseif low:find("^scoperail_") then folders = { "Weapons/Attachments/Rail" }
        elseif low:find("^[12]h_") then folders = { "Weapons/New_Melee", "Weapons" }
        elseif low:find("^weapon_") or low:find("bow") or low:find("spear") or Weapons.kind(name) then
            folders = { "Weapons/Ranged_Weapons", "Weapons", "Weapons/New_Melee" }
        end
        for _, folder in ipairs(folders) do
            local pkg = "/Game/ConZ_Files/Items/" .. folder .. "/" .. name
            local op = pkg .. "." .. name .. "_C"
            local found = load_item_class(op)
            if found and valid(found) then
                item_class_cache[key] = found
                remember_item_class(found)
                lnote(name .. ": class found at " .. op)
                return found
            end
        end
        guess_failed[key] = true
        B.item_paths_dirty = true
        lnote(name .. ": not found in " .. #folders .. " item folders - drop one with #SpawnItem so the mod learns it")
    end
    if not item_index then build_item_index() end
    c = item_index[key] or item_index["bp_" .. key]
    if c and valid(c) then
        item_class_cache[key] = c
        return c
    end
    return nil
end

local function spawn_actor(cls, pos, before_finish, rot, exact)
    local gs = get_statics()
    local world = B.get_world()
    if not (gs and world and cls) then return nil, "no statics/world/class" end
    local xf = { Rotation = rot or { X = 0, Y = 0, Z = 0, W = 1 },
                 Translation = { X = pos.X, Y = pos.Y, Z = pos.Z + (exact and 0 or 50) },
                 Scale3D = { X = 1, Y = 1, Z = 1 } }
    local ok, actor = pcall(function()
        local a = gs:BeginDeferredActorSpawnFromClass(world, cls, xf, 1, nil)
        -- Settings the item reads while it is made (e.g. InitialAmmo).
        if a and valid(a) and before_finish then pcall(before_finish, a) end
        if a and valid(a) then gs:FinishSpawningActor(a, xf) end
        return a
    end)
    if ok and valid(actor) then return actor end
    return nil, tostring(actor)
end

-- Equip calls tried in order; the first that the engine accepts is kept.
local EQUIP_CANDIDATES = {
    "EquipItem", "Server_EquipItem", "EquipItemFromInventory", "TryEquipItem",
    "AddItemToInventory", "Server_AddItemToInventory", "PutItemInHands",
    "Server_PutItemInHands", "WearItem", "Server_WearItem", "AutoEquip",
}
local equip_fn = nil
local function try_equip(pawn, item)
    if equip_fn then
        local ok = pcall(function() pawn[equip_fn](pawn, item) end)
        return ok, equip_fn
    end
    for _, fn in ipairs(EQUIP_CANDIDATES) do
        local ok = pcall(function() pawn[fn](pawn, item) end)
        if ok then
            equip_fn = fn
            lnote("equip call accepted: " .. fn)
            return true, fn
        end
    end
    return false
end

-- ------------------------------------------------------ outfit by mesh ---

-- SCUM's armed NPCs have no inventory: npc_api.txt (1.7.1) shows no equip or
-- item calls at all, and their clothes are parts of the character model. So
-- an outfit is put on by swapping model parts: the clothing item's own mesh
-- goes onto the NPC's matching mesh component (pants onto the legs part, and
-- so on). The game's asset registry tells where each item's mesh lives.
local asset_index = nil
local function fname(s)
    local ok, v = pcall(function() return FName(s) end)
    if ok then return v end
    return s
end
local function str(v)
    if v == nil then return "" end
    local ok, s2 = pcall(function() return v:ToString() end)
    if ok and type(s2) == "string" then return s2 end
    return tostring(v)
end

local function build_asset_index()
    asset_index = {}
    local ok, err = pcall(function()
        local helpers = StaticFindObject("/Script/AssetRegistry.Default__AssetRegistryHelpers")
        local reg = helpers:GetAssetRegistry()
        -- Skeletal meshes only: a few thousand entries, not the whole game.
        local t0 = os.clock()
        local out = {}
        local okc = pcall(function() reg:GetAssetsByClass(fname("SkeletalMesh"), out, false) end)
        if not okc or #out == 0 then
            out = {}
            reg:GetAssetsByPath(fname("/Game/ConZ_Files/Items"), out, true, false)
        end
        local n = 0
        for i = 1, #out do
            local ad = out[i]
            local okf, name, pkg, cls = pcall(function()
                return str(ad.AssetName), str(ad.PackageName), str(ad.AssetClass)
            end)
            if okf and name ~= "" then
                asset_index[#asset_index + 1] = { name = name, lname = name:lower(), package = pkg, class = cls }
                n = n + 1
            end
        end
        lnote(string.format("asset registry: %d assets indexed in %.0f ms", n, (os.clock() - t0) * 1000))
    end)
    if not ok then lnote("asset registry unavailable: " .. tostring(err)) end
end

-- Assets whose name contains the item name, e.g. Christmas_Pants_02 ->
-- SK_Christmas_Pants_02 (mesh), Christmas_Pants_02 (item class).
function B.find_assets(item)
    if not asset_index then build_asset_index() end
    local key = tostring(item):lower()
    local out = {}
    for _, a in ipairs(asset_index or {}) do
        if a.lname:find(key, 1, true) then out[#out + 1] = a end
        if #out >= 20 then break end
    end
    return out
end

-- The skeletal mesh parts of one actor: name, current mesh, component.
function B.mesh_parts(actor)
    local out = {}
    local an = full_name(actor)
    local list = find_all("SkeletalMeshComponent", nil, true) or {}
    for _, comp in ipairs(list) do
        local okw, owner = pcall(function() return comp:GetOwner() end)
        if okw and owner and full_name(owner) == an then
            local okn, nm = pcall(function() return comp:GetFName():ToString() end)
            local okm, mesh = pcall(function() return comp.SkeletalMesh end)
            out[#out + 1] = { comp = comp, name = okn and nm or "?",
                              mesh = (okm and mesh and valid(mesh)) and full_name(mesh) or "(none)" }
        end
    end
    return out
end

-- Which model part an item replaces, from words in its name.
local SLOTS = {
    { words = { "pants", "trouser", "jeans", "shorts", "skirt" }, parts = { "pant", "leg", "trouser", "lower", "bottom" } },
    { words = { "shirt", "jacket", "vest", "hoodie", "coat", "sweater", "tshirt", "top", "parka", "uniform" },
      parts = { "shirt", "torso", "upper", "jacket", "top", "chest", "body" } },
    { words = { "shoe", "boot", "sneaker", "sandal" }, parts = { "shoe", "boot", "feet", "foot" } },
    { words = { "hat", "cap", "helmet", "beanie", "hood", "beret" }, parts = { "hat", "head", "helmet", "cap", "hair" } },
    { words = { "glove" }, parts = { "glove", "hand" } },
    { words = { "mask", "balaclava", "goggle" }, parts = { "mask", "face" } },
    { words = { "backpack", "bag" }, parts = { "backpack", "bag", "back" } },
}
local function slot_parts(item)
    local l = tostring(item):lower()
    for _, sl in ipairs(SLOTS) do
        for _, w in ipairs(sl.words) do if l:find(w, 1, true) then return sl.parts end end
    end
    return nil
end

B.api_meshes_logged = false
local function wear_by_mesh(actor, item, label)
    local parts = B.mesh_parts(actor)
    if not B.api_meshes_logged then
        B.api_meshes_logged = true
        local lines = { "NPC model parts (" .. #parts .. "):" }
        for _, p in ipairs(parts) do lines[#lines + 1] = "  " .. p.name .. " = " .. p.mesh end
        lnote(table.concat(lines, "\n"))
    end
    local assets = B.find_assets(item)
    local mesh_asset = nil
    for _, a in ipairs(assets) do
        if a.class:find("SkeletalMesh", 1, true) then mesh_asset = a; break end
    end
    if not mesh_asset then
        local seen = {}
        for _, a in ipairs(assets) do seen[#seen + 1] = a.name .. " [" .. a.class .. "] " .. a.package end
        lnote(string.format("%s: %s - no skeletal mesh asset found; matches: %s", label, item,
            #seen > 0 and table.concat(seen, "; ") or "none"))
        return false
    end
    local path = mesh_asset.package .. "." .. mesh_asset.name
    local mesh = nil
    pcall(function() mesh = StaticFindObject(path) end)
    if not (mesh and valid(mesh)) and have("LoadAsset") then
        pcall(function() LoadAsset(path) end)
        pcall(function() mesh = StaticFindObject(path) end)
    end
    if not (mesh and valid(mesh)) then
        lnote(string.format("%s: %s - mesh %s would not load", label, item, path))
        return false
    end
    local want = slot_parts(item)
    local target = nil
    if want then
        for _, p in ipairs(parts) do
            local hay = (p.name .. " " .. p.mesh):lower()
            for _, w in ipairs(want) do
                if hay:find(w, 1, true) then target = p; break end
            end
            if target then break end
        end
    end
    if not target then
        lnote(string.format("%s: %s - mesh %s found, but no matching model part (slot %s)",
            label, item, path, want and table.concat(want, "/") or "unknown"))
        return false
    end
    local ok, err = pcall(function() target.comp:SetSkeletalMesh(mesh, true) end)
    if ok then
        lnote(string.format("%s: %s - worn: %s %s -> %s", label, item, target.name, target.mesh, path))
        return true
    end
    lnote(string.format("%s: %s - SetSkeletalMesh failed on %s: %s", label, item, target.name, tostring(err)))
    return false
end

B.wear_by_mesh = function(actor, item, label) return wear_by_mesh(actor, item, label) end

-- One-time survey of how SCUM dresses its NPCs, written to npc_loadout.txt:
-- the actors attached to the NPC (worn clothes are item actors in SCUM), the
-- item base classes that exist, and every loaded class whose name mentions
-- the configured items. The 1.7.2 log showed the NPC has a single mesh (the
-- prisoner body), so the clothes must be attached actors.
B.outfit_surveyed = false
function B.maybe_survey(now)
    if B.outfit_surveyed or not B.survey_handle or (now or os.time()) < (B.survey_at or 0) then return end
    local a = B.actor(B.survey_handle)
    if not a then B.survey_handle = nil; return end
    pcall(B.survey_outfit, a, B.survey_names)
end
-- What a character (NPC or player pawn) wears, as seen from Lua: the body
-- mesh's child components, attached actors, items owned by or attached to it,
-- its own properties, and the insides of the clothes items it owns.
local function inspect_character(actor, tag, lines, max_items)
    local an = full_name(actor)
    lines[#lines + 1] = tag .. " " .. an
    pcall(function() lines[#lines + 1] = "  class " .. full_name(actor:GetClass()) end)
    -- 0. What hangs off the body mesh.
    pcall(function()
        local mesh = actor.Mesh
        lines[#lines + 1] = "body mesh: " .. full_name(mesh) .. " = " .. full_name(mesh.SkeletalMesh)
        local out = {}
        local r = mesh:GetChildrenComponents(true, out)
        local kids = to_list(r)
        if #kids == 0 then kids = to_list(out) end
        lines[#lines + 1] = "body mesh children: " .. #kids
        for _, k0 in ipairs(kids) do
            local k = unwrap(k0)
            local nm, cl, m, ow, sock, mat = "?", "?", "", "", "", ""
            pcall(function() nm = k:GetFName():ToString() end)
            pcall(function() cl = full_name(k:GetClass()) end)
            pcall(function() m = full_name(k.SkeletalMesh) end)
            if m == "" or m == "nil" then pcall(function() m = full_name(k.StaticMesh) end) end
            pcall(function() ow = full_name(k:GetOwner()) end)
            pcall(function() sock = k:GetAttachSocketName():ToString() end)
            pcall(function() mat = full_name(k:GetMaterial(0)) end)
            lines[#lines + 1] = string.format("  %s [%s] mesh=%s mat0=%s socket=%s owner=%s",
                tostring(nm), tostring(cl), tostring(m), tostring(mat), tostring(sock), tostring(ow))
        end
    end)
    -- 1. Attached actors, asked two ways (UE4SS out-parameter styles differ).
    local attached = {}
    pcall(function()
        local out = {}
        local r = actor:GetAttachedActors(out, true)
        attached = to_list(r)
        if #attached == 0 then attached = to_list(out) end
    end)
    lines[#lines + 1] = "GetAttachedActors: " .. #attached
    for _, a0 in ipairs(attached) do
        local a = unwrap(a0)
        local sock = ""
        pcall(function() sock = a:GetAttachParentSocketName():ToString() end)
        lines[#lines + 1] = "  " .. full_name(a) .. (sock ~= "" and ("  @" .. sock) or "")
        pcall(function() lines[#lines + 1] = "    class " .. full_name(a:GetClass()) end)
    end
    -- 2. Item actors on or next to this character, by base class.
    local npos = nil
    pcall(function() npos = vec(actor:K2_GetActorLocation()) end)
    local worn = {}
    for _, base in ipairs({ "Item", "ClothesItem" }) do
        local list = find_all(base, nil, true)
        local n, mine = list and #list or 0, 0
        for _, it in ipairs(list or {}) do
            local okp, par = pcall(function() return it:GetAttachParentActor() end)
            local okw, own = pcall(function() return it:GetOwner() end)
            local ipos = nil
            pcall(function() ipos = vec(it:K2_GetActorLocation()) end)
            local near = npos and ipos and U.dist2d(npos, ipos) < 400
            local on = (okp and par and full_name(par) == an) or (okw and own and full_name(own) == an)
            if on or near then
                mine = mine + 1
                local sock = ""
                pcall(function() sock = it:GetAttachParentSocketName():ToString() end)
                lines[#lines + 1] = string.format("  [%s %s] %s @%s parent=%s owner=%s", base, on and "on" or "near",
                    full_name(it), sock, (okp and par) and full_name(par) or "-", (okw and own) and full_name(own) or "-")
                if base == "ClothesItem" and on then worn[#worn + 1] = it end
            end
        end
        lines[#lines + 1] = string.format("FindAllOf(%s): %d in world, %d on/near", base, n, mine)
    end
    -- 2b. The character's own properties (where the outfit is stored), and
    --     what a worn clothes item looks like inside.
    pcall(dump_props, actor, lines, tag, "/Script/Engine.Character")
    for i, it in ipairs(worn) do
        if i > (max_items or 1) then break end
        pcall(dump_props, it, lines, "CLOTHES", "/Script/Engine.Actor")
        -- The item's own mesh components, read from its properties (a scan
        -- of every mesh component in the world froze the server for 30 s).
        local comps = {}
        for _, pn in ipairs({ "Mesh", "_skeletalMeshComponent", "_characterMesh" }) do
            pcall(function()
                local c = it[pn]
                if not (c and valid(c)) then return end
                local m, vis, par = "", "", ""
                pcall(function() m = full_name(c.SkeletalMesh) end)
                pcall(function() if m == "" or m == "nil" then m = full_name(c.StaticMesh) end end)
                pcall(function() vis = tostring(c:IsVisible()) end)
                pcall(function() par = full_name(c:GetAttachParent()) end)
                comps[#comps + 1] = string.format("  %s = %s mesh=%s visible=%s parent=%s", pn, full_name(c), m, vis, par)
                pcall(dump_props, c, comps, "    " .. pn, "/Script/Engine.SceneComponent")
            end)
        end
        lines[#lines + 1] = "CLOTHES components: " .. #comps
        for _, l in ipairs(comps) do lines[#lines + 1] = l end
    end
    return worn
end
B.inspect_character = inspect_character

-- The player's own outfit, written to player_outfit.txt once a minute: put
-- the clothes on yourself and the file shows how SCUM stores worn clothes on
-- a character, to compare with the NPC survey in npc_loadout.txt.
B.player_survey_every = 120
local player_history = {}
function B.maybe_player_survey(now)
    now = now or os.time()
    if now - (B.player_survey_at or 0) < B.player_survey_every then return end
    B.player_survey_at = now
    if not B.write_file then return end
    local pawn = nil
    for _, pc in ipairs(find_all("ConZPlayerController", now, true) or {}) do
        local okp, p = pcall(function() return pc:K2_GetPawn() end)
        if okp and valid(p) then pawn = p; break end
    end
    if not pawn then return end
    local lines = {}
    local worn = {}
    pcall(B.log_player_weapon, pawn)
    local ok, w = pcall(inspect_character, pawn, "PLAYER", lines, 2)
    if ok and w then worn = w end
    local names = {}
    for _, it in ipairs(worn) do names[#names + 1] = (full_name(it):match("([%w_]+)_C_%d+") or full_name(it)) end
    player_history[#player_history + 1] = os.date("%H:%M:%S") .. "  " .. #names .. " clothes: " .. table.concat(names, ", ")
    while #player_history > 30 do table.remove(player_history, 1) end
    local head = { "PLAYER OUTFIT " .. os.date("%Y-%m-%d %H:%M:%S"), "--- clothes worn per scan ---" }
    for _, l in ipairs(player_history) do head[#head + 1] = l end
    head[#head + 1] = ""
    head[#head + 1] = "--- latest scan ---"
    pcall(B.write_file, "player_outfit.txt", table.concat(head, "\n") .. "\n" .. table.concat(lines, "\n") .. "\n")
end

function B.survey_outfit(actor, wanted)
    if B.outfit_surveyed then return end
    B.outfit_surveyed = true
    local lines = { "OUTFIT SURVEY" }
    pcall(inspect_character, actor, "NPC", lines, 1)
    -- 3. Item classes learned from the world so far, and the wanted ones.
    pcall(B.learn_items, 0)
    local n = 0
    for _ in pairs(B.item_paths) do n = n + 1 end
    lines[#lines + 1] = "item classes learned from the world: " .. n
    for _, w in ipairs(wanted or {}) do
        local p = B.item_paths[tostring(w):lower()]
        lines[#lines + 1] = "  " .. tostring(w) .. ": " .. (p or "not seen yet - drop one with #SpawnItem near you")
    end
    local shown = 0
    for k, p in pairs(B.item_paths) do
        if shown < 25 and (k:find("pants", 1, true) or k:find("shirt", 1, true)) then
            lines[#lines + 1] = "  e.g. " .. k .. " = " .. p
            shown = shown + 1
        end
    end
    lnote(table.concat(lines, "\n"))
end

local function keep_extra(handle, obj)
    local rec = handles[handle]
    if rec then
        rec.extras = rec.extras or {}
        rec.extras[#rec.extras + 1] = obj
    end
end

-- A clothing item worn on an NPC: the item is spawned, made the NPC's, and
-- its mesh is fastened to the NPC's body mesh and driven by the body's
-- skeleton (leader pose), so it moves with the NPC like worn clothing.
local function wear_item(a, handle, name, label, pos)
    local cls = B.find_item_class(name)
    if not cls then return false end
    local item, why = spawn_actor(cls, pos)
    if not item then
        lnote(string.format("%s: %s - spawn failed: %s", label, name, tostring(why)))
        return false
    end
    keep_extra(handle, item)
    pcall(function() item:SetOwner(a) end)
    pcall(function() item:SetActorEnableCollision(false) end)
    local body = nil
    pcall(function() body = a.Mesh end)
    if not (body and valid(body)) then
        lnote(string.format("%s: %s - NPC body mesh not reachable", label, name))
        return false
    end
    local meshes = {}
    pcall(function()
        local m = item._skeletalMeshComponent
        if m and valid(m) then meshes[1] = m end
    end)
    local steps = {}
    for _, m in ipairs(meshes) do
        pcall(function() m:SetSimulatePhysics(false) end)
        local att = pcall(function() m:K2_AttachToComponent(body, fname("None"), 2, 2, 2, false) end)
        local pose = pcall(function() m:SetLeaderPoseComponent(body, true) end)
            or pcall(function() m:SetMasterPoseComponent(body, true) end)
        local mn = "?"
        pcall(function() mn = full_name(m.SkeletalMesh) end)
        steps[#steps + 1] = string.format("%s attach=%s pose=%s", mn, tostring(att), tostring(pose))
    end
    if #meshes == 0 then
        -- No skeletal mesh: fasten the whole item to the body as it is.
        local att = pcall(function()
            item:K2_AttachToComponent(body, fname("pelvis"), 2, 2, 2, false)
        end)
        lnote(string.format("%s: %s - item has no skeletal mesh; attached whole item: %s", label, name, tostring(att)))
        return att
    end
    lnote(string.format("%s: %s - worn (%s)", label, name, table.concat(steps, "; ")))
    return true
end

-- ------------------------------------------------ weapon internals log ---
-- weapon_api.txt: every property (with value) and function of a weapon, a
-- magazine and a scope, once per class, plus the player's own loaded weapon -
-- how SCUM links a magazine and rounds to a weapon.
local weapon_api, weapon_api_seen = {}, {}
local function write_weapon_api()
    if B.write_file then pcall(B.write_file, "weapon_api.txt", table.concat(weapon_api, "\n") .. "\n") end
end
local function functions_of(obj, stop_at)
    local out = {}
    local okc, cls = pcall(function() return obj:GetClass() end)
    local depth = 0
    while okc and cls and valid(cls) and depth < 10 do
        depth = depth + 1
        local cn = full_name(cls)
        if stop_at and cn:find(stop_at, 1, true) then break end
        pcall(function()
            cls:ForEachFunction(function(f)
                pcall(function() out[#out + 1] = f:GetFName():ToString() end)
            end)
        end)
        local oks, sup = pcall(function() return cls:GetSuperStruct() end)
        if not (oks and sup) then break end
        cls = sup
    end
    return out
end
B.functions_of = functions_of
function B.log_weapon_api(obj, label, force)
    if not (obj and valid(obj)) or #weapon_api > 12000 then return end
    local key = ""
    pcall(function() key = full_name(obj:GetClass()) end)
    if weapon_api_seen[key] and not force then return end
    weapon_api_seen[key] = true
    weapon_api[#weapon_api + 1] = "=== " .. label .. " " .. full_name(obj) .. " (" .. os.date("%H:%M:%S") .. ")"
    pcall(dump_props, obj, weapon_api, "  props", "/Script/Engine.Actor")
    weapon_api[#weapon_api + 1] = "  functions: " .. table.concat(functions_of(obj, "/Script/Engine.Actor"), ", ")
    write_weapon_api()
end
local function items_owned_by(owner)
    local out, on = {}, full_name(owner)
    for _, it in ipairs(find_all("Item", nil, true) or {}) do
        local ok, o = pcall(function() return it:GetOwner() end)
        if ok and o and full_name(o) == on then out[#out + 1] = it end
    end
    return out
end
-- The player's weapon in hands, with whatever hangs on it (magazine, rail,
-- scope): SCUM's own way of putting them together.
local player_weapon_logged = false
function B.log_player_weapon(pawn)
    if player_weapon_logged then return end
    local w = nil
    pcall(function() w = pawn._itemInHands end)
    if not (w and valid(w)) then return end
    local parts = items_owned_by(w)
    if #parts == 0 then return end
    player_weapon_logged = true
    B.log_weapon_api(w, "PLAYER WEAPON", true)
    for _, it in ipairs(parts) do
        B.log_weapon_api(it, "PLAYER WEAPON PART", true)
        for _, sub in ipairs(items_owned_by(it)) do B.log_weapon_api(sub, "PLAYER WEAPON PART PART", true) end
    end
end

-- Puts an item on a weapon: spawned, owned by the weapon, fastened to the
-- weapon's mesh at the socket, then handed to whichever of the weapon's own
-- functions takes it (names found at run time, see weapon_api.txt).
local function weapon_mesh(w)
    local m = nil
    for _, pn in ipairs({ "_skeletalMeshComponent", "Mesh" }) do
        pcall(function() local c = w[pn]; if c and valid(c) and not m then m = c end end)
    end
    return m
end
-- SCUM's own call for fitting an attachment (magazine, scope) to a weapon:
-- Weapon:AddAttachmentOnServer(item) (1.9.x: the only one that took the
-- scope; the magazine was only tried with magazine-named calls).
local function call_ok(obj, fn, ...)
    local args = { ... }
    local ok, res = pcall(function() return obj[fn](obj, table.unpack(args)) end)
    return ok, res
end
local function num(obj, fn)
    local ok, v = call_ok(obj, fn)
    v = ok and unwrap(v) or nil
    return tonumber(v)
end
local function set_condition(item, share)
    if not share then return nil end
    local max = num(item, "GetMaxHealth") or 100
    local ok = call_ok(item, "SetHealth", max * share)
    return ok and math.floor(share * 100 + 0.5) or nil
end
local function put_on_weapon(w, name, label, pos, before_attach, before_finish)
    local cls = B.find_item_class(name)
    if not cls then return nil end
    local part = spawn_actor(cls, pos, before_finish)
    if not part then return nil end
    pcall(function() part:SetOwner(w) end)
    pcall(function() part:SetActorEnableCollision(false) end)
    if before_attach then pcall(before_attach, part) end
    local ok, err = call_ok(w, "AddAttachmentOnServer", part)
    B.log_weapon_api(part, "PART " .. name)
    return part, ok, err
end
-- A random share of a capacity: 30-90 %, at least one round.
local function some_rounds(cap)
    cap = math.floor(tonumber(cap) or 0)
    if cap <= 0 then return 0 end
    return math.max(1, math.min(cap, math.floor(cap * (0.3 + math.random() * 0.6) + 0.5)))
end
-- The rounds are given to the item while it is made (InitialAmmo, as SCUM's
-- own spawners do); should that leave it empty, SCUM's fill calls are tried
-- one by one and the first that works is used.
local fill_way = nil
local function load_rounds(obj, want, cap_fn)
    local have = num(obj, "GetAmmoCount") or 0
    if have > 0 then return have, "InitialAmmo" end
    local ammo = nil
    pcall(function() ammo = obj.DefaultFillAmmo or obj.DefaultAmmunitionItemClass end)
    -- Only calls that take no arguments: guessed arguments can crash SCUM.
    local ways = {
        { "FillWithDefaultAmmo", function() return call_ok(obj, "FillWithDefaultAmmo") end },
        { "FillUpWithDefaultAmmo", function() return call_ok(obj, "FillUpWithDefaultAmmo") end },
    }
    if fill_way then
        for i, wdef in ipairs(ways) do if wdef[1] == fill_way then table.insert(ways, 1, table.remove(ways, i)) break end end
    end
    for _, wdef in ipairs(ways) do
        pcall(wdef[2])
        local n = num(obj, "GetAmmoCount") or 0
        if n > 0 then
            fill_way = wdef[1]
            return n, wdef[1]
        end
    end
    return 0, "ei mikaan tapa"
end

function B.fit_weapon(w, weapon_name, loadout, label, pos)
    B.log_weapon_api(w, "WEAPON " .. weapon_name)
    pcall(B.log_signatures)
    local notes = {}
    local cond = tonumber(loadout.Kunto)
    local c = set_condition(w, cond)
    if c then notes[#notes + 1] = "kunto " .. c .. " %" end
    local mname = type(loadout.Lipas) == "string" and loadout.Lipas or Weapons.magazine_for(weapon_name)
    if loadout.Lipas ~= false and mname then
        local want, cap, got, how = 0, 0, 0, ""
        local mag, ok, err = put_on_weapon(w, mname, label, pos, function(m)
            got, how = load_rounds(m, want)
            set_condition(m, cond)
        end, function(m)
            pcall(function() cap = m._capacity end)
            want = some_rounds(cap)
            pcall(function() m.InitialAmmo = want end)
        end)
        if mag then
            notes[#notes + 1] = string.format("lipas %s %s (%s/%s panosta, %s)", mname,
                ok and "kiinni" or ("EI kiinni: " .. tostring(err):sub(1, 80)), tostring(got), tostring(cap), how)
        else
            notes[#notes + 1] = "lipasta " .. mname .. " ei loytynyt"
        end
    elseif Weapons.kind(weapon_name) and loadout.Lipas ~= false then
        -- Built-in magazine (revolvers, shotguns, bolt-action rifles): the
        -- weapon is loaded as it is.
        -- The rounds were set as the weapon was made (hold_weapon).
        local n = num(w, "GetAmmoCount")
        local want = B.want_rounds[full_name(w)] or 0
        if n and n == 0 and want > 0 then n = load_rounds(w, want) end
        B.want_rounds[full_name(w)] = nil
        if n then notes[#notes + 1] = string.format("sisainen lipas: %s panosta", tostring(n)) end
    end
    local scopes = loadout.Tahtaimet or Weapons.scopes_for(weapon_name)
    local want_scope = loadout.Tahtain
    if want_scope == nil then want_scope = math.random() < (tonumber(loadout.TahtainOsuus) or 0) end
    if want_scope and #Weapons.scopes_for(weapon_name) > 0 and #scopes > 0 then
        for _, sname in ipairs(scopes) do
            if B.find_item_class(sname) then
                local sc, ok = put_on_weapon(w, sname, label, pos, function(x) set_condition(x, cond) end)
                if sc then notes[#notes + 1] = "tahtain " .. sname .. (ok and " kiinni" or " EI kiinni") end
                break
            end
        end
    end
    lnote(string.format("%s: %s - %s", label, weapon_name, table.concat(notes, ", ")))
end

-- The NPC fires through a "weapon manual" SCUM makes for its weapon type
-- (Weapon._armedNPCWeaponManualClass: rifle, handgun, bow, crossbow...).
-- A manual cannot be made or set up again from here: 1.9.6 made new ones
-- (the NPC held its weapon without firing), 1.9.7 and 1.9.9 called their
-- Initialize and the server crashed. So an NPC only gets a weapon of the
-- same manual type as the one SCUM gave it: rifle for rifle, pistol for
-- pistol - its own manual then fires the new weapon.
-- The parameters SCUM's functions take, read from the functions themselves
-- (1.9.7 guessed Initialize's arguments and a wrong guess crashed the
-- server). Written to weapon_api.txt once.
local SIGNATURES = {
    "/Script/SCUM.ArmedNPCWeaponManual:Initialize",
    "/Script/SCUM.ArmedNPCWeaponManual:GetWeapon",
    "/Script/SCUM.WeaponAttachmentMagazine:SetAmmo",
    "/Script/SCUM.WeaponAttachmentMagazine:AddAmmo",
    "/Script/SCUM.WeaponAttachmentMagazine:FillWithDefaultAmmo",
    "/Script/SCUM.Weapon:FillUpWithDefaultAmmo",
    "/Script/SCUM.Weapon:AddAttachmentOnServer",
    "/Script/SCUM.Item:Equip",
    "/Script/SCUM.Weapon:Equip",
    "/Script/SCUM.Weapon:StartFire",
    "/Script/SCUM.Item:DropAround",
}
function B.log_signatures()
    if B.signatures_logged then return end
    B.signatures_logged = true
    weapon_api[#weapon_api + 1] = "=== SIGNATURES"
    for _, path in ipairs(SIGNATURES) do
        crumb("signature " .. path)
        local f = nil
        pcall(function() f = StaticFindObject(path) end)
        if f and valid(f) then
            local params = {}
            pcall(function()
                f:ForEachProperty(function(p)
                    local n, t = "?", "?"
                    pcall(function() n = p:GetFName():ToString() end)
                    pcall(function() t = p:GetClass():GetFName():ToString() end)
                    -- Only object/class parameters have a class to name:
                    -- asking a struct parameter for one crashed UE4SS
                    -- (1.9.28-1.9.29, on the first weapon after a join).
                    local extra = ""
                    if t == "ObjectProperty" or t == "ClassProperty" then
                        pcall(function() extra = " " .. full_name(p:GetPropertyClass()) end)
                    end
                    params[#params + 1] = n .. ":" .. t .. extra
                end)
            end)
            weapon_api[#weapon_api + 1] = "  " .. path .. "(" .. table.concat(params, ", ") .. ")"
        else
            weapon_api[#weapon_api + 1] = "  " .. path .. " - not found"
        end
    end
    write_weapon_api()
end

local manual_cache = {}
local cdo_noted = false
local function manual_of(name)
    local key = tostring(name):lower()
    if manual_cache[key] ~= nil then return manual_cache[key] end
    local cls = B.find_item_class(name)
    if not cls then
        if B.last_find_deferred then return nil end
        manual_cache[key] = false
        return false
    end
    local cdo = nil
    pcall(function() cdo = cls:GetCDO() end)
    if not (cdo and valid(cdo)) then
        if not cdo_noted then cdo_noted = true; lnote("GetCDO ei toimi: aseen kasikirjaa ei voi lukea") end
        manual_cache[key] = false
        return false
    end
    local mc = nil
    pcall(function() mc = cdo._armedNPCWeaponManualClass end)
    local v = (mc and valid(mc)) and full_name(mc) or ""
    manual_cache[key] = v
    return v
end
B.manual_of = manual_of

-- ---------------------------------------------- weapons from the start ---
-- SCUM gives an armed NPC its weapon itself, a moment after the spawn, from
-- the list in its common data (PossibleItemInHands, e.g. four weapons for a
-- level 1 drifter) - and builds the weapon manual the NPC fires through for
-- exactly that weapon. A weapon swapped in later is never fired (1.9.6-
-- 1.9.11). So the list is set to the wanted weapon just before the NPC is
-- spawned, and SCUM itself hands it over, manual and all. The list's weapon
-- field is a soft class reference; how UE4SS takes a value for it is tried
-- once (a path string, a soft class path, a soft class reference) and the
-- way that reads back right is kept.
local soft_way = nil      -- nil: not tried yet, false: none works
local function kismet()
    local k = nil
    pcall(function() k = StaticFindObject("/Script/Engine.Default__KismetSystemLibrary") end)
    return k
end
local function soft_text(v)
    local k = kismet()
    local t = nil
    if k then pcall(function() t = k:Conv_SoftClassReferenceToString(v) end) end
    if t ~= nil then pcall(function() t = t:ToString() end) end
    if type(t) ~= "string" then pcall(function() t = v:ToString() end) end
    return type(t) == "string" and t or tostring(v)
end
local SOFT_WAYS = {
    { "polku", function(path) return path end },
    { "SoftClassPath", function(path) return kismet():MakeSoftClassPath(path) end },
    { "SoftClassRef", function(path)
        local k = kismet()
        return k:Conv_SoftClassPathToSoftClassRef(k:MakeSoftClassPath(path))
    end },
}
local function write_soft(entry, path, short)
    local tries = {}
    local ways = SOFT_WAYS
    if soft_way then ways = { soft_way } end
    for _, w in ipairs(ways) do
        local okv, val = pcall(w[2], path)
        local okset = okv and pcall(function() entry.Item = val end)
        local back = okset and soft_text(entry.Item) or ""
        tries[#tries + 1] = w[1] .. "=" .. (okset and back:sub(-60) or "x")
        if okset and back:find(short, 1, true) then
            soft_way = w
            return true, tries
        end
    end
    return false, tries
end
-- 1.9.13: writing the list crashed the server the moment the first NPC was
-- spawned (access violation inside UE4SS). Kept only behind a config switch
-- that is off (PresetWeapons), in case a later UE4SS handles it.
function B.preset_weapon(npccls, names)
    if not (B.cfg and B.cfg.PresetWeapons) then return nil end
    if soft_way == false or (B.cfg and B.cfg.SwapWeapons) then return nil end
    -- The first of the member's weapons whose class is known (one new class
    -- lookup per tick at most, as everywhere).
    local wcls, wname = nil, nil
    for _, n in ipairs(names or {}) do
        local c = B.find_item_class(n)
        if c then wcls, wname = c, n; break end
    end
    if not wcls then return nil end
    local path = full_name(wcls):match("%s(%S+)$")
    local cdo, cd, arr = nil, nil, nil
    pcall(function() cdo = npccls:GetCDO() end)
    pcall(function() cd = cdo._armedNPCBaseCommonData end)
    pcall(function() arr = cd.PossibleItemInHands end)
    if not (path and arr) then
        if not B.preset_noted then B.preset_noted = true; lnote("aseen esiasetus: NPC-luokan listaa ei loytynyt") end
        return nil
    end
    local short = (path:match("%.([%w_]+)$") or wname):gsub("_C$", "")
    local all_ok, notes = true, nil
    pcall(function()
        arr:ForEach(function(_, e)
            local entry = unwrap(e)
            local ok, tries = write_soft(entry, path, short)
            notes = notes or tries
            if not ok then all_ok = false end
            pcall(function() entry.SpawnWeight = 1.0 end)
        end)
    end)
    if soft_way == nil and not all_ok then
        soft_way = false
        lnote("aseen esiasetus EI toimi (" .. table.concat(notes or {}, ", ") .. "): NPC:t pitavat SCUMin aseet")
        return nil
    end
    if not B.preset_ok_noted and all_ok then
        B.preset_ok_noted = true
        lnote("aseen esiasetus toimii (" .. tostring(soft_way and soft_way[1]) .. "): " .. wname)
    end
    return all_ok and wname or nil
end

-- One NPC at a time: the next is spawned once the last one has its weapon
-- (or after a few seconds), so no NPC picks up a list set for another.
B.spawn_gap_sec = 4
function B.spawn_ready()
    local l = B.last_spawn
    if not l then return true end
    if os.time() - l.t >= B.spawn_gap_sec then return true end
    local a = B.actor(l.handle)
    if not a then return true end
    local w = nil
    pcall(function() w = a._itemInHands end)
    return w ~= nil and valid(w)
end

-- A weapon: the new one goes where SCUM had put the NPC's own (same parent
-- and socket), becomes the item in hands, and the old one is removed.
B.want_rounds = {}
local function hold_weapon(a, handle, name, label, pos, olds)
    local cls = B.find_item_class(name)
    if not cls then return false end
    -- A weapon with a built-in magazine (shotgun, revolver, bolt-action)
    -- gets a random number of rounds as it is made.
    local want = 0
    local item, why = spawn_actor(cls, pos, function(x)
        if Weapons.magazine_for(name) then return end
        local cap = 0
        pcall(function() cap = tonumber(x.InternalMagazineCapacity) or 0 end)
        if cap <= 0 then pcall(function() if x.UseChamberAsInternalMagazine then cap = tonumber(x.MaxLoadedAmmo) or 1 end end) end
        if cap > 0 then
            want = some_rounds(cap)
            pcall(function() x.InitialAmmo = want end)
        end
    end)
    if not item then
        lnote(string.format("%s: %s - spawn failed: %s", label, name, tostring(why)))
        return false
    end
    keep_extra(handle, item)
    if want > 0 then B.want_rounds[full_name(item)] = want end
    pcall(function() item:SetOwner(a) end)
    pcall(function() item:SetActorEnableCollision(false) end)
    local parent, socket = nil, nil
    if olds[1] then
        pcall(function() parent = olds[1]:K2_GetRootComponent():GetAttachParent() end)
        pcall(function() socket = olds[1]:GetAttachParentSocketName() end)
    end
    if not (parent and valid(parent)) then pcall(function() parent = a.Mesh end) end
    local att = pcall(function()
        item:K2_GetRootComponent():K2_AttachToComponent(parent, socket or fname("hand_r"), 2, 2, 2, false)
    end)
    local inhands = pcall(function() a._itemInHands = item end)
    -- A weapon in someone's hands is "active" and knows who holds it (the
    -- player's weapon: _currentState = StateActive, _attachParentObject =
    -- the player). A freshly spawned one is inactive and fires nothing, which
    -- is why the swapped weapons never shot. Both are set as plain fields -
    -- no function of the weapon is called (Initialize crashed the server).
    pcall(function() item._attachParentObject = a end)
    local state = "?"
    pcall(function()
        local act = item._activeState
        if act and valid(act) then item._currentState = act end
    end)
    pcall(function() state = (full_name(item._currentState):match("([%w_]+)$") or "?") end)
    for _, o in ipairs(olds) do pcall(function() o:K2_DestroyActor() end) end
    lnote(string.format("%s: %s - weapon placed (attach=%s, in hands=%s, replaced %d, state %s)",
        label, name, tostring(att), tostring(inhands), #olds, state))
    return att, item
end

-- ---------------------------------------------------------- ghost weapon ---
-- The NPC keeps SCUM's weapon - the only one it fires, through the weapon
-- manual SCUM built for it - but that weapon is hidden, and the squad's own
-- weapon (same type: rifle for rifle, pistol for pistol, so the hands hold
-- it right) sits in its hand as a prop. When the NPC dies the hidden weapon
-- is removed and the prop drops to the ground in its place, magazine and
-- all, as if it had fired it.
local function ghost_weapon(a, h, own, name, label, pos)
    local cls = B.find_item_class(name)
    if not cls then return nil end
    local want = 0
    local prop = spawn_actor(cls, pos, function(x)
        if Weapons.magazine_for(name) then return end
        local cap = 0
        pcall(function() cap = tonumber(x.InternalMagazineCapacity) or 0 end)
        if cap <= 0 then pcall(function() if x.UseChamberAsInternalMagazine then cap = tonumber(x.MaxLoadedAmmo) or 1 end end) end
        if cap > 0 then
            want = some_rounds(cap)
            pcall(function() x.InitialAmmo = want end)
        end
    end)
    if not prop then return nil end
    keep_extra(h, prop)
    if want > 0 then B.want_rounds[full_name(prop)] = want end
    pcall(function() prop:SetOwner(a) end)
    pcall(function() prop:SetActorEnableCollision(false) end)
    pcall(function() prop._attachParentObject = a end)
    local parent, socket = nil, nil
    pcall(function() parent = own:K2_GetRootComponent():GetAttachParent() end)
    pcall(function() socket = own:GetAttachParentSocketName() end)
    if not (parent and valid(parent)) then pcall(function() parent = a.Mesh end) end
    local att = pcall(function()
        prop:K2_GetRootComponent():K2_AttachToComponent(parent, socket or fname("hand_r"), 2, 2, 2, false)
    end)
    -- Players' machines draw a weapon in the NPC's hand only for the NPC's
    -- item in hands (1.9.15: the prop was attached on the server but lay on
    -- the ground on screen). So the prop becomes the item in hands, active
    -- and held by the NPC; SCUM's weapon stays alive, hidden - the weapon
    -- manual SCUM built for it is still bound to it and fires it.
    pcall(function() prop._currentState = prop._activeState end)
    local inhands = pcall(function() a._itemInHands = prop end)
    -- SCUM's weapon, and whatever hangs on it, out of sight.
    local hid = pcall(function() own:SetActorHiddenInGame(true) end)
    for _, part in ipairs(items_owned_by(own)) do pcall(function() part:SetActorHiddenInGame(true) end) end
    local rec = handles[h]
    if rec then rec.ghost = { own = own, prop = prop } end
    lnote(string.format("%s: haamuase - nakyva %s, piilotettu %s (kiinni %s, kadessa %s, piilossa %s)", label, name,
        (full_name(own:GetClass()):match("([%w_]+)$") or "?"):gsub("_C$", ""), tostring(att), tostring(inhands), tostring(hid)))
    return prop
end

-- The NPC is dead: the hidden weapon and the prop go, and the weapon falls
-- from its hand. The prop itself stays "in hands" to SCUM (active, held by
-- the NPC) and could not be picked up (1.9.17), so a fresh copy - same
-- weapon, same scope, the prop's condition, a magazine with some rounds -
-- lies on the floor right under where the hand was. The floor comes from a
-- short trace down (the navmesh sits above the ground: 1.9.18 left the
-- weapon hanging in the air). Waiting for a search (1.9.19-1.9.23) did not
-- work: SCUM's search loot is not visible to the mod.
local function body_pos(a)
    local p = nil
    pcall(function() p = vec(a.Mesh:K2_GetComponentLocation()) end)
    if not sane(p) then pcall(function() p = vec(a:K2_GetActorLocation()) end) end
    return sane(p) and p or nil
end

-- The floor right under a spot (a short trace: a roof or a tree above the
-- body must not count).
local function floor_under(pos)
    local k = get_kismet()
    if not k then return nil end
    local ok, out, hit = pcall(function()
        local o = {}
        local r = k:LineTraceSingle(B.get_world(),
            { X = pos.X, Y = pos.Y, Z = pos.Z + 80 }, { X = pos.X, Y = pos.Y, Z = pos.Z - 400 },
            0, false, {}, 0, o, true, { R = 0, G = 0, B = 0, A = 0 }, { R = 0, G = 0, B = 0, A = 0 }, 0)
        return o, r
    end)
    if not ok or hit == false then return nil end
    local p = vec(out.ImpactPoint) or vec(out.Location)
    return sane(p) and p.Z or nil
end

-- Items in SCUM do not fall: a weapon has to be laid down. It is made
-- upright (as held), its box tells which way the barrel runs (the longest
-- side), it is turned onto its side around that line with a random heading,
-- and set down so the bottom of its box touches the floor.
local function box_of(item)
    local o, e = {}, {}
    local ok = pcall(function() item:GetActorBounds(false, o, e, false) end)
    local ov, ev = vec(o), vec(e)
    if ok and sane(ov) and sane(ev) and (ev.X + ev.Y + ev.Z) > 1 then return ov, ev end
    return nil
end

local function lay_down(item, floor)
    local yaw = math.random() * 360
    local _, e = box_of(item)
    local rot = { Pitch = 0, Yaw = yaw, Roll = 90 }
    if e and e.Y > e.X then rot = { Pitch = 0, Yaw = yaw, Roll = 0 }; rot.Pitch = 90 end
    pcall(function() item:K2_SetActorRotation(rot, true) end)
    local p = nil
    pcall(function() p = vec(item:K2_GetActorLocation()) end)
    local o2, e2 = box_of(item)
    local z = floor + 4
    if p and o2 then z = p.Z + (floor - (o2.Z - e2.Z)) + 1 end
    if p then pcall(function() item:K2_SetActorLocation({ X = p.X, Y = p.Y, Z = z }, false, {}, true) end) end
    return string.format("%s, lattia %.0f, asetettu %.0f", e and (e.Y > e.X and "piippu Y" or "piippu X") or "ei mittoja",
        floor, z)
end

local function lay_weapon(l, at)
    local name = l.name
    local cls = B.find_item_class(name)
    if not cls then return false end
    local want = 0
    local item = spawn_actor(cls, at, function(x)
        if Weapons.magazine_for(name) then return end
        local cap = 0
        pcall(function() cap = tonumber(x.InternalMagazineCapacity) or 0 end)
        if cap <= 0 then pcall(function() if x.UseChamberAsInternalMagazine then cap = tonumber(x.MaxLoadedAmmo) or 1 end end) end
        if cap > 0 then
            want = some_rounds(cap)
            pcall(function() x.InitialAmmo = want end)
        end
    end, nil, true)
    if not item then return false end
    if want > 0 then B.want_rounds[full_name(item)] = want end
    local okl, how = pcall(lay_down, item, l.floor or at.Z)
    local okf, err = pcall(B.fit_weapon, item, name, l.lo or {}, l.label, at)
    if not okf then lnote("haamuase: varustus - error: " .. tostring(err)) end
    return true, okl and how or ("asettelu - error: " .. tostring(how))
end

function B.ghost_drop(handle)
    local rec = handles[handle]
    local g = rec and rec.ghost
    if not g or g.dropped then return end
    g.dropped = true
    local own, prop = g.own, g.prop
    local a = B.actor(handle)
    local body = a and body_pos(a) or nil
    local hand, name = nil, g.name
    if prop and valid(prop) then
        pcall(function() hand = vec(prop:K2_GetActorLocation()) end)
        if not name then
            pcall(function() name = (full_name(prop:GetClass()):match("([%w_]+)$") or ""):gsub("_C$", "") end)
        end
        pcall(function() prop:SetActorHiddenInGame(true) end)
        for _, part in ipairs(items_owned_by(prop)) do pcall(function() part:K2_DestroyActor() end) end
        pcall(function() prop:K2_DestroyActor() end)
        for i, x in ipairs(rec.extras or {}) do
            if x == prop then table.remove(rec.extras, i); break end
        end
    end
    if own and valid(own) then
        for _, part in ipairs(items_owned_by(own)) do pcall(function() part:K2_DestroyActor() end) end
        pcall(function() own:K2_DestroyActor() end)
    end
    local ok, where = false, "?"
    local ref = sane(hand) and hand or body
    if ref and name and name ~= "" then
        local at = { X = ref.X, Y = ref.Y, Z = ref.Z }
        local z = floor_under(at)
        if not z and body then
            at = { X = body.X + 40, Y = body.Y, Z = body.Z }
            z = floor_under(at)
        end
        if z then
            -- Made above the floor (never inside the ground), then laid down.
            at.Z = z + 40
            local how
            ok, how = lay_weapon({ name = name, lo = g.lo, label = g.label or tostring(rec.npcId), floor = z }, at)
            where = tostring(how)
        else
            where = "lattiaa ei loytynyt"
        end
    end
    lnote(string.format("haamuase pudotettu (%s): %s maassa %s (%s)", tostring(rec.npcId), tostring(name),
        tostring(ok), where))
end

-- Does this NPC show a custom weapon (config GhostWeaponChance)? The roll
-- comes from the NPC's name, so it is the same every time it is spawned.
function B.ghost_roll(label)
    local c = tonumber(B.cfg and B.cfg.GhostWeaponChance)
    if c == nil then c = 1.0 end
    if c >= 1 then return true end
    if c <= 0 then return false end
    local h = 5381
    for i = 1, #tostring(label or "") do h = (h * 33 + tostring(label):byte(i)) % 2147483647 end
    return (h % 10000) / 10000 < c
end

-- SCUM gives an NPC its own weapon a moment after the spawn. 1.8.1 put the
-- new weapon on at once: when the NPC had no weapon yet, the new one hung in
-- the air (no hand socket to copy) and the NPC got its own anyway. So the
-- swap waits until the NPC's own weapon exists and takes its place.
B.pending_weapons = {}
B.weapon_chosen = {}
function B.weapon_of(handle) return B.weapon_chosen[handle] end
B.weapon_wait_sec = 20
function B.tick_weapons(now)
    B.probe_budget = 1
    if next(B.pending_weapons) == nil then return end
    now = now or os.time()
    local by_owner = nil
    for h, p in pairs(B.pending_weapons) do
        local a = B.actor(h)
        if not a then
            B.pending_weapons[h] = nil
        else
            if not by_owner then
                by_owner = {}
                for _, it in ipairs(find_all("Item", nil, true) or {}) do
                    local ok, own = pcall(function() return it:GetOwner() end)
                    if ok and own then
                        local on = full_name(own)
                        by_owner[on] = by_owner[on] or {}
                        table.insert(by_owner[on], it)
                    end
                end
            end
            local olds = by_owner[full_name(a)] or {}
            -- SCUM's own weapon is kept and fitted out (config SwapWeapons
            -- off, the default): a weapon put in the NPC's hands later never
            -- fires, because the NPC's weapon manual stays bound to the one
            -- SCUM gave it (1.9.6-1.9.11), and re-binding it crashes SCUM.
            if #olds > 0 and not (B.cfg and B.cfg.SwapWeapons) then
                local w = nil
                pcall(function() w = a._itemInHands end)
                if not (w and valid(w)) then w = olds[1] end
                local wname = (full_name(w:GetClass()):match("([%w_]+)$") or "?"):gsub("_C$", "")
                -- Ghost weapon: a prop of the same type from the member's list.
                local gpick, gwait = nil, false
                if not (B.cfg and B.cfg.GhostWeapons == false) and B.ghost_roll(p.label) then
                    local own_m = ""
                    pcall(function()
                        local m = a._weaponManual
                        if m and valid(m) then own_m = full_name(m:GetClass()) end
                    end)
                    -- Only weapons that fire like the hidden one (same group:
                    -- shotgun, precision rifle, automatic rifle, pistol...)
                    -- and that the hands hold the same way (same manual).
                    local cands = Weapons.similar(wname, (p.loadout or {}).Luokka, p.order)
                    for _, name in ipairs(cands) do
                        local mc = manual_cache[name:lower()]
                        if mc == nil then mc = manual_of(name) end
                        if mc == nil then gwait = true; break end
                        if mc and mc == own_m then gpick = name; break end
                    end
                end
                if gwait and not gpick and now <= p.deadline + 60 then goto continue end
                B.pending_weapons[h] = nil
                if gpick and gpick:lower() ~= wname:lower() then
                    local gpos = nil
                    pcall(function() gpos = vec(a:K2_GetActorLocation()) end)
                    local prop = gpos and ghost_weapon(a, h, w, gpick, p.label, gpos) or nil
                    if prop then
                        B.weapon_chosen[h] = gpick
                        local lo = {}
                        for k, v in pairs(p.loadout or {}) do lo[k] = v end
                        if gpick ~= p.name then lo.Tahtain = nil end
                        -- Scope decided once: the weapon dropped at death gets the same.
                        if lo.Tahtain == nil then lo.Tahtain = math.random() < (tonumber(lo.TahtainOsuus) or 0) end
                        local okf, err = pcall(B.fit_weapon, prop, gpick, lo, p.label, gpos)
                        if not okf then lnote(p.label .. ": varustus - error: " .. tostring(err)) end
                        local rec = handles[h]
                        if rec and rec.ghost then rec.ghost.name = gpick; rec.ghost.lo = lo; rec.ghost.label = p.label end
                        goto continue
                    end
                end
                B.weapon_chosen[h] = wname
                local rec = handles[h]
                if rec and rec.wanted and rec.wanted:lower() ~= wname:lower() then
                    lnote(string.format("%s: pyydetty %s, SCUM antoi %s", p.label, rec.wanted, wname))
                end
                local pos = nil
                pcall(function() pos = vec(a:K2_GetActorLocation()) end)
                if pos then
                    local lo = {}
                    for k, v in pairs(p.loadout or {}) do lo[k] = v end
                    lo.Tahtain = nil
                    local okf, err = pcall(B.fit_weapon, w, wname, lo, p.label, pos)
                    if not okf then lnote(p.label .. ": varustus - error: " .. tostring(err)) end
                end
                goto continue
            end
            -- Is every candidate's type known, or is one still to be looked up
            -- (one lookup per tick)? Then the NPC waits for its turn.
            local waiting, pick = false, nil
            if #olds > 0 then
                local own = ""
                pcall(function()
                    local m = a._weaponManual
                    if m and valid(m) then own = full_name(m:GetClass()) end
                end)
                p.own = own
                for _, name in ipairs(p.order or { p.name }) do
                    local mc = manual_cache[name:lower()]
                    if mc == nil then mc = manual_of(name) end
                    if mc == nil then waiting = true; break end
                    if mc and mc == own then pick = name; break end
                end
                p.pick = pick
            end
            if waiting and not pick and now <= p.deadline + 60 then
                -- next tick
            elseif #olds > 0 then
                B.pending_weapons[h] = nil
                local pos = nil
                pcall(function() pos = vec(a:K2_GetActorLocation()) end)
                -- The NPC's own manual type (from the weapon SCUM gave it).
                local own, pick = p.own or "", p.pick
                if pos and pick then
                    local ok, res, item = pcall(hold_weapon, a, h, pick, p.label, pos, olds)
                    if not ok then lnote(p.label .. ": " .. pick .. " - error: " .. tostring(res))
                    elseif res and item then
                        B.weapon_chosen[h] = pick
                        local lo = p.loadout or {}
                        if pick ~= p.name then
                            -- Another weapon than the member's pick: its scope is rolled anew.
                            local lo2 = {}
                            for k, v in pairs(lo) do lo2[k] = v end
                            lo2.Tahtain = nil
                            lo = lo2
                        end
                        local okf, err = pcall(B.fit_weapon, item, pick, lo, p.label, pos)
                        if not okf then lnote(p.label .. ": varustus - error: " .. tostring(err)) end
                    end
                elseif pos then
                    lnote(string.format("%s: oma ase pidetaan (kasikirja %s; listassa ei samaa tyyppia)",
                        p.label, own:match("([%w_]+)$") or "-"))
                end
            elseif now > p.deadline then
                B.pending_weapons[h] = nil
                lnote(p.label .. ": " .. p.name .. " - NPC:n omaa asetta ei tullut " .. B.weapon_wait_sec .. " s:ssa, ase jatettiin vaihtamatta")
            end
        end
        ::continue::
    end
end

-- Outfit: _bodyMeshIndex picks one of the NPC type's ready outfits
-- (_armedNPCBaseCommonData.Variations.Physical, e.g. 10 for Drifter level 1).
-- Setting it once right after the spawn changed nothing on screen (1.7.9).
-- SCUM gives the NPC its weapon a moment later, so it probably rolls the
-- outfit again then: the index is watched for a while, every change the game
-- makes is logged and our number put back.
B.body_watch = {}
B.body_watch_sec = 90
local body_logged = 0
local function outfit_count(a)
    local n = nil
    pcall(function()
        local arr = a._armedNPCBaseCommonData.Variations.Physical
        local ok, c = pcall(function() return arr:GetArrayNum() end)
        if ok and tonumber(c) then n = tonumber(c) else n = #arr end
    end)
    if n and n > 0 then return n end
    return nil
end
function B.set_body(a, want, label)
    local idx = want
    if type(want) == "table" then
        if #want == 0 then return nil end
        idx = want[math.random(#want)]
    end
    idx = tonumber(idx)
    if not idx then return nil end
    idx = math.floor(idx)
    local n = outfit_count(a)
    if n and (idx < 0 or idx >= n) then idx = idx % n end
    local ok = pcall(function() a._bodyMeshIndex = idx end)
    local after = nil
    pcall(function() after = a._bodyMeshIndex end)
    if ok and after == idx then return idx, n end
    return nil
end
function B.tick_body(now)
    if next(B.body_watch) == nil then return end
    now = now or os.time()
    for h, w in pairs(B.body_watch) do
        local a = B.actor(h)
        if not a then
            B.body_watch[h] = nil
        else
            local cur = nil
            pcall(function() cur = a._bodyMeshIndex end)
            if cur ~= w.idx then
                w.changes = w.changes + 1
                if w.log then
                    lnote(string.format("%s: peli vaihtoi asun %s -> %s %d s spawnin jalkeen, palautetaan %d",
                        w.label, tostring(w.idx), tostring(cur), now - w.t0, w.idx))
                end
                pcall(function() a._bodyMeshIndex = w.idx end)
            end
            if now - w.t0 >= B.body_watch_sec then
                B.body_watch[h] = nil
                if w.log then
                    lnote(string.format("%s: asu %d pysyi %d s (peli vaihtoi sita %d kertaa)",
                        w.label, w.idx, B.body_watch_sec, w.changes))
                end
            end
        end
    end
end

function B.apply_loadout(handle, loadout, label)
    local a = B.actor(handle)
    if not (a and loadout) then return 0 end
    label = label or "?"
    local names = {}
    for _, key in ipairs({ "Clothes", "Weapons", "Items" }) do
        for _, n in ipairs(loadout[key] or {}) do names[#names + 1] = n end
    end
    if not B.outfit_surveyed and not B.survey_handle then
        B.survey_handle, B.survey_names, B.survey_at = handle, names, os.time() + 6
    end
    local given = 0
    if loadout.Asu ~= nil then
        local before = nil
        pcall(function() before = a._bodyMeshIndex end)
        local okb, idx, n = pcall(B.set_body, a, loadout.Asu, label)
        if okb and idx then
            given = given + 1
            body_logged = body_logged + 1
            local log = body_logged <= 6
            B.body_watch[handle] = { idx = idx, label = label, t0 = os.time(), changes = 0, log = log }
            if log then
                lnote(string.format("%s: asu %s -> %d (asuja tyypilla %s)", label, tostring(before), idx, tostring(n or "?")))
            end
        elseif body_logged == 0 then
            body_logged = 1
            lnote(label .. ": asun asetus ei onnistunut: " .. tostring(idx))
        end
    end
    if #names == 0 then return given end
    local okl, loc = pcall(function() return a:K2_GetActorLocation() end)
    local pos = okl and vec(loc) or nil
    if not pos then return given end
    for _, name in ipairs(loadout.Clothes or {}) do
        local ok, res = pcall(wear_item, a, handle, name, label, pos)
        if ok and res then given = given + 1
        elseif not ok then lnote(label .. ": " .. name .. " - error: " .. tostring(res)) end
    end
    -- One weapon at random among those in the list this server has.
    local w = nil
    local order = {}
    for _, name in ipairs(loadout.Weapons or {}) do order[#order + 1] = name end
    for i = #order, 2, -1 do
        if loadout.ordered then break end
        local j = math.random(i)
        order[i], order[j] = order[j], order[i]
    end
    -- The classes are looked up later, one per tick (tick_weapons); names
    -- this server does not have are left out now.
    local kept = {}
    for _, name in ipairs(order) do
        if not guess_failed[name:lower()] or item_class_cache[name:lower()] then kept[#kept + 1] = name end
    end
    order = kept
    w = order[1] or "SCUM"
    if w then
        B.pending_weapons[handle] = { name = w, order = order, label = label, loadout = loadout,
                                      deadline = os.time() + B.weapon_wait_sec }
        pcall(B.tick_weapons, os.time())
        given = given + 1
    end
    if #(loadout.Items or {}) > 0 and not B.items_note then
        B.items_note = true
        lnote("Items: carried items are not supported yet (SCUM's NPCs have no inventory)")
    end
    return given
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
