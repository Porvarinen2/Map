-- World state persistence.
--
-- The save holds durable facts only: identity seeds, positions, goals,
-- relationships, traumas. Personalities are regenerated from their seed on
-- load, so the file stays small and there is exactly one source of truth for
-- what an NPC is.
local U = require("core.util")
local Log = require("core.log")

local P = { dir = nil, file = "world_state.json", interval = 45, last_save = 0 }

function P.configure(dir, interval)
    P.dir = dir
    if interval then P.interval = interval end
end

local function path(name)
    if not P.dir then return nil end
    return U.join(P.dir, name or P.file)
end

local function open_read(name)
    local a = path(name)
    if not a then return nil end
    return io.open(a, "r")
end

local function open_write(name)
    local a = path(name)
    if not a then return nil end
    return io.open(a, "w")
end

-- ----------------------------------------------------------- JSON reader ---

-- A small, strict JSON parser. Only the shapes this mod writes are accepted.
local function parse(text)
    local pos = 1
    local function err(msg) error("json:" .. pos .. ": " .. msg, 0) end
    local function skip()
        while true do
            local c = text:sub(pos, pos)
            if c == " " or c == "\t" or c == "\n" or c == "\r" then pos = pos + 1
            else break end
        end
    end
    local value

    local function str()
        pos = pos + 1
        local buf = {}
        while true do
            local c = text:sub(pos, pos)
            if c == "" then err("unterminated string") end
            if c == '"' then pos = pos + 1; break end
            if c == "\\" then
                local n = text:sub(pos + 1, pos + 1)
                pos = pos + 2
                if n == "n" then buf[#buf + 1] = "\n"
                elseif n == "t" then buf[#buf + 1] = "\t"
                elseif n == "r" then buf[#buf + 1] = "\r"
                elseif n == "b" then buf[#buf + 1] = "\b"
                elseif n == "f" then buf[#buf + 1] = "\f"
                elseif n == "u" then
                    local hex = text:sub(pos, pos + 3)
                    pos = pos + 4
                    local code = tonumber(hex, 16) or 63
                    buf[#buf + 1] = (code < 128) and string.char(code) or "?"
                else buf[#buf + 1] = n end
            else
                buf[#buf + 1] = c
                pos = pos + 1
            end
        end
        return table.concat(buf)
    end

    local function num()
        local s, e = text:find("^-?%d+%.?%d*[eE]?[-+]?%d*", pos)
        if not s then err("bad number") end
        local v = tonumber(text:sub(s, e))
        pos = e + 1
        return v
    end

    local function arr()
        pos = pos + 1
        local out = {}
        skip()
        if text:sub(pos, pos) == "]" then pos = pos + 1; return out end
        while true do
            out[#out + 1] = value()
            skip()
            local c = text:sub(pos, pos)
            pos = pos + 1
            if c == "]" then return out end
            if c ~= "," then err("expected , or ] in array") end
            skip()
        end
    end

    local function obj()
        pos = pos + 1
        local out = {}
        skip()
        if text:sub(pos, pos) == "}" then pos = pos + 1; return out end
        while true do
            skip()
            if text:sub(pos, pos) ~= '"' then err("expected key") end
            local k = str()
            skip()
            if text:sub(pos, pos) ~= ":" then err("expected :") end
            pos = pos + 1
            skip()
            out[k] = value()
            skip()
            local c = text:sub(pos, pos)
            pos = pos + 1
            if c == "}" then return out end
            if c ~= "," then err("expected , or } in object") end
        end
    end

    value = function()
        skip()
        local c = text:sub(pos, pos)
        if c == "{" then return obj() end
        if c == "[" then return arr() end
        if c == '"' then return str() end
        if c == "t" and text:sub(pos, pos + 3) == "true" then pos = pos + 4; return true end
        if c == "f" and text:sub(pos, pos + 4) == "false" then pos = pos + 5; return false end
        if c == "n" and text:sub(pos, pos + 3) == "null" then pos = pos + 4; return nil end
        return num()
    end

    local v = value()
    return v
end

P.parse = parse

-- ---------------------------------------------------------------- saving ---

-- Written to a temp file first and put in place only when complete: a
-- server stopped in the middle of a save leaves the last good file, never a
-- half one.
function P.save(data, name)
    name = name or P.file
    local ok, text = pcall(U.json, data)
    if not ok then
        Log.error("world state serialise failed: " .. tostring(text))
        return false
    end
    local tmp = name .. ".tmp"
    local f = open_write(tmp)
    if not f then
        Log.warn("could not open world state for writing")
        return false
    end
    local okw = f:write(text)
    f:close()
    if not okw then
        os.remove(path(tmp))
        Log.warn("world state could not be written (disk full?)")
        return false
    end
    if not os.rename(path(tmp), path(name)) then
        -- Windows will not rename onto an existing file.
        os.remove(path(name))
        if not os.rename(path(tmp), path(name)) then
            Log.warn("world state could not be put in place")
            return false
        end
    end
    P.last_save = os.time()
    return true
end

local function load_one(name)
    local f = open_read(name)
    if not f then return nil, "NO_FILE" end
    local text = f:read("*a")
    f:close()
    if not text or #text < 2 then return nil, "EMPTY" end
    local ok, data = pcall(parse, text)
    if not ok or type(data) ~= "table" then
        Log.error("world state parse failed (" .. tostring(name) .. "): " .. tostring(data))
        return nil, "PARSE_ERROR"
    end
    return data
end

-- The saved world, or the backup when the save itself is missing or broken:
-- a damaged file must never cost the whole world.
function P.load(name)
    name = name or P.file
    local data, why = load_one(name)
    if data then return data end
    local bak, why2 = load_one(name .. ".bak")
    if bak then
        Log.warn("world state " .. tostring(why) .. ": the backup was loaded instead")
        P.loaded_backup = true
        return bak
    end
    return nil, why
end

function P.due(now)
    return (now - (P.last_save or 0)) >= P.interval
end

-- Keeps one rolling backup so a corrupted save is never the only copy.
-- The last good save becomes the backup. A file that does not parse is not
-- allowed to replace a good backup.
function P.rotate()
    local a = path(P.file)
    local bak = path(P.file .. ".bak")
    if not a then return end
    local f = io.open(a, "r")
    if not f then return end
    local head = f:read(1)
    local size = f:seek("end") or 0
    local tail = ""
    if size >= 2 then
        f:seek("set", size - 1)
        tail = f:read(1) or ""
    end
    f:close()
    -- A complete save starts with { and ends with }.
    if head ~= "{" or tail ~= "}" then return end
    os.remove(bak)
    os.rename(a, bak)
end

return P
