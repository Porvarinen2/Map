-- SmartNPC :: util.lua
-- Safe Unreal access, math, logging, file IO, JSON.
-- Every call that crosses into native UE memory is wrapped in pcall.

local S = SMARTNPC
local U = {}

--------------------------------------------------------------------------
-- time
--------------------------------------------------------------------------

local clock_base = os.clock()
local wall_base  = os.time()

-- Monotonic-ish seconds with sub-second resolution.
-- os.clock() on Windows measures wall time for the process, which is what we
-- want; if it ever drifts against the wall clock we resync.
function U.now()
    local c = os.clock() - clock_base
    return c
end

function U.wall()
    return os.time()
end

function U.stamp()
    return os.date("%Y-%m-%d %H:%M:%S")
end

function U.hhmmss()
    return os.date("%H:%M:%S")
end

--------------------------------------------------------------------------
-- files / logging
--------------------------------------------------------------------------

local function write_file(path, text, mode)
    local f = io.open(path, mode or "w")
    if not f then return false end
    f:write(text)
    f:close()
    return true
end
U.write_file = write_file

function U.read_file(path)
    local f = io.open(path, "r")
    if not f then return nil end
    local t = f:read("*a")
    f:close()
    return t
end

-- Atomic-ish replace: write to .tmp then os.rename over the target.
-- The map server only ever sees a complete file.
function U.write_atomic(path, text)
    local tmp = path .. ".tmp"
    if not write_file(tmp, text, "wb") then return false end
    -- The map server keeps the snapshot open while reading it, so the remove or
    -- the rename can lose a race.  Retry a couple of times, then fall back to a
    -- direct write: a torn read just makes the browser skip one poll.
    for _ = 1, 3 do
        os.remove(path)
        if os.rename(tmp, path) then return true end
    end
    os.remove(tmp)
    return write_file(path, text, "wb")
end

local log_bytes = 0
local LOG_PATH

function U.log(msg)
    msg = tostring(msg)
    print("[SmartNPC] " .. msg .. "\n")
    LOG_PATH = LOG_PATH or (S.DIR_LOGS .. S.SEP .. "smartnpc.log")
    local line = "[" .. U.stamp() .. "] " .. msg .. "\n"
    log_bytes = log_bytes + #line
    if log_bytes > 8 * 1024 * 1024 then
        -- Roll once so a long uptime cannot fill the disk.
        os.remove(LOG_PATH .. ".1")
        os.rename(LOG_PATH, LOG_PATH .. ".1")
        log_bytes = #line
    end
    write_file(LOG_PATH, line, "a")
end

local warn_seen = {}
function U.warn_once(tag, msg)
    if warn_seen[tag] then return end
    warn_seen[tag] = true
    U.log("WARN " .. tag .. ": " .. tostring(msg))
end

--------------------------------------------------------------------------
-- math
--------------------------------------------------------------------------

local sqrt, abs, floor, max, min = math.sqrt, math.abs, math.floor, math.max, math.min
local random = math.random

function U.clamp(v, lo, hi) if v < lo then return lo elseif v > hi then return hi else return v end end
function U.lerp(a, b, t) return a + (b - a) * t end

function U.dist2(a, b)
    if not a or not b then return math.huge end
    local dx, dy = (a.x or a.X or 0) - (b.x or b.X or 0), (a.y or a.Y or 0) - (b.y or b.Y or 0)
    return sqrt(dx * dx + dy * dy)
end

function U.dist2sq(a, b)
    if not a or not b then return math.huge end
    local dx, dy = (a.x or a.X or 0) - (b.x or b.X or 0), (a.y or a.Y or 0) - (b.y or b.Y or 0)
    return dx * dx + dy * dy
end

function U.dist3(a, b)
    if not a or not b then return math.huge end
    local dx = (a.x or a.X or 0) - (b.x or b.X or 0)
    local dy = (a.y or a.Y or 0) - (b.y or b.Y or 0)
    local dz = (a.z or a.Z or 0) - (b.z or b.Z or 0)
    return sqrt(dx * dx + dy * dy + dz * dz)
end

function U.norm2(dx, dy)
    local l = sqrt(dx * dx + dy * dy)
    if l < 1e-6 then return 0, 0, 0 end
    return dx / l, dy / l, l
end

-- Signed smallest difference between two headings in degrees.
function U.angle_delta(a, b)
    local d = (b - a) % 360
    if d > 180 then d = d - 360 end
    return d
end

function U.heading(dx, dy)
    return (math.deg(math.atan(dy, dx))) % 360
end

function U.rand_range(a, b) return a + random() * (b - a) end
function U.rand_int(a, b) return random(a, b) end

