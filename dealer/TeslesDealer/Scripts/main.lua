-- TESLES DEALER: SCUM's traders refuse cannabis and mushrooms, so this mod
-- buys them at the doctors' counters itself. Server-side, UE4SS Lua.
-- Every engine call is wrapped in pcall; all output goes to
-- dealer.log in this mod's folder.
local SCRIPT_DIR = (debug.getinfo(1, "S").source:match("^@(.*[\\/])") or ".\\")
local MOD_DIR = SCRIPT_DIR .. "..\\"
package.path = SCRIPT_DIR .. "?.lua;" .. package.path

local Dealer = require("dealer")

local CFG = {}
do
    local ok, c = pcall(dofile, MOD_DIR .. "config.lua")
    if ok and type(c) == "table" then CFG = c end
end

-- ------------------------------------------------------------------ log ---

local LOG_PATH = MOD_DIR .. "dealer.log"
local function log(msg)
    local line = os.date("%Y-%m-%d %H:%M:%S") .. "  " .. tostring(msg)
    print("[TeslesDealer] " .. line .. "\n")
    local f = io.open(LOG_PATH, "a")
    if f then f:write(line .. "\n"); f:close() end
end

-- -------------------------------------------------------------- helpers ---

local function valid(o)
    if o == nil then return false end
    local ok, v = pcall(function() return o:IsValid() end)
    return ok and v == true
end
local function full_name(o)
    local ok, n = pcall(function() return o:GetFullName() end)
    return ok and tostring(n) or "?"
end
local function vec(v)
    if not v then return nil end
    local ok, x, y, z = pcall(function() return v.X, v.Y, v.Z end)
    if ok and type(x) == "number" then return { X = x, Y = y, Z = z } end
    return nil
end
local function loc(a)
    local ok, p = pcall(function() return a:K2_GetActorLocation() end)
    return ok and vec(p) or nil
end
local function find_all(short)
    local ok, list = pcall(function() return FindAllOf(short) end)
    if ok and list then return list end
    return {}
end

-- --------------------------------------------------------------- bridge ---

local Bridge = {}

