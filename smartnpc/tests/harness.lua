-- SmartNPC offline test harness.
-- Emulates enough of UE4SS + Unreal path following to exercise the real mod
-- code (world/squad/body/director/telemetry) without a game running.
--
--   lua5.4 tests/harness.lua [seconds] [npc_count]
--
-- It reports the metrics that matter for the zig-zag problem:
--   * MoveTo commands issued per kilometre walked
--   * heading wiggle: summed |turn| per kilometre  (a straight walk is ~0)
--   * how many squads actually completed routes

local SECONDS = tonumber(arg and arg[1]) or 900
local NPCS    = tonumber(arg and arg[2]) or 48
local FORCE_PHYSICAL = (arg and arg[3] == "physical")

--------------------------------------------------------------------------
-- fake clock
--------------------------------------------------------------------------
local SIMT = 0
local real_time = os.time
os.clock = function() return SIMT end
os.time = function() return 1700000000 + math.floor(SIMT) end

--------------------------------------------------------------------------
-- fake engine
--------------------------------------------------------------------------
local ENGINE = {
    pawns = {},            -- list of fake pawns
    commands = 0,
    failed = 0,
    blocked_until = {},
}

local next_addr = 0x10000

local Vec = function(x, y, z) return { X = x, Y = y, Z = z } end

local Ctrl = {}
Ctrl.__index = Ctrl

function Ctrl:IsValid() return true end
function Ctrl:GetFullName() return "Controller " .. self.name end
function Ctrl:GetAddress() return self.addr end
function Ctrl:GetPropertyValue(n)
    if n == "Pawn" then return self.pawn end
    if n == "BrainComponent" then return self.brain end
    return self.props[n]
end
function Ctrl:SetPropertyValue(n, v) self.props[n] = v end
function Ctrl:GetMoveStatus() return self.status end
function Ctrl:StopMovement() self.status = 0; self.target = nil end
function Ctrl:K2_SetFocalPoint(v) self.focus = v end
function Ctrl:K2_ClearFocus() self.focus = nil end
function Ctrl:MoveToLocation(dest, accept, stopOverlap, usePath, project, strafe, filter, partial)
    ENGINE.commands = ENGINE.commands + 1
    self.pawn.cmds = (self.pawn.cmds or 0) + 1
    -- Unreal refuses a request whose destination cannot be projected.
    if dest == nil or dest.X ~= dest.X then ENGINE.failed = ENGINE.failed + 1; return 0 end
    self.target = { x = dest.X, y = dest.Y }
    self.accept = accept or 220
    self.status = 3
    return 2
end

local Brain = {}
Brain.__index = Brain
function Brain:IsValid() return true end
function Brain:GetFullName() return "Brain" end
function Brain:GetAddress() return self.addr end
function Brain:GetPropertyValue(n) return self.props[n] end
function Brain:SetPropertyValue(n, v) self.props[n] = v end
function Brain:StopLogic(reason) self.running = false; self.stops = (self.stops or 0) + 1 end
function Brain:RestartLogic() self.running = true end

local Move = {}
Move.__index = Move
function Move:IsValid() return true end
function Move:GetFullName() return "CharacterMovement" end
function Move:GetAddress() return self.addr end
function Move:GetPropertyValue(n) return self.props[n] end
function Move:SetPropertyValue(n, v) self.props[n] = v end

local Pawn = {}
Pawn.__index = Pawn
function Pawn:IsValid() return self.alive end
function Pawn:GetFullName() return "BP_Drifter_Lvl_3_C " .. self.name end
function Pawn:GetAddress() return self.addr end
function Pawn:GetClass() return self.cls end
function Pawn:GetPropertyValue(n)
    if n == "Controller" then return self.ctrl end
    if n == "CharacterMovement" then return self.move end
    return self.props[n]
end
function Pawn:SetPropertyValue(n, v) self.props[n] = v end
function Pawn:GetController() return self.ctrl end
function Pawn:K2_GetActorLocation() return Vec(self.x, self.y, self.z) end
function Pawn:K2_GetActorRotation() return { Pitch = 0, Yaw = self.yaw, Roll = 0 } end
function Pawn:K2_DestroyActor() self.alive = false; self.destroyed = true end
function Pawn:K2_TeleportTo(loc, rot)
    self.x, self.y, self.z = loc.X, loc.Y, loc.Z
    self.teleports = (self.teleports or 0) + 1
    self.ctrl.status = 0
    self.ctrl.target = nil
    return true
