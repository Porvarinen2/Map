-- SmartNPC :: telemetry.lua
-- Writes the single JSON snapshot the browser map consumes.
-- One file, written atomically, so the map server needs no parsing logic.

local S = SMARTNPC
local U = S.util
local C = S.config
local W = S.world

local M = {}

local floor = math.floor

local events = {}
local event_seq = 0
local last_write = 0
local trails = {}      -- squad id -> { {x,y}, ... }
local started_at = U.wall()

function M.event(kind, subject, detail)
    event_seq = event_seq + 1
    events[#events + 1] = {
        n = event_seq,
        t = U.hhmmss(),
        kind = tostring(kind),
        who = tostring(subject or "-"),
        what = tostring(detail or ""),
    }
    while #events > C.TelemetryEventCap do table.remove(events, 1) end
end

local function push_trail(id, pos)
    local t = trails[id]
    if not t then t = {}; trails[id] = t end
    local last = t[#t]
    if last and U.dist2({ x = last[1], y = last[2] }, pos) < 900 then return end
    t[#t + 1] = { floor(pos.x), floor(pos.y) }
    while #t > C.TelemetryTrailPoints do table.remove(t, 1) end
end

local function poi_payload()
    local out = {}
    local function add(list)
        for _, p in ipairs(list) do
            out[#out + 1] = { id = p.id, label = p.label, kind = p.kind,
                              x = floor(p.x), y = floor(p.y), sector = p.sector }
        end
    end
    add(W.pois.highloot)
    add(W.pois.settlements)
    add(W.pois.hunting)
    return out
end

local poi_cache = nil

function M.write(force)
    local now = U.now()
    if not force and now - last_write < C.TelemetryIntervalSec then return end
    last_write = now

    local D = S.director
    local squads = {}
    local live_ids = {}

    for id, sq in pairs(D.squads) do
        if sq.pos then
            live_ids[id] = true
            push_trail(id, sq.pos)
            local s = sq:summary()
            s.playerDist = sq.player_dist and floor(sq.player_dist) or nil
            s.route = sq:route_line(70)
            s.trail = trails[id]
            s.members_detail = {}
            for _, m in ipairs(sq.members) do
                if m.pos then
                    s.members_detail[#s.members_detail + 1] = {
                        x = floor(m.pos.x), y = floor(m.pos.y), z = floor(m.pos.z or 0),
                        yaw = floor(m.yaw or 0),
                        speed = floor(m.speed or 0),
                        cls = m.class,
                        lead = (sq.leader == m) or nil,
                        stalls = m.stall_total,
                        traits = m.traits and {
                            agg = m.traits.aggression, cau = m.traits.caution,
                            gre = m.traits.greed, dis = m.traits.discipline,
                            sta = m.traits.stamina, mar = m.traits.marksmanship,
                            cur = m.traits.curiosity, loy = m.traits.loyalty,
                        } or nil,
                    }
                end
            end
            squads[#squads + 1] = s
        end
    end

    for id in pairs(trails) do
        if not live_ids[id] then trails[id] = nil end
    end

    poi_cache = poi_cache or poi_payload()

    local diag = D.diagnostics()
    local b = W.bounds()

    local payload = {
        version   = S.VERSION,
        time      = U.stamp(),
        uptime    = U.wall() - started_at,
        tick      = S.tick_count or 0,
        tickMs    = S.last_tick_ms or 0,
        ok        = true,
        calib     = { xWest = b.xWest, xEast = b.xEast, yNorth = b.yNorth, ySouth = b.ySouth },
        stats     = diag,
        squads    = squads,
        players   = C.TelemetryIncludePlayers and D.players or {},
        events    = events,
        pois      = poi_cache,
    }

    U.write_atomic(S.DIR_OUTPUT .. S.SEP .. "world.json", U.json(payload))
end

return M
