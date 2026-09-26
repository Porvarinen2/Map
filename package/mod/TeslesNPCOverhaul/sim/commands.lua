-- Commands from the live map: spawn a squad at a spot, remove a squad.
--
-- The map's server appends one command per line to output/commands.txt:
--   <id> spawn <class> <size> <x> <y>
--   <id> remove <gid>
-- Every couple of seconds the director takes the file (rename first, so a
-- line written meanwhile lands in a fresh file and is not lost), runs each
-- command, and reports the outcome in the live state for the map to show.
local Lang = require("core.lang")
local U = require("core.util")
local Grid = require("world.navgrid")
local Zones = require("world.zones")
local POI = require("world.pois")
local GroupClasses = require("npc.groups")
local Factory = require("npc.factory")
local Population = require("sim.population")
local Physical = require("sim.physical")
local Log = require("core.log")

local C = {}

C.dir = nil
C.sep = "/"
C.interval = 2
C.MAX_RESULTS = 12

function C.configure(dir, sep)
    C.dir, C.sep = dir, sep or "/"
end

local function result(director, id, ok, text)
    director.command_results = director.command_results or {}
    local list = director.command_results
    list[#list + 1] = { id = id, ok = ok, text = text, t = director.now }
    while #list > C.MAX_RESULTS do table.remove(list, 1) end
    Log.event(ok and "COMMAND" or "COMMAND_FAIL", "MAP", text)
end

-- Spawns a squad of `class` at x, y. Refuses what the world's rules forbid:
-- water, the outposts, and the C0 radiation zone for anyone but the radiation
-- squads (and those outside it).
function C.spawn(director, id, class, size, x, y)
    local cls = GroupClasses.get(class)
    if not cls then return result(director, id, false, Lang.pick("tuntematon luokka: ", "unknown class: ") .. tostring(class)) end
    local pos = { X = x, Y = y, Z = 0 }
    if not (U.finite_vec(pos) and Zones.sector(pos) ~= "OUT") then
        return result(director, id, false, Lang.pick("piste on kartan ulkopuolella", "the point is outside the map"))
    end
    if not Grid.is_passable(pos) then
        local land = Grid.snap_to_land(pos)
        if not land or U.dist2d(land, pos) > 20000 then
            return result(director, id, false, Lang.pick("piste on vedessä", "the point is in water"))
        end
        pos = land
    end
    if POI.near_outpost and POI.near_outpost(pos) then
        return result(director, id, false, Lang.pick("outpostin lähellä ei saa olla NPC:itä", "no NPCs near an outpost"))
    end
    local zone = Zones.reserved_at(pos)
    local own_zone = Zones.reserved_by_class[class]
    if zone and zone.class ~= class then
        return result(director, id, false, Lang.t(zone.fi) .. Lang.pick(" on vain luokalle ", " is only for class ") .. zone.class)
    end
    if own_zone and zone ~= own_zone then
        return result(director, id, false, class .. Lang.pick(" pysyy alueella ", " stays in ") .. Lang.t(own_zone.fi))
    end
    local world = director.world
    size = math.floor(tonumber(size) or cls.size[1])
    size = math.max(cls.size[1], math.min(cls.size[2], size))
    local g = Factory.new_group({
        id = world.next_group_id, class = class,
        seed = director.rng:int(1, 2 ^ 30), position = pos, home = pos, size = size,
        zone = zone and zone.key or nil,
    })
    Population.add_group(world, g)
    result(director, id, true, string.format(Lang.pick("%s (%s, %d NPC) spawnattu %s", "%s (%s, %d NPCs) spawned in %s"), g.gid, Lang.t(cls.fi),
        #g.members, Zones.sector(pos)))
    return g
end

function C.remove(director, id, gid)
    local world = director.world
    local g = world.by_gid[gid]
    if not g then return result(director, id, false, Lang.pick("ryhmää ", "no squad ") .. tostring(gid) .. Lang.pick(" ei ole", "")) end
    if g.physical then Physical.virtualize(g, director.bridge, {}) end
    for i, x in ipairs(world.groups) do
        if x == g then table.remove(world.groups, i); break end
    end
    world.by_gid[gid] = nil
    result(director, id, true, gid .. Lang.pick(" poistettu", " removed"))
    return true
end

function C.run_line(director, line)
    local parts = {}
    for w in tostring(line):gmatch("%S+") do parts[#parts + 1] = w end
    local id, op = parts[1], parts[2]
    if not (id and op) then return end
    if op == "spawn" then
        C.spawn(director, id, parts[3], tonumber(parts[4]), tonumber(parts[5]), tonumber(parts[6]))
    elseif op == "remove" then
        C.remove(director, id, parts[3])
    else
        result(director, id, false, Lang.pick("tuntematon komento ", "unknown command ") .. op)
    end
end

function C.poll(director, now)
    if not C.dir then return end
    if now - (director.commands_at or 0) < C.interval then return end
    director.commands_at = now
    local file = C.dir .. C.sep .. "commands.txt"
    local work = C.dir .. C.sep .. "commands.processing"
    if not os.rename(file, work) then return end
    local f = io.open(work, "r")
    if not f then return end
    local text = f:read("*a") or ""
    f:close()
    os.remove(work)
    for line in text:gmatch("[^\r\n]+") do
        local ok, err = pcall(C.run_line, director, line)
        if not ok then result(director, "?", false, Lang.pick("komento epäonnistui: ", "command failed: ") .. tostring(err)) end
    end
end

return C
