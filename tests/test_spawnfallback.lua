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
local c, fam, var, lv = B.class_for(3, nil, "Guard")
check(c and fam == "Guard" and lv == 3 and var == nil, "other classes unaffected")
if fails > 0 then os.exit(1) end
print("spawn fallback: all ok")
