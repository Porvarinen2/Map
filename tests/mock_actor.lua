-- Mock physical actor used by the movement tests. It approximates how SCUM's
-- character movement responds to a MoveToLocation order: turn towards the
-- commanded point at a limited rate, walk forward, with a little noise so the
-- tests do not pass by being perfectly frictionless.
local U = require("core.util")

local A = {}
A.__index = A

function A.new(pos, opts)
    opts = opts or {}
    return setmetatable({
        pos = U.copy_vec(pos),
        heading = opts.heading or 0,
        speed = opts.speed or 420,             -- UU/s, SCUM walk/jog band
        turn_rate = opts.turn_rate or U.rad(95),  -- rad/s
        noise = opts.noise or U.rad(4),        -- heading noise per second
        target = nil,
        rng = opts.rng,
        trail = { U.copy_vec(pos) },
        reject_rate = opts.reject_rate or 0.0,
        rejects = 0,
    }, A)
end

function A:command(target)
    if self.rng and self.rng:float() < self.reject_rate then
        self.rejects = self.rejects + 1
        return false
    end
    self.target = U.copy_vec(target)
    return true
end

function A:step(dt)
    if not self.target then return end
    local dir, dist = U.direction(self.pos, self.target)
    if not dir or dist < 40 then return end
    local want = math.atan(dir.Y, dir.X)
    local delta = U.angle_delta(self.heading, want)
    local max_turn = self.turn_rate * dt
    if delta > max_turn then delta = max_turn elseif delta < -max_turn then delta = -max_turn end
    self.heading = self.heading + delta
    if self.noise > 0 and self.rng then
        self.heading = self.heading + (self.rng:float() - 0.5) * 2 * self.noise * dt
    end
    -- Speed falls off while turning hard, as a real character does.
    local turn_penalty = 1 - math.min(0.55, math.abs(delta) / max_turn * 0.55)
    local step = math.min(self.speed * dt * turn_penalty, dist)
    self.pos.X = self.pos.X + math.cos(self.heading) * step
    self.pos.Y = self.pos.Y + math.sin(self.heading) * step
    self.trail[#self.trail + 1] = U.copy_vec(self.pos)
end

return A