function U.pick(list)
    if not list or #list == 0 then return nil end
    return list[random(1, #list)]
end

-- Weighted pick. items = { {w=<number>, ...}, ... } or a weight accessor.
function U.pick_weighted(items, weight_of)
    if not items or #items == 0 then return nil end
    local total = 0
    for i = 1, #items do
        local w = weight_of and weight_of(items[i]) or (items[i].w or items[i].weight or 1)
        if w and w > 0 then total = total + w end
    end
    if total <= 0 then return items[random(1, #items)] end
    local r = random() * total
    for i = 1, #items do
        local w = weight_of and weight_of(items[i]) or (items[i].w or items[i].weight or 1)
        if w and w > 0 then
            r = r - w
            if r <= 0 then return items[i] end
        end
    end
    return items[#items]
end

-- Deterministic small hash, used for stable per-NPC jitter.
function U.hash(str)
    local h = 5381
    str = tostring(str)
    for i = 1, #str do
        h = (h * 33 + str:byte(i)) % 4294967296
    end
    return h
end

function U.hash01(str, salt)
    return (U.hash(tostring(salt or "") .. "|" .. tostring(str)) % 10007) / 10007
end

--------------------------------------------------------------------------
-- safe Unreal access
--------------------------------------------------------------------------

-- UE4SS hands back either a live UObject or a RemoteUnrealParam wrapper.
-- resolve() flattens both and returns nil for anything unusable.
local function resolve(o)
    if o == nil then return nil end
    local ok, v = pcall(function() return o:IsValid() end)
    if ok then return v and o or nil end
    local ok2, inner = pcall(function() return o:get() end)
    if ok2 and inner ~= nil then
        local ok3, v3 = pcall(function() return inner:IsValid() end)
        if ok3 and v3 then return inner end
    end
    return nil
end
U.resolve = resolve

function U.valid(o)
    return resolve(o) ~= nil
end

function U.fullname(o)
    o = resolve(o); if not o then return "" end
    local ok, s = pcall(function() return o:GetFullName() end)
    return ok and tostring(s) or ""
end

function U.shortname(o)
    local fn = U.fullname(o)
    return fn:match("([^%.%s/]+)$") or fn
end

-- Stable identity for an actor. Address is cheap and unique while alive.
function U.key(o)
    o = resolve(o); if not o then return nil end
    local ok, a = pcall(function() return o:GetAddress() end)
    if ok and a then return tostring(a) end
    local fn = U.fullname(o)
    return fn ~= "" and fn or nil
end

function U.get(o, name, default)
    o = resolve(o); if not o then return default end
    local ok, v = pcall(function() return o:GetPropertyValue(name) end)
    if ok and v ~= nil then return v end
    local ok2, v2 = pcall(function() return o[name] end)
    if ok2 and v2 ~= nil then return v2 end
    return default
end

function U.set(o, name, value)
    o = resolve(o); if not o then return false end
    if pcall(function() o:SetPropertyValue(name, value) end) then return true end
    return pcall(function() o[name] = value end)
end

function U.num(v, default)
    if v == nil then return default end
    if type(v) == "number" then return v end
    local ok, inner = pcall(function() return v:get() end)
    if ok and type(inner) == "number" then return inner end
    return tonumber(v) or default
end

function U.bool(v, default)
    if v == nil then return default end
    if type(v) == "boolean" then return v end
    local ok, inner = pcall(function() return v:get() end)
    if ok and type(inner) == "boolean" then return inner end
    if type(v) == "number" then return v ~= 0 end
    return default
end

function U.getnum(o, name, default)
    return U.num(U.get(o, name, nil), default)
end

function U.getbool(o, name, default)
    return U.bool(U.get(o, name, nil), default)
end

-- Call a UFUNCTION by name with pcall; returns ok, result.
function U.call(o, fn, ...)
    o = resolve(o); if not o then return false, nil end
    local args = table.pack(...)
    local ok, res = pcall(function()
        return o[fn](o, table.unpack(args, 1, args.n))
    end)
    return ok, res
end

-- Flatten an FVector coming out of UE4SS into a plain Lua table.
function U.vec(v)
    if v == nil then return nil end
    if type(v) == "table" and (v.X or v.x) then
        local x, y, z = U.num(v.X or v.x, nil), U.num(v.Y or v.y, nil), U.num(v.Z or v.z, 0)
        if x and y then return { x = x, y = y, z = z or 0 } end
        return nil
    end
    local ok, t = pcall(function()
        return { x = v.X, y = v.Y, z = v.Z }
    end)
    if ok and t then
        local x, y, z = U.num(t.x, nil), U.num(t.y, nil), U.num(t.z, 0)
        if x and y then return { x = x, y = y, z = z or 0 } end
    end
    local ok2, inner = pcall(function() return v:get() end)
    if ok2 and inner ~= nil and inner ~= v then return U.vec(inner) end
    return nil
end

function U.fv(p)
    return { X = p.x or p.X or 0, Y = p.y or p.Y or 0, Z = p.z or p.Z or 0 }
end

function U.actor_pos(a)
    a = resolve(a); if not a then return nil end
    local ok, v = pcall(function() return a:K2_GetActorLocation() end)
    if ok then
        local p = U.vec(v)
        if p then return p end
    end
    local rc = U.get(a, "RootComponent", nil)
    if rc then
        local p = U.vec(U.get(rc, "RelativeLocation", nil))
        if p then return p end
    end
    return nil
end

function U.actor_yaw(a)
    a = resolve(a); if not a then return nil end
    local ok, r = pcall(function() return a:K2_GetActorRotation() end)
    if ok and r then
        local y = U.num(r.Yaw, nil)
        if y then return y % 360 end
    end
    return nil
end

function U.is_finite(n)
    return type(n) == "number" and n == n and n ~= math.huge and n ~= -math.huge
end

function U.pos_sane(p)
    if not p then return false end
    if not (U.is_finite(p.x) and U.is_finite(p.y) and U.is_finite(p.z)) then return false end
    -- The SCUM island fits comfortably inside +/- 1.2e6 uu; anything beyond is
    -- an unloaded/garbage transform, not a real location.
    if abs(p.x) > 2.0e6 or abs(p.y) > 2.0e6 or abs(p.z) > 1.0e6 then return false end
    if abs(p.x) < 1.0 and abs(p.y) < 1.0 then return false end
    return true
end

--------------------------------------------------------------------------
-- JSON encoder (numbers, strings, booleans, arrays, maps)
--------------------------------------------------------------------------

local esc = {
    ['"'] = '\\"', ['\\'] = '\\\\', ['\b'] = '\\b', ['\f'] = '\\f',
    ['\n'] = '\\n', ['\r'] = '\\r', ['\t'] = '\\t',
}
local function esc_char(c)
    return esc[c] or string.format("\\u%04x", c:byte())
end

local function json_str(s)
    return '"' .. tostring(s):gsub('[%c"\\]', esc_char) .. '"'
end

local function json_num(n)
    if not U.is_finite(n) then return "0" end
    if n == floor(n) and abs(n) < 1e15 then return string.format("%d", n) end
    return string.format("%.3f", n)
end

local function is_array(t)
    local n = 0
    for k in pairs(t) do
        if type(k) ~= "number" then return false end
        n = n + 1
    end
    return n == #t
end

local function encode(v, out, depth)
    if depth > 24 then out[#out + 1] = "null"; return end
    local tv = type(v)
    if v == nil then out[#out + 1] = "null"
    elseif tv == "number" then out[#out + 1] = json_num(v)
    elseif tv == "boolean" then out[#out + 1] = v and "true" or "false"
    elseif tv == "string" then out[#out + 1] = json_str(v)
    elseif tv == "table" then
        if is_array(v) then
            out[#out + 1] = "["
            for i = 1, #v do
                if i > 1 then out[#out + 1] = "," end
                encode(v[i], out, depth + 1)
            end
            out[#out + 1] = "]"
        else
            out[#out + 1] = "{"
            local first = true
            for k, val in pairs(v) do
                if val ~= nil and type(k) ~= "table" then
                    if not first then out[#out + 1] = "," end
                    first = false
                    out[#out + 1] = json_str(k)
                    out[#out + 1] = ":"
                    encode(val, out, depth + 1)
                end
            end
            out[#out + 1] = "}"
        end
    else
        out[#out + 1] = "null"
    end
end

function U.json(v)
    local out = {}
    encode(v, out, 0)
    return table.concat(out)
end

--------------------------------------------------------------------------
-- small ring buffer
--------------------------------------------------------------------------

function U.ring(cap)
    return { cap = cap, n = 0, items = {} }
end

function U.ring_push(r, item)
    r.items[#r.items + 1] = item
    if #r.items > r.cap then
        table.remove(r.items, 1)
    end
    r.n = r.n + 1
end

--------------------------------------------------------------------------
-- pcall wrapper that logs once per unique failure site
--------------------------------------------------------------------------

local guard_seen = {}
function U.guard(tag, fn, ...)
    local ok, err = pcall(fn, ...)
    if not ok then
        local n = (guard_seen[tag] or 0) + 1
        guard_seen[tag] = n
        if n <= 3 or n % 200 == 0 then
            U.log("ERROR[" .. tag .. " x" .. n .. "] " .. tostring(err))
        end
        return false, err
    end
    return true
end

function U.guard_counts()
    return guard_seen
end

return U