end

local FakeClass = { IsValid = function() return true end,
                    GetFullName = function() return "BlueprintGeneratedClass BP_Drifter_Lvl_3_C" end,
                    GetAddress = function() return 0x999 end }
FakeClass.__index = FakeClass
local CLS = setmetatable({}, FakeClass)

local function new_pawn(x, y, name)
    next_addr = next_addr + 16
    local mv = setmetatable({ addr = next_addr + 1, props = { MaxWalkSpeed = 300 } }, Move)
    next_addr = next_addr + 16
    local br = setmetatable({ addr = next_addr + 2, props = {}, running = true }, Brain)
    next_addr = next_addr + 16
    local p = setmetatable({
        addr = next_addr, name = name, alive = true,
        x = x, y = y, z = 100, yaw = math.random(0, 359),
        props = {}, move = mv, cls = CLS,
        travelled = 0, wiggle = 0, cmds = 0,
    }, Pawn)
    next_addr = next_addr + 16
    local c = setmetatable({
        addr = next_addr, name = name, pawn = p, brain = br,
        props = {}, status = 0,
    }, Ctrl)
    p.ctrl = c
    ENGINE.pawns[#ENGINE.pawns + 1] = p
    return p
end

-- Unreal-ish path following: walk toward the request target, turning at a
-- limited rate, and report Idle once inside the acceptance radius.
local function engine_step(dt)
    for _, p in ipairs(ENGINE.pawns) do
        if p.alive then
            local c = p.ctrl
            if c.status == 3 and c.target then
                local speed = p.move.props.MaxWalkSpeed or 300
                local rate  = p.move.props.RotationRate and p.move.props.RotationRate.Yaw or 180
                local dx, dy = c.target.x - p.x, c.target.y - p.y
                local d = math.sqrt(dx * dx + dy * dy)
                if d <= (c.accept or 220) then
                    c.status = 0
                    c.target = nil
                else
                    local want = math.deg(math.atan(dy, dx)) % 360
                    local delta = (want - p.yaw + 540) % 360 - 180
                    local step = math.min(math.abs(delta), rate * dt) * (delta >= 0 and 1 or -1)
                    p.yaw = (p.yaw + step) % 360
                    p.wiggle = p.wiggle + math.abs(step)
                    -- blocked pawns stop making progress but stay "Moving",
                    -- exactly like a pawn jammed against world geometry
                    local blocked = ENGINE.blocked_until[p] and ENGINE.blocked_until[p] > SIMT
                    if not blocked then
                        local adv = math.min(speed * dt, d)
                        local rad = math.rad(p.yaw)
                        p.x = p.x + math.cos(rad) * adv
                        p.y = p.y + math.sin(rad) * adv
                        p.travelled = p.travelled + adv
                    end
                end
            end
        end
    end
end

--------------------------------------------------------------------------
-- fake AI helper / navigation system / world
--------------------------------------------------------------------------
local FakeWorld = { IsValid = function() return true end,
                    GetFullName = function() return "World Level" end,
                    GetAddress = function() return 0x1 end }
FakeWorld.__index = FakeWorld
local WORLD = setmetatable({}, FakeWorld)

local Helper = {}
Helper.__index = Helper
function Helper:IsValid() return true end
function Helper:GetFullName() return "AIBlueprintHelperLibrary" end
function Helper:GetAddress() return 0x2 end
function Helper:SpawnAIFromClass(world, cls, bt, loc, rot, noCollisionFail, owner)
    ENGINE.spawned = (ENGINE.spawned or 0) + 1
    local p = new_pawn(loc.X, loc.Y, "spawn" .. ENGINE.spawned)
    p.z = loc.Z
    return p
end
local HELPER = setmetatable({}, Helper)

local Nav = {}
Nav.__index = Nav
function Nav:IsValid() return true end
function Nav:GetFullName() return "NavigationSystemV1" end
function Nav:GetAddress() return 0x3 end
function Nav:K2_ProjectPointToNavigation(world, point, out, a, b, extent, extra)
    out.X, out.Y, out.Z = point.X, point.Y, 120
    return true
end
local NAV = setmetatable({}, Nav)

--------------------------------------------------------------------------
-- UE4SS globals
--------------------------------------------------------------------------
function FindAllOf(name)
    if name == "BP_Drifter_Lvl_3_C" then
        local out = {}
        for _, p in ipairs(ENGINE.pawns) do if p.alive then out[#out + 1] = p end end
        return out
    end
    return nil
end
function FindFirstOf(name)
    if name == "World" then return WORLD end
    if name == "NavigationSystemV1" then return NAV end
    if name == "BP_Drifter_Lvl_3_C" then
        for _, p in ipairs(ENGINE.pawns) do if p.alive then return p end end
    end
    return nil
end
function StaticFindObject(path)
    if path:find("AIBlueprintHelperLibrary") then return HELPER end
    if path:find("NavigationSystemV1") then return NAV end
    return nil
end

local loop_cb = nil
function LoopAsync(ms, cb) loop_cb = cb end
function ExecuteInGameThread(cb) cb() end

--------------------------------------------------------------------------
-- run
--------------------------------------------------------------------------
local here = (arg and arg[0] or ""):match("^(.*)[/\\][^/\\]+$") or "."
SMARTNPC_ROOT = here .. "/../package/payload/SmartNPC"

math.randomseed(20260916)

-- Sprinkle NPCs across known-good land anchors.
dofile(SMARTNPC_ROOT .. "/lua/boot.lua")

local S = SMARTNPC
local W, D, U, C = S.world, S.director, S.util, S.config

local anchors = dofile(SMARTNPC_ROOT .. "/data/pois.lua").anchors.points
-- Clustered so real squads form and formation lanes get exercised.
local per_squad = 4
local made = 0
local ai = 0
while made < NPCS do
    ai = ai + 1
    local a = anchors[((ai - 1) % #anchors) + 1]
    local n = math.min(per_squad, NPCS - made)
    for k = 1, n do
        new_pawn(a.x + math.random(-1800, 1800), a.y + math.random(-1800, 1800), "npc" .. (made + k))
    end
    made = made + n
end

-- A player wandering the island so squads cross the materialise/virtualise
-- boundary repeatedly during the run.
local player_pawn = { x = -69660, y = 156358, z = 100 }
local pdir = 0
D.scan_players = function()
    pdir = pdir + 0.004
    player_pawn.x = -69660 + math.cos(pdir) * 380000
    player_pawn.y = 156358 + math.sin(pdir) * 300000
    D.players = { { x = player_pawn.x, y = player_pawn.y, z = player_pawn.z } }
    return 1
end
C.PlayerDetectRadiusUU  = 0        -- no combat hand-over; test travel only
C.SpawnOwnPopulation    = (arg and arg[3] == "population") or false
C.StartupDelaySec       = 1
if FORCE_PHYSICAL then
    C.MaterializeDistanceUU = 5.0e6
    C.VirtualizeDistanceUU  = 9.0e6
end

local DT = 0.2
local steps = math.floor(SECONDS / DT)
local plans, stops, unsticks, routefails = 0, 0, 0, 0
local materialized, virtualized = 0, 0
local real_event = S.telemetry.event
S.telemetry.event = function(kind, who, what)
    if kind == "PLAN" then plans = plans + 1
    elseif kind == "STOP" then stops = stops + 1
    elseif kind == "UNSTICK" then unsticks = unsticks + 1
    elseif kind == "ROUTE_FAIL" then routefails = routefails + 1
    elseif kind == "MATERIALIZE" then materialized = materialized + 1
    elseif kind == "VIRTUALIZE" then virtualized = virtualized + 1 end
    return real_event(kind, who, what)
end

local map_distance = 0
local last_sq_pos = {}

for i = 1, steps do
    SIMT = SIMT + DT
    -- randomly jam ~1.5% of pawns for a few seconds to exercise the stall ladder
    if i % 50 == 0 then
        for _, p in ipairs(ENGINE.pawns) do
            if math.random() < 0.015 then ENGINE.blocked_until[p] = SIMT + math.random(4, 12) end
        end
    end
    engine_step(DT)
    if loop_cb then loop_cb() end
    if i % 5 == 0 then
        for id, sq in pairs(D.squads) do
            if sq.pos then
                local prev = last_sq_pos[id]
                if prev then
                    local d = U.dist2(prev, sq.pos)
                    if d < 20000 then map_distance = map_distance + d end
                end
                last_sq_pos[id] = { x = sq.pos.x, y = sq.pos.y }
            end
        end
    end
end

--------------------------------------------------------------------------
-- report
--------------------------------------------------------------------------
local dist, wig, cmds, tps, brainstops = 0, 0, 0, 0, 0
for _, p in ipairs(ENGINE.pawns) do
    dist = dist + p.travelled
    wig  = wig + p.wiggle
    cmds = cmds + (p.cmds or 0)
    tps  = tps + (p.teleports or 0)
    brainstops = brainstops + (p.ctrl.brain.stops or 0)
end
local km = dist / 100000

local function line(k, v) print(string.format("  %-26s %s", k, v)) end
print("")
print("SmartNPC harness  ---------------------------------------------")
line("simulated", string.format("%.0f s  (%d pawns)", SECONDS, NPCS))
line("distance walked", string.format("%.2f km", km))
line("MoveTo commands", tostring(cmds))
line("commands / km", km > 0 and string.format("%.1f", cmds / km) or "-")
line("heading wiggle / km", km > 0 and string.format("%.0f deg", wig / km) or "-")
line("failed requests", tostring(ENGINE.failed))
line("brain StopLogic calls", tostring(brainstops))
line("unstick teleports", tostring(tps))
line("plans / stops", plans .. " / " .. stops)
line("route failures", tostring(routefails))
line("squads", tostring(D.squad_count()))
line("materialize / virtualize", materialized .. " / " .. virtualized)
line("map distance (all squads)", string.format("%.2f km", map_distance / 100000))
line("pawns spawned / destroyed", tostring(ENGINE.spawned or 0) .. " / " .. (function()
    local n = 0
    for _, p in ipairs(ENGINE.pawns) do if p.destroyed then n = n + 1 end end
    return n
end)())
line("pawns left standing idle", (function()
    local n = 0
    for _, p in ipairs(ENGINE.pawns) do
        if p.alive and p.ctrl.status ~= 3 then n = n + 1 end
    end
    return n
end)())
line("tick avg", string.format("%.2f ms", S.last_tick_ms or 0))
print("")

-- Route geometry check: no node may sit on water, and turns must stay sane.
local bad_water, sharp, nodes, maxturn = 0, 0, 0, 0
for _, sq in pairs(D.squads) do
    if sq.route then
        for i, n in ipairs(sq.route.nodes) do
            nodes = nodes + 1
            if W.is_water(n) then bad_water = bad_water + 1 end
        end
        for i, t in pairs(sq.route.turn) do
            if t > 100 then sharp = sharp + 1 end
            if t > maxturn then maxturn = t end
        end
    end
end
line("route nodes checked", tostring(nodes))
line("nodes on water", tostring(bad_water))
line("turns > 100 deg", tostring(sharp))
line("max turn", string.format("%.0f deg", maxturn))
print("")

local fail = false
local function check(name, ok, detail)
    print(string.format("  [%s] %s  %s", ok and "PASS" or "FAIL", name, detail or ""))
    if not ok then fail = true end
end
check("world is moving", (km + map_distance / 100000) > 1.0,
      string.format("%.2f km physical + %.2f km on map", km, map_distance / 100000))
if km > 0.5 then
    check("command rate is low", (cmds / km) < 60, string.format("%.1f / km", cmds / km))
    check("no zig-zag", (wig / km) < 4000, string.format("%.0f deg / km", wig / km))
else
    print("  [skip] command rate / zig-zag: not enough physical walking in this mode")
end
check("routes avoid water", bad_water == 0, bad_water .. " bad nodes")
check("squads made plans", plans > 0, plans .. " plans")
for _, sq in pairs(D.squads) do
    if sq.virtual and #sq.members > 0 then
        print(string.format("  STRANDED %s native=%s state=%s members=%d pending=%s dist=%s",
            sq.id, tostring(sq.native), sq.state, #sq.members,
            tostring(sq.pending_spawn), tostring(sq.player_dist)))
    end
end
check("no stranded bodies", (function()
    local n = 0
    for _, sq in pairs(D.squads) do
        if sq.virtual and #sq.members > 0 then n = n + 1 end
    end
    return n
end)() == 0, "virtual squads never keep bodies")
print("")
os.exit(fail and 1 or 0)
