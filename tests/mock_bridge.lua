-- Stand-in for bridge/scum.lua used by the world simulation test.
-- It behaves like a cooperative-but-imperfect engine: spawns can fail, move
-- requests are sometimes rejected, and actors move with turn-rate limits.
local U = require("core.util")
local Grid = require("world.navgrid")
local Actor = require("mock_actor")

local B = { health = {}, actors = {}, next = 1, players = {},
            spawn_fail_rate = 0.05, move_reject_rate = 0.05,
            stats = { spawns = 0, fails = 0, moves = 0, rejects = 0, despawns = 0 } }

function B.configure(rng, opts)
    B.rng = rng
    opts = opts or {}
    B.spawn_fail_rate = opts.spawn_fail_rate or B.spawn_fail_rate
    B.move_reject_rate = opts.move_reject_rate or B.move_reject_rate
    B.class_available = opts.class_available ~= false
end

function B.available() return true end
function B.player_positions() return B.players end

function B.spawn_npc(req)
    if not B.class_available then return nil, "NPC_CLASS_UNAVAILABLE" end
    if B.rng:float() < B.spawn_fail_rate then
        B.stats.fails = B.stats.fails + 1
        return nil, "SPAWN_FAILED"
    end
    local h = B.next
    B.next = h + 1
    B.actors[h] = Actor.new(req.position, { rng = B.rng, speed = 400,
                                            reject_rate = B.move_reject_rate })
    B.actors[h].npcId = req.npcId
    B.actors[h].alive = true
    B.stats.spawns = B.stats.spawns + 1
    return h
end

function B.despawn(h)
    if B.actors[h] then B.stats.despawns = B.stats.despawns + 1 end
    B.actors[h] = nil
    return true
end

function B.actor_position(h)
    local a = B.actors[h]
    return a and U.copy_vec(a.pos) or nil
end

function B.is_alive(h)
    local a = B.actors[h]
    return a ~= nil and a.alive
end

function B.actor_health(h)
    local a = B.actors[h]
    return a and (a.hp or 100) or nil
end

function B.move_to(h, dest, opts)
    local a = B.actors[h]
    if not a then return false end
    a.follow = nil
    -- SCUM's navmesh is a small patch around its AI: a pathfinding request
    -- is accepted and then goes nowhere.
    if B.pathfinding_goes_nowhere and not (opts and opts.direct) then
        a.target = nil
        B.stats.moves = B.stats.moves + 1
        return true
    end
    local ok = a:command(dest)
    if ok then B.stats.moves = B.stats.moves + 1 else B.stats.rejects = B.stats.rejects + 1 end
    return ok
end

-- Follow a moving actor until within radius, like MoveToActor: the request
-- ends on arrival.
function B.follow(h, target, radius)
    local a, t = B.actors[h], B.actors[target]
    if not (a and t) then return false end
    if B.rng:float() < B.move_reject_rate then return false end
    a.follow = { h = target, r = radius or 300 }
    B.stats.moves = B.stats.moves + 1
    return true
end

-- Damage like SCUM's ApplyDamage: health goes down, at zero the body dies.
B.damage_calls = 0
function B.apply_damage(h, amount)
    local a = B.actors[h]
    if not a then return false end
    B.damage_calls = B.damage_calls + 1
    a.hp = (a.hp or 100) - amount
    if a.hp <= 0 then a.alive = false; a.target = nil; a.follow = nil end
    return true
end
-- Zombies placed by a test: { pos = {X,Y,Z}, actor = { hp = 100 } }.
B.zombies = {}
function B.zombies_near(pos, radius)
    local out = {}
    for _, z in ipairs(B.zombies) do
        if (z.actor.hp or 100) > 0 and U.dist2d(z.pos, pos) <= radius then out[#out + 1] = z end
    end
    return out
end
B.zombie_damage = 0
function B.damage_actor(actor, amount)
    actor.hp = (actor.hp or 100) - amount
    B.zombie_damage = B.zombie_damage + 1
    return true
end
function B.face() return true end
function B.clear_focus() return true end
function B.fire_once() return true end
function B.note_kill_result(how) B.kill_result = how end

B.brain_checks = 0
function B.keep_ownership(h)
    B.brain_checks = B.brain_checks + 1
    return false
end

function B.walk_speed(h)
    local a = B.actors[h]
    return a and a.speed or nil
end

function B.stop(h)
    local a = B.actors[h]
    if a then a.target = nil end
    return true
end

function B.set_speed(h, v)
    local a = B.actors[h]
    if a then a.speed = v end
    return true
end

function B.ground_at(pos) return pos.Z end
function B.nearby_zombies() return 0 end
function B.find_buildings() return nil end
function B.aim_at() return true end
function B.start_fire() return true end
function B.stop_fire() return true end
B.owned = 0
function B.take_ownership(h)
    if B.actors[h] then B.owned = B.owned + 1; return true end
    return false
end

-- Advance every spawned actor by dt seconds.
function B.step(dt)
    local sub = 0.25
    local n = math.max(1, math.floor(dt / sub))
    for _ = 1, n do
        for _, a in pairs(B.actors) do
            if a.alive and a.follow then
                local t = B.actors[a.follow.h]
                if not t then a.follow = nil
                elseif U.dist2d(a.pos, t.pos) <= a.follow.r then
                    a.follow, a.target = nil, nil
                else
                    a.target = U.copy_vec(t.pos)
                end
            end
            if a.alive then a:step(sub) end
        end
    end
end

function B.reset()
    B.actors = {}
    B.owned = 0
    B.next = 1
    B.stats = { spawns = 0, fails = 0, moves = 0, rejects = 0, despawns = 0 }
end

return B
