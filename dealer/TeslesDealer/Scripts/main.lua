-- TESLES DEALER: SCUM's traders refuse cannabis and mushrooms, so this mod
-- buys them at the doctors' counters itself. Server-side, UE4SS Lua.
-- Every engine call is wrapped in pcall; all output goes to
-- dealer.log in this mod's folder.
local SCRIPT_DIR = (debug.getinfo(1, "S").source:match("^@(.*[\\/])") or ".\\")
local MOD_DIR = SCRIPT_DIR .. "..\\"
package.path = SCRIPT_DIR .. "?.lua;" .. package.path

local Dealer = require("dealer")
local VERSION = "1.0.2"

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
local players_at, players = -1, {}
local function player_spots()
    local now = os.time()
    if now ~= players_at then
        players_at, players = now, {}
        for _, pc in ipairs(find_all("PlayerController")) do
            pcall(function()
                local pawn = pc.Pawn
                if valid(pawn) then players[#players + 1] = loc(pawn) end
            end)
        end
    end
    return players
end
local function why_not_free(item)
    local parent, owner = nil, nil
    pcall(function() parent = item:GetAttachParentActor() end)
    if valid(parent) then return "attached to " .. full_name(parent) end
    pcall(function() owner = item:GetOwner() end)
    if valid(owner) then return "owned by " .. full_name(owner) end
    -- An item in a pocket sits where its carrier is.
    local p = loc(item)
    for _, q in ipairs(player_spots()) do
        if p and q and (p.X - q.X) ^ 2 + (p.Y - q.Y) ^ 2 < 40 * 40 then return "on a player" end
    end
    return nil
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
                            local why = why_not_free(it)
                            if why and not skip_logged then
                                skip_logged = true
                                log("goods near a doctor but not lying free: " .. full_name(it) .. " (" .. why .. ")")
                            end
                            if not why then
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
-- A component (or the item itself) and one of its fields.
local function slot_targets(item, slot)
    if slot.comp then return components(item, slot.comp) end
    return { item }
end
local function read_slot(item, slot)
    for _, t in ipairs(slot_targets(item, slot)) do
        local ok, v = pcall(function() return t[slot.prop] end)
        if ok and type(v) == "number" then return v end
    end
    return nil
end
local function write_slot(item, slot, amount)
    local done = false
    for _, t in ipairs(slot_targets(item, slot)) do
        if pcall(function() t[slot.prop] = amount end) then done = true end
    end
    return done
end
local NUMERIC = { IntProperty = true, FloatProperty = true, DoubleProperty = true, Int64Property = true,
                  UInt32Property = true, ByteProperty = true, Int16Property = true, BoolProperty = true }
local function plain_props(obj, stop)
    local out = {}
    local ok_c, cls = pcall(function() return obj:GetClass() end)
    local depth = 0
    while ok_c and valid(cls) and depth < 8 do
        depth = depth + 1
        local cn = full_name(cls)
        if stop and cn:find(stop, 1, true) then break end
        pcall(function()
            cls:ForEachProperty(function(p)
                local n, t = "?", ""
                pcall(function() n = p:GetFName():ToString() end)
                pcall(function() t = p:GetClass():GetFName():ToString() end)
                if NUMERIC[t] then
                    local okv, v = pcall(function() return obj[n] end)
                    out[#out + 1] = n .. "=" .. (okv and tostring(v) or "?")
                end
            end)
        end)
        local oks, sup = pcall(function() return cls:GetSuperStruct() end)
        if not (oks and valid(sup)) then break end
        cls = sup
    end
    return out
end
local structure_logged = false
local function log_cash_structure(item)
    if structure_logged then return end
    structure_logged = true
    local lines = { "cash item structure (" .. full_name(item) .. "):" }
    lines[#lines + 1] = "  item: " .. table.concat(plain_props(item, "/Script/Engine.Actor"), ", ")
    for _, c in ipairs(components(item, "/Script/Engine.ActorComponent")) do
        lines[#lines + 1] = "  " .. full_name(c):match("^(%S+)") .. " " .. (full_name(c):match("([^%.:]+)$") or "")
            .. ": " .. table.concat(plain_props(c, "/Script/Engine.ActorComponent"), ", ")
    end
    log(table.concat(lines, "\n"))
end

local function get_world_and_statics()
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
    return world, gs
end

local function weight(item)
    local ok, w = pcall(function() return item:GetTotalWeight() end)
    return (ok and type(w) == "number") and w or nil
end

-- Cash on the counter. Setting the shown amount alone is not enough: SCUM
-- keeps the real count elsewhere, and 1.0.1's 120 became 1 when picked up.
-- The amount is set and SCUM is told it changed (OnRep_Quantity); whether
-- the real count followed is read from the bundle's weight (every note
-- weighs the same). If it did not, the cash is removed and nothing is paid.
local cash_logged = false
local function pay_cash(pos, amount)
    local cls = get_cash_class()
    if not cls then return false, "Cash class not found" end
    local world, gs = get_world_and_statics()
    if not (valid(gs) and valid(world)) then return false, "no world" end
    local xf = { Rotation = { X = 0, Y = 0, Z = 0, W = 1 },
                 Translation = { X = pos.X, Y = pos.Y, Z = pos.Z + 5 },
                 Scale3D = { X = 1, Y = 1, Z = 1 } }
    local ok, cash = pcall(function()
        local a = gs:BeginDeferredActorSpawnFromClass(world, cls, xf, 1, nil)
        if valid(a) then gs:FinishSpawningActor(a, xf) end
        return a
    end)
    if not (ok and valid(cash)) then return false, "spawn failed" end
    local slot = { comp = "/Script/SCUM.DiscreteAmountItemComponent", prop = "_repQuantity" }
    local before_q = read_slot(cash, slot) or 1
    local w1 = weight(cash)
    write_slot(cash, slot, amount)
    for _, c in ipairs(components(cash, slot.comp)) do
        pcall(function() c:OnRep_Quantity(before_q) end)
    end
    local w2 = weight(cash)
    local want = w1 and (w1 / math.max(1, before_q)) * amount or nil
    local good = want and w2 and want > 0 and math.abs(w2 - want) <= want * 0.1
    if not cash_logged then
        cash_logged = true
        log(string.format("cash paid %d: shown %s, weight %s -> %s (a true count weighs %s)%s", amount,
            tostring(read_slot(cash, slot)), tostring(w1), tostring(w2), tostring(want),
            good and "" or " - the real count did not follow"))
    end
    if not good then
        pcall(log_cash_structure, cash)
        pcall(function() cash:K2_DestroyActor() end)
        return false, "the cash's real count stays 1"
    end
    return true
end

-- SCUM's admin commands as the server runs them (UMiscStatics), and what
-- they are called on this build: written to the log once.
local misc = nil
local function admin(cmd)
    if not valid(misc) then pcall(function() misc = StaticFindObject("/Script/SCUM.Default__MiscStatics") end) end
    local world = get_world_and_statics()
    if not (valid(misc) and valid(world)) then return false, "no MiscStatics/world" end
    local ok, err = pcall(function() misc:Test_ProcessAdminCommand(world, cmd) end)
    return ok, ok and nil or tostring(err)
end
local commands_logged = false
local function log_admin_commands()
    if commands_logged then return end
    commands_logged = true
    local lines = { "SCUM admin commands for money:" }
    for _, n in ipairs({ "ChangeCurrencyBalance", "SetCurrencyBalance", "SpawnItem" }) do
        local cdo = nil
        pcall(function() cdo = StaticFindObject("/Script/SCUM.Default__AdminCommand_" .. n) end)
        if valid(cdo) then
            local verb, args = "?", {}
            pcall(function() verb = cdo._verb:ToString() end)
            pcall(function()
                local list = cdo._argumentDescriptions
                for i = 1, #list do
                    local okn, an = pcall(function() return list[i].Name:ToString() end)
                    args[#args + 1] = okn and an or "?"
                end
            end)
            lines[#lines + 1] = string.format("  %s: #%s %s", n, verb, table.concat(args, " "))
        else
            lines[#lines + 1] = "  " .. n .. ": not found"
        end
    end
    log(table.concat(lines, "\n"))
end

-- The bank: the seller is the player standing nearest the counter, and the
-- money goes to their account with SCUM's own admin command.
local function pay_bank(pos, amount)
    log_admin_commands()
    local best, bd = nil, math.huge
    for _, pc in ipairs(find_all("PlayerController")) do
        pcall(function()
            local pawn = pc.Pawn
            local p = valid(pawn) and loc(pawn) or nil
            if p then
                local d = (p.X - pos.X) ^ 2 + (p.Y - pos.Y) ^ 2
                if d < bd then best, bd = pc, d end
            end
        end)
    end
    if not best or bd > 600 * 600 then return false, "no player at the counter" end
    local name = nil
    pcall(function() name = best.PlayerState:GetPlayerName():ToString() end)
    if not name then pcall(function() name = best.PlayerState._platformPlayerDisplayName:ToString() end) end
    if not name or name == "" then return false, "the seller's name could not be read" end
    local tmpl = CFG.DrugBankCommand or "#ChangeCurrencyBalance Normal {amount} {player}"
    local cmd = tmpl:gsub("{amount}", tostring(amount)):gsub("{player}", name)
    local ok, err = admin(cmd)
    log(string.format("bank payment to %s: %s -> %s", name, cmd, ok and "sent" or ("failed: " .. tostring(err))))
    if not ok then return false, err end
    return true
end

local cash_broken = false
function Bridge.spawn_cash(pos, amount)
    local mode = tostring(CFG.DrugPayment or "auto"):lower()
    if mode ~= "bank" and not cash_broken then
        local ok, why = pay_cash(pos, amount)
        if ok then return true end
        if mode == "cash" then return false, why end
        cash_broken = true
        log("cash cannot hold an amount (" .. tostring(why) .. "): paying to the seller's bank account from now on")
    end
    return pay_bank(pos, amount)
end

-- ----------------------------------------------------------------- loop ---

local state = Dealer.new()
local function tick()
    local ok, err = pcall(Dealer.tick, state, Bridge, CFG, os.time(), log)
    if not ok then log("error: " .. tostring(err)) end
end

log("TESLES DEALER " .. VERSION .. " loaded (sales " .. tostring(CFG.DrugSales ~= false) .. ")")
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
