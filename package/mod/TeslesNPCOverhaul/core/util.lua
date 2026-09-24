-- TESLES NPC OVERHAUL - shared helpers. No engine calls live in this file.
local U = {}

local floor, sqrt, huge = math.floor, math.sqrt, math.huge

function U.clamp(v, lo, hi)
    if v ~= v then return lo end
    if v < lo then return lo end
    if v > hi then return hi end
    return v
end

function U.num(v, default)
    local n = tonumber(v)
    if n == nil or n ~= n or n == huge or n == -huge then return default end
    return n
end

function U.round(v) return floor(v + 0.5) end

function U.copy_vec(v)
    if not v then return nil end
    return { X = v.X or 0, Y = v.Y or 0, Z = v.Z or 0 }
end

-- Planar distance. Height differences are ignored for navigation decisions;
-- the LOD code applies its own 3D check where altitude actually matters.
function U.dist2d(a, b)
    if not a or not b then return huge end
    local dx = (a.X or 0) - (b.X or 0)
    local dy = (a.Y or 0) - (b.Y or 0)
    return sqrt(dx * dx + dy * dy)
end

function U.dist3d(a, b)
    if not a or not b then return huge end
    local dx = (a.X or 0) - (b.X or 0)
    local dy = (a.Y or 0) - (b.Y or 0)
    local dz = (a.Z or 0) - (b.Z or 0)
    return sqrt(dx * dx + dy * dy + dz * dz)
end

-- Unit vector from a to b, or nil when the two points coincide.
function U.direction(a, b)
    local dx = (b.X or 0) - (a.X or 0)
    local dy = (b.Y or 0) - (a.Y or 0)
    local len = sqrt(dx * dx + dy * dy)
    if len < 1e-4 then return nil, 0 end
    return { X = dx / len, Y = dy / len, Z = 0 }, len
end

function U.heading(a, b)
    local dx = (b.X or 0) - (a.X or 0)
    local dy = (b.Y or 0) - (a.Y or 0)
    if dx * dx + dy * dy < 1e-8 then return nil end
    return math.atan(dy, dx)
end

-- Smallest signed difference between two headings, in radians (-pi..pi).
function U.angle_delta(a, b)
    if not a or not b then return 0 end
    local d = b - a
    while d > math.pi do d = d - 2 * math.pi end
    while d < -math.pi do d = d + 2 * math.pi end
    return d
end

function U.deg(rad) return rad * 180 / math.pi end
function U.rad(deg) return deg * math.pi / 180 end

-- Signed distance from p to the plane through `at` with normal `dir`.
-- Positive means p has already passed the plane.
function U.past_plane(p, at, dir)
    if not (p and at and dir) then return false end
    local dx = (p.X or 0) - (at.X or 0)
    local dy = (p.Y or 0) - (at.Y or 0)
    return (dx * dir.X + dy * dir.Y) >= 0
end

function U.finite_vec(v)
    if type(v) ~= "table" then return false end
    local x, y, z = tonumber(v.X), tonumber(v.Y), tonumber(v.Z)
    if not (x and y and z) then return false end
    if x ~= x or y ~= y or z ~= z then return false end
    if math.abs(x) > 5e6 or math.abs(y) > 5e6 or math.abs(z) > 5e6 then return false end
    return true
end

-- Weighted pick over {weight=n} entries. Returns nil for an empty/zero table.
function U.weighted_pick(items, rng)
    local total = 0
    for _, it in ipairs(items) do
        local w = U.num(it.weight, 0)
        if w > 0 then total = total + w end
    end
    if total <= 0 then return nil end
    local roll = (rng and rng:float() or math.random()) * total
    local acc = 0
    for _, it in ipairs(items) do
        local w = U.num(it.weight, 0)
        if w > 0 then
            acc = acc + w
            if roll <= acc then return it end
        end
    end
    return items[#items]
end

function U.keys(t)
    local out = {}
    for k in pairs(t) do out[#out + 1] = k end
    return out
end

function U.count(t)
    local n = 0
    for _ in pairs(t) do n = n + 1 end
    return n
end


-- Path separator. The mod runs on Windows, but the test harness runs the same
-- code on a POSIX host, so the separator is taken from the directory itself
-- instead of being hard-coded.
function U.path_sep(dir)
    if type(dir) == "string" and dir:find("\\", 1, true) then return "\\" end
    if type(dir) == "string" and dir:find("/", 1, true) then return "/" end
    return "\\"
end

function U.join(dir, name)
    if not dir or dir == "" then return name end
    local sep = U.path_sep(dir)
    if dir:sub(-1) == sep then return dir .. name end
    return dir .. sep .. name
end

-- Minimal JSON writer. Only the shapes the telemetry layer produces are
-- supported: string / number / boolean / array / object / nil.
local esc_map = {
    ['"'] = '\\"', ['\\'] = '\\\\', ['\b'] = '\\b', ['\f'] = '\\f',
    ['\n'] = '\\n', ['\r'] = '\\r', ['\t'] = '\\t',
}

local function esc(s)
    -- tostring can be overridden on a table via __tostring and return
    -- something that is not a string; one bad value must not end the tick.
    local str = tostring(s)
    if type(str) ~= "string" then return "" end
    return (str:gsub('[%c"\\]', function(c)
        return esc_map[c] or string.format('\\u%04X', c:byte())
    end))
end

local function is_array(t)
    local n = 0
    for k in pairs(t) do
        if type(k) ~= "number" then return false end
        n = n + 1
    end
    return n == #t
end

-- Appends only. The whole document is joined once, by U.json, at the end.
--
-- Until 1.1.3 every recursive call ended with table.concat(buf), so each of the
-- ~15,000 fragments of a live_state.json re-copied everything written before
-- it: 2.5 seconds for 130 KB on a desktop, about 8 seconds inside the server.
-- That ran on the game thread every two seconds, and it is what the engine
-- reported as a hung game thread.
local function encode(v, buf)
    local n = #buf
    local tv = type(v)
    if v == nil then
        buf[n + 1] = "null"
    elseif tv == "boolean" then
        buf[n + 1] = v and "true" or "false"
    elseif tv == "number" then
        if v ~= v or v == huge or v == -huge then
            buf[n + 1] = "0"
        elseif v == floor(v) and math.abs(v) < 1e15 then
            buf[n + 1] = string.format("%d", v)
        else
            buf[n + 1] = string.format("%.3f", v)
        end
    elseif tv == "string" then
        buf[n + 1] = '"' .. esc(v) .. '"'
    elseif tv == "table" then
        if is_array(v) then
            buf[n + 1] = "["
            for i = 1, #v do
                if i > 1 then buf[#buf + 1] = "," end
                encode(v[i], buf)
            end
            buf[#buf + 1] = "]"
        else
            buf[n + 1] = "{"
            local first = true
            local ks = U.keys(v)
            table.sort(ks, function(a, b) return tostring(a) < tostring(b) end)
            for _, k in ipairs(ks) do
                local val = v[k]
                local tval = type(val)
                if tval ~= "function" and tval ~= "userdata" and tval ~= "thread" then
                    if not first then buf[#buf + 1] = "," end
                    first = false
                    buf[#buf + 1] = '"' .. esc(k) .. '":'
                    encode(val, buf)
                end
            end
            buf[#buf + 1] = "}"
        end
    else
        buf[n + 1] = "null"
    end
end

function U.json(v)
    local buf = {}
    encode(v, buf)
    return table.concat(buf)
end

return U