-- The doctors: every trader whose name (or personality) has one of the
-- DrugTraders words. Looked up once a minute; every trader found is
-- written to the log once, so the words can be set right.
local zones_cache, zones_at, traders_logged = {}, -1000, false
function Bridge.dealer_zones(now)
    if now - zones_at < 60 then return zones_cache end
    zones_at = now
    local words = CFG.DrugTraders or { "doctor", "hospital", "medic", "physician" }
    local out, lines = {}, {}
    for _, t in ipairs(find_all("Trader")) do
        if valid(t) then
            local name = full_name(t)
            local persona = ""
            pcall(function()
                local p = t._traderPersonalityDataAsset
                if p then
                    local okg, obj = pcall(function() return p:Get() end)
                    persona = full_name(okg and obj or p)
                end
            end)
            local pos = loc(t)
            local hay = (name .. " " .. persona):lower()
            local match = false
            for _, w in ipairs(words) do
                if hay:find(tostring(w):lower(), 1, true) then match = true; break end
            end
            lines[#lines + 1] = string.format("  %s %s | %s | at %s", match and "BUYS " or "     ",
                name, persona, pos and string.format("%.0f %.0f %.0f", pos.X, pos.Y, pos.Z) or "?")
            if match and pos then out[#out + 1] = { pos = pos, name = name:match("([^%.:]+)$") or name } end
        end
    end
    if not traders_logged and #lines > 0 then
        traders_logged = true
        log("traders found (" .. #lines .. "), BUYS = buys drugs:\n" .. table.concat(lines, "\n"))
    end
    zones_cache = out
    return out
end

local comp_classes = {}
local function comp_class(path)
    if comp_classes[path] == nil then
        local ok, c = pcall(StaticFindObject, path)
        comp_classes[path] = (ok and valid(c)) and c or false
    end
    return comp_classes[path] or nil
end
local function components(actor, path)
    local cls = comp_class(path)
    if not cls then return {} end
    local out = {}
    pcall(function()
        local list = actor:K2_GetComponentsByClass(cls)
        for i = 1, #list do
            local c = list[i]
            local okg, g = pcall(function() return c:get() end)
            if okg and g then c = g end
            if valid(c) then out[#out + 1] = c end
        end
    end)
    return out
end

-- How many uses or pieces an item holds (a bud's 6/6, a stack of joints).
local function quantity(item)
    for _, c in ipairs(components(item, "/Script/SCUM.DiscreteAmountItemComponent")) do
        local ok, q = pcall(function() return c._repQuantity end)
        if ok and type(q) == "number" then return q end
    end
    return nil
end

local function health_share(item)
    local ok, h, m = pcall(function() return item:GetHealth(), item:GetMaxHealth() end)
    if ok and type(h) == "number" and type(m) == "number" and m > 0 then return h / m end
    return 1
end

-- Lying in the world, not in someone's hands, pockets or a container
-- (those are attached to their holder, or hidden).
local function on_ground(item)
    local parent, hidden = nil, false
    pcall(function() parent = item:GetAttachParentActor() end)
    pcall(function() hidden = item.bHidden == true end)
    return not valid(parent) and not hidden
end

local item_logged, skip_logged = false, false
function Bridge.dealer_items(goods, zones, radius, height)
    local out = {}
    for key, good in pairs(goods) do
        for _, it in ipairs(find_all(good.name .. "_C")) do
            if valid(it) then
                local p = loc(it)
                if p then
                    for zi, z in ipairs(zones) do
                        local dx, dy, dz = p.X - z.pos.X, p.Y - z.pos.Y, p.Z - z.pos.Z
                        if dx * dx + dy * dy <= radius * radius and math.abs(dz) <= height then
                            local ground = on_ground(it)
                            if not ground and not skip_logged then
                                skip_logged = true
                                local par = nil
                                pcall(function() par = it:GetAttachParentActor() end)
                                log("goods near a doctor but not lying free (held or in a container): "
                                    .. full_name(it) .. " attached to " .. (valid(par) and full_name(par) or "nothing"))
                            end
                            if ground then
                                local q, h = quantity(it), health_share(it)
                                if not item_logged then
                                    item_logged = true
                                    log(string.format("first goods on a counter: %s, quantity %s, condition %.0f %%",
                                        full_name(it), tostring(q), h * 100))
                                end
                                out[#out + 1] = { key = full_name(it), actor = it, good = key, pos = p,
                                                  zone = zi, qty = q, health = h }
                            end
                            break
                        end
                    end
                end
            end
        end
    end
    return out
end

function Bridge.destroy_item(item)
    return (pcall(function() item:K2_DestroyActor() end))
end

-- SCUM cash: the Cash item, its amount the money resource it holds.
local CASH_PATH = "/Game/ConZ_Files/Items/Economy/Cash.Cash_C"
local cash_class = nil
local function get_cash_class()
    if cash_class and valid(cash_class) then return cash_class end
    pcall(function() cash_class = StaticFindObject(CASH_PATH) end)
    if not valid(cash_class) then
        pcall(function() LoadAsset(CASH_PATH) end)
        pcall(function() cash_class = StaticFindObject(CASH_PATH) end)
    end
    return valid(cash_class) and cash_class or nil
end
local function set_cash(item, amount)
    local set = false
    for _, c in ipairs(components(item, "/Script/SCUM.BasicGameResourceContainerComponent")) do
        if pcall(function() c._repResourceAmount = amount end) then set = true end
    end
    return set
end
local function read_cash(item)
    for _, c in ipairs(components(item, "/Script/SCUM.BasicGameResourceContainerComponent")) do
        local ok, v = pcall(function() return c._repResourceAmount end)
        if ok and type(v) == "number" then return v end
    end
    return nil
end

local cash_logged = false
function Bridge.spawn_cash(pos, amount)
    local cls = get_cash_class()
    if not cls then return false, "Cash class not found" end
    local gs = nil
    pcall(function() gs = StaticFindObject("/Script/Engine.Default__GameplayStatics") end)
    local world = nil
    for _, short in ipairs({ "GameModeBase", "PlayerController" }) do
        pcall(function()
            local o = FindFirstOf(short)
            if valid(o) then world = o:GetWorld() end
        end)
        if valid(world) then break end
    end
    if not (valid(gs) and valid(world)) then return false, "no world" end
    local xf = { Rotation = { X = 0, Y = 0, Z = 0, W = 1 },
                 Translation = { X = pos.X, Y = pos.Y, Z = pos.Z + 5 },
                 Scale3D = { X = 1, Y = 1, Z = 1 } }
    local ok, cash = pcall(function()
        local a = gs:BeginDeferredActorSpawnFromClass(world, cls, xf, 1, nil)
        if valid(a) then
            set_cash(a, amount)
            gs:FinishSpawningActor(a, xf)
        end
        return a
    end)
    if not (ok and valid(cash)) then return false, "spawn failed" end
    -- SCUM may give new cash an amount of its own after spawning: set again.
    set_cash(cash, amount)
    local got = read_cash(cash)
    if not cash_logged then
        cash_logged = true
        log(string.format("cash paid: asked %d, the cash item holds %s", amount, tostring(got)))
    end
    if got == nil or math.abs(got - amount) > 0.5 then
        pcall(function() cash:K2_DestroyActor() end)
        return false, "cash amount " .. tostring(got) .. " instead of " .. amount
    end
    return true
end

-- ----------------------------------------------------------------- loop ---

local state = Dealer.new()
local function tick()
    local ok, err = pcall(Dealer.tick, state, Bridge, CFG, os.time(), log)
    if not ok then log("error: " .. tostring(err)) end
end

log("TESLES DEALER " .. tostring(CFG.Version) .. " loaded (sales " .. tostring(CFG.DrugSales ~= false) .. ")")
-- The world and the traders are there some time after the server starts.
local function start()
    if LoopInGameThreadWithDelay then
        LoopInGameThreadWithDelay(1000, function() tick() end)
    else
        LoopAsync(1000, function()
            ExecuteInGameThread(function() tick() end)
            return false
        end)
    end
    log("watching the doctors' counters")
end
if ExecuteInGameThreadWithDelay then
    ExecuteInGameThreadWithDelay(30000, start)
else
    ExecuteWithDelay(30000, function() ExecuteInGameThread(start) end)
end
