-- Deterministic seeded RNG (xorshift128). The same seed must always rebuild
-- the same personality, so this never touches math.random's global state.
local RNG = {}
RNG.__index = RNG

local function u32(v) return v % 0x100000000 end

local function bxor(a, b)
    local r, bit = 0, 1
    for _ = 1, 32 do
        local x, y = a % 2, b % 2
        if x ~= y then r = r + bit end
        a, b, bit = (a - x) / 2, (b - y) / 2, bit * 2
    end
    return r
end

local function lshift(v, n) return u32(v * (2 ^ n)) end
local function rshift(v, n) return math.floor(v / (2 ^ n)) end

function RNG.new(seed)
    local s = math.floor(math.abs(tonumber(seed) or os.time())) % 0x100000000
    if s == 0 then s = 0x9E3779B9 end
    local o = setmetatable({}, RNG)
    o.a = u32(s)
    o.b = u32(s * 1103515245 + 12345)
    o.c = u32(bxor(o.a, 0x5DEECE66) + 7)
    o.d = u32(o.b + 0x9E3779B9)
    for _ = 1, 8 do o:next() end
    return o
end

function RNG:next()
    local t = self.d
    local s = self.a
    self.d, self.c, self.b = self.c, self.b, s
    t = bxor(t, lshift(t, 11))
    t = bxor(t, rshift(t, 8))
    self.a = u32(bxor(bxor(t, s), rshift(s, 19)))
    return self.a
end

-- Uniform float in [0,1).
function RNG:float() return self:next() / 0x100000000 end

-- Uniform float in [lo,hi).
function RNG:range(lo, hi) return lo + (hi - lo) * self:float() end

-- Uniform integer in [lo,hi].
function RNG:int(lo, hi)
    if hi == nil then lo, hi = 1, lo end
    if hi < lo then return lo end
    return lo + math.floor(self:float() * (hi - lo + 1))
end

function RNG:chance(p) return self:float() < p end

function RNG:pick(list)
    if not list or #list == 0 then return nil end
    return list[self:int(1, #list)]
end

-- Roughly normal distribution clamped to [lo,hi]; used for trait spread so
-- most individuals sit near the archetype mean with rare outliers.
function RNG:gauss(mean, sd, lo, hi)
    local s = (self:float() + self:float() + self:float() + self:float()
        + self:float() + self:float() - 3) / 1.5
    local v = mean + s * sd
    if lo and v < lo then v = lo end
    if hi and v > hi then v = hi end
    return v
end

return RNG
