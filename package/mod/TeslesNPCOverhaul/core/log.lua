-- File + console logging. Paths are injected by main.lua so the module stays
-- testable outside the game.
local U = require("core.util")

local L = { dir = nil, echo = true, level = 2, _buf = {}, _events = {} }

local LEVELS = { error = 1, warn = 2, info = 3, debug = 4 }

local function stamp()
    return os.date("%H:%M:%S")
end

function L.configure(dir, level, echo)
    L.dir = dir
    L.level = LEVELS[level or "info"] or 3
    if echo ~= nil then L.echo = echo end
end

local function write(name, line)
    if not L.dir then return end
    local f = io.open(U.join(L.dir, name), "a")
    if not f then return end
    f:write(line, "\n")
    f:close()
end

local function emit(kind, msg)
    local line = string.format("[%s] %-5s %s", stamp(), kind, msg)
    if L.echo and print then print("[TeslesNPC] " .. line) end
    write("director.log", line)
end

function L.error(msg) if L.level >= 1 then emit("ERROR", tostring(msg)) end end
function L.warn(msg) if L.level >= 2 then emit("WARN", tostring(msg)) end end
function L.info(msg) if L.level >= 3 then emit("INFO", tostring(msg)) end end
function L.debug(msg) if L.level >= 4 then emit("DEBUG", tostring(msg)) end end

-- Structured world events. These feed the live map feed and the movement
-- debug export, so they are kept separate from the human-readable log.
function L.event(kind, subject, detail)
    local e = {
        t = os.time(),
        kind = tostring(kind),
        subject = tostring(subject or ""),
        detail = tostring(detail or ""),
    }
    L._events[#L._events + 1] = e
    if #L._events > 400 then table.remove(L._events, 1) end
    write("events.tsv", string.format("%d\t%s\t%s\t%s", e.t, e.kind, e.subject, e.detail))
    return e
end

function L.recent_events(n)
    n = n or 60
    local out = {}
    local start = math.max(1, #L._events - n + 1)
    for i = start, #L._events do out[#out + 1] = L._events[i] end
    return out
end

-- Movement debug trail: one row per issued move command. This is the file the
-- zig-zag investigation reads back.
function L.move_trace(row)
    write("movement_debug.tsv", row)
end

return L
