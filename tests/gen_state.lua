-- Produces a realistic live_state.json so the live map can be verified
-- against real director output rather than hand-written sample data.
package.path = "../package/mod/TeslesNPCOverhaul/?.lua;./?.lua;" .. package.path
local U = require("core.util")
local RNG = require("core.rng")
local Log = require("core.log")
local POI = require("world.pois")
local Population = require("sim.population")
local Director = require("sim.director")
local Telemetry = require("bridge.telemetry")
local Bridge = require("mock_bridge")
Log.configure(nil, "info", false)

local rng = RNG.new(31337)
Bridge.configure(rng, { spawn_fail_rate = 0.06, move_reject_rate = 0.06 })
Bridge.health = {
  brain = { status = "OK", detail = "initialized" },
  worldRouting = { status = "OK", detail = "dry-land grid 512x512 / 285 POIs" },
  persistence = { status = "OK", detail = "world state loaded" },
  worldPopulation = { status = "OK", detail = "101 persistent NPCs / 32 groups" },
  scumAdapter = { status = "OK", detail = "bridge scheduler online" },
  spawnCatalog = { status = "OK", detail = "10 NPC classes resolved" },
  physicalVirtualization = { status = "OK", detail = "43 actors materialized this session" },
  takeover = { status = "OK", detail = "director owns stop+brain" },
  physicalCombat = { status = "DEGRADED", detail = "aim issued; weapon fire and damage unverified" },
  buildingSearch = { status = "PENDING", detail = "waiting for live proof: building_discovery, door_discovery, door_interaction, interior_navigation" },
  ue4ssCore = { status = "OK", detail = "UE4SS v3.0.1 Beta / Git SHA 662df915" },
}

local world = Population.new_world({ seed = 20260921, target_npcs = 100 })
Population.generate(world)
local director = Director.new({ world = world, bridge = Bridge, seed = 4242,
  config = { RouteSolvesPerTick = 2, RouteExpansionsPerTick = 7000 } })

local player = { pos = U.copy_vec(POI.points[1].pos), goal = nil }
local now = os.time()
for step = 1, 5400 do
  now = now + 1
  if not player.goal or U.dist2d(player.pos, player.goal) < 3000 then
    player.goal = U.copy_vec(POI.points[rng:int(1, POI.count)].pos)
  end
  local d = U.direction(player.pos, player.goal)
  if d then
    player.pos.X = player.pos.X + d.X * 500
    player.pos.Y = player.pos.Y + d.Y * 500
  end
  Bridge.players = { player.pos }
  Bridge.step(1)
  director:tick(now)
end

Telemetry.configure("/home/user/Map/build/webroot")
local ok = Telemetry.write(world, Bridge, director,
  { version = "1.0.0", uptime = 5400 })
print("wrote live_state.json:", ok)
local snap = Telemetry.snapshot(world, Bridge, director, { version = "1.0.0", uptime = 5400 })
print(string.format("groups=%d npcs=%d physical=%d events=%d",
  #snap.groups, snap.stats.npcs, snap.stats.physical, #snap.events))
