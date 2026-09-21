-- Dumps simulated group trails so they can be drawn over the map image.
package.path = "../package/mod/TeslesNPCOverhaul/?.lua;./?.lua;" .. package.path
local U = require("core.util")
local RNG = require("core.rng")
local Log = require("core.log")
local POI = require("world.pois")
local Grid = require("world.navgrid")
local Population = require("sim.population")
local Director = require("sim.director")
local Bridge = require("mock_bridge")
Log.configure(nil, "error", false)

local rng = RNG.new(31337)
Bridge.configure(rng, { spawn_fail_rate = 0.06, move_reject_rate = 0.06 })
local world = Population.new_world({ seed = 20260921, target_npcs = 100 })
Population.generate(world)
local director = Director.new({ world = world, bridge = Bridge, seed = 4242,
    config = { RouteSolvesPerTick = 2, RouteExpansionsPerTick = 7000 } })

local player = { pos = U.copy_vec(POI.points[1].pos), goal = nil }
local trails = {}
for _, g in ipairs(world.groups) do trails[g.gid] = {} end

local now = os.time()
for step = 1, 14400 do
    now = now + 1
    if not player.goal or U.dist2d(player.pos, player.goal) < 3000 then
        player.goal = U.copy_vec(POI.points[rng:int(1, POI.count)].pos)
    end
    local dir = U.direction(player.pos, player.goal)
    if dir then
        player.pos.X = player.pos.X + dir.X * 500
        player.pos.Y = player.pos.Y + dir.Y * 500
    end
    Bridge.players = { player.pos }
    Bridge.step(1)
    director:tick(now)
    if step % 5 == 0 then
        for _, g in ipairs(world.groups) do
            if g.position then
                if not Grid.is_passable(g.position) and (_G.__shown or 0) < 3 then
                    _G.__shown = (_G.__shown or 0) + 1
                    print(string.format("LIVE WATER %s step=%d phys=%s state=%s pos=%.2f,%.2f",
                        g.gid, step, tostring(g.physical), g.act.state, g.position.X, g.position.Y))
                end
                local t = trails[g.gid]
                t[#t + 1] = string.format("%.0f,%.0f,%s%s%s", g.position.X, g.position.Y,
                    g.act.state == "TRAVEL" and "T" or "W",
                    g.physical and "P" or "V",
                    g.mv.route and "R" or "-")
            end
        end
    end
end

local f = io.open("/home/user/Map/build/sim_trails.txt", "w")
for gid, t in pairs(trails) do
    f:write(gid .. "|" .. table.concat(t, ";") .. "\n")
end
f:close()
print("dumped " .. #world.groups .. " trails over 4 simulated hours")
