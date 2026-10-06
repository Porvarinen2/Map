-- A class whose spawns keep failing is benched and the NPC gets the nearest
-- working body (1.9.47: plain level 5 Guards never spawned).
package.path = "../package/mod/TeslesNPCOverhaul/?.lua;./?.lua;" .. package.path
local fails = 0
local function check(c, m) if c then print("  ok  " .. m) else print("FAIL: " .. m); fails = fails + 1 end end

local function obj(name, extra)
    local o = extra or {}
    o._name = name
    o.IsValid = function() return true end
    o.GetFullName = function() return name end
    o.GetWorld = function() return obj("World /Game/World") end
    return setmetatable(o, { __tostring = function() return name end })
end
local spawned = {}
local helper = obj("AIBlueprintHelperLibrary Default__AIBlueprintHelperLibrary")
helper.SpawnAIFromClass = function(_, _, cls, _, pos)
    if cls._name:find("BP_Guard_Lvl_5%.") then return nil end
    spawned[#spawned + 1] = cls._name
    return obj("Pawn " .. cls._name .. "_" .. #spawned, { K2_GetActorLocation = function() return pos end })
end
_G.StaticFindObject = function(path)
    if path:find("AIBlueprintHelperLibrary") then return helper end
    if path:find("/Guard/") or path:find("/Drifter/") then return obj("BlueprintGeneratedClass " .. path) end
    return nil
end
_G.FindFirstOf = function(s) if s == "ConZGameMode" then return obj("ConZGameMode GM") end end
_G.LoadAsset = function() end

local B = require("bridge.scum")
B.cfg = {}
local req = { level = 5, family = "Guard", position = { X = 1000, Y = 2000, Z = 300 }, group = "G", npcId = "N" }
local r1 = B.spawn_npc(req)
check(r1 == nil, "plain level 5 Guard fails")
for _ = 1, 3 do B.spawn_npc(req) end
check(#spawned == 3, "the next tries spawn in another body: " .. #spawned)
for _, n in ipairs(spawned) do
    check(n:find("BP_Guard_Lvl_5_AbandonedBunker") ~= nil, "fallback is the level 5 Abandoned Bunker Guard")
end
check(B.class_fails["Guard5"] and B.class_fails["Guard5"].n >= 1, "the failing class is remembered")
do
    local h = B.spawn_npc(req)
    if h then
        check(B.set_pose(h, "walk") == true and B.set_pose(h, "face") == true and B.release_pose(h) == true,
              "walking / facing poses can be set on a spawned NPC")
    end
end
do
    local h = B.spawn_npc(req)
    local h2 = B.spawn_npc(req)
    if h and h2 then
        local ok, sp = B.set_speed(h, 135)
        check(ok and sp == 135, "walking is SCUM's walk pace (135)")
        local pace = nil
        pcall(function() pace = B.actor(h)._pace end)
        check(pace == 0, "a walk is pace 0 (Slow): pace 1 played the jog at walking speed")
        ok, sp = B.set_speed(h, 262)
        check(ok and sp == 262, "a jog is SCUM's jog pace (262)")
        ok, sp = B.set_speed(h, 450)
        check(ok and sp == 600, "anything faster is SCUM's run pace (600), never a speed of our own")
        check(B.aim_at(h, { X = 0, Y = 0, Z = 0 }, h2) == true, "an NPC aims at another NPC's body")
    end
end
local c, fam, var, lv = B.class_for(3, nil, "Guard")
check(c and fam == "Guard" and lv == 3 and var == nil, "other classes unaffected")
for _, n in ipairs({ "BP_Bear_C", "BP_Bear_Mutant_C", "BP_BTBear_Mutant_ApexHunt_C", "BP_Wolf_C", "BP_Wolf_Mutant_C" }) do
    check(B.is_predator(n), n .. " is shot by every squad")
end
for _, n in ipairs({ "BP_Deer_C", "BP_Deer_Mutant_C", "BP_Boar_C", "BP_Boar_Mutant_C", "BP_Goat_C", "BP_Chicken_C",
                     "BP_Rabbit_C", "BP_Horse_C", "BP_Donkey_C" }) do
    check(not B.is_predator(n), n .. " is game: hunters only")
end
if fails > 0 then os.exit(1) end
print("spawn fallback: all ok")
