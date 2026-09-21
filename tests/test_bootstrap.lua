-- Smoke test for the real UE4SS entry point.
--
-- Runs Scripts/main.lua exactly as the game would, with the UE4SS globals
-- stubbed out, and checks that it finds its own folder, loads its config,
-- builds a world and writes its output files. This is the path no unit test
-- otherwise covers.
local TMP = (os.getenv("TMPDIR") or "/tmp") .. "/tesles_boot"
os.execute("rm -rf '" .. TMP .. "'")
os.execute("mkdir -p '" .. TMP .. "'")
os.execute("cp -r ../package/mod/TeslesNPCOverhaul '" .. TMP .. "/'")

local MOD = TMP .. "/TeslesNPCOverhaul"

local fails = 0
local function check(cond, msg)
    if cond then print("  ok  " .. msg)
    else print("FAIL: " .. msg); fails = fails + 1 end
end

-- UE4SS stubs. Nothing in the mod may require these to exist.
local delayed = nil
local loops = {}
_G.ExecuteWithDelay = function(ms, fn) delayed = fn end
_G.LoopAsync = function(ms, fn) loops[#loops + 1] = { ms = ms, fn = fn } end
_G.ExecuteInGameThread = function(fn) fn() end
-- Deliberately no FindFirstOf / StaticFindObject: the bridge must degrade
-- gracefully when the engine API is not there.

local chunk, err = loadfile(MOD .. "/Scripts/main.lua")
check(chunk ~= nil, "Scripts/main.lua loads (" .. tostring(err) .. ")")
if not chunk then os.exit(1) end

local ok, M = pcall(chunk)
check(ok, "main.lua runs without error: " .. tostring(M))
if not ok then os.exit(1) end

check(delayed ~= nil, "startup is deferred, not run inside the load callback")
local ok2, err2 = pcall(delayed)
check(ok2, "deferred startup completes: " .. tostring(err2))

check(#loops == 1, "the director registers exactly one tick loop")
check(loops[1] and loops[1].ms == 1000, "tick period comes from config.lua")

-- Drive a few ticks through the registered loop, as UE4SS would.
local ticked = true
for _ = 1, 5 do
    local okt, errt = pcall(loops[1].fn)
    if not okt then ticked = false; print("     tick error: " .. tostring(errt)) end
end
check(ticked, "five director ticks run with no engine available")

local function exists(p)
    local f = io.open(p, "r")
    if f then f:close(); return true end
    return false
end

check(exists(MOD .. "/output/live_state.json"), "live_state.json written to output/")
check(exists(MOD .. "/output/director.log"), "director.log written to output/")

local f = io.open(MOD .. "/output/live_state.json", "r")
local body = f:read("*a")
f:close()
package.path = "../package/mod/TeslesNPCOverhaul/?.lua;./?.lua;" .. package.path
local Persist = require("core.persist")
local snap = Persist.parse(body)
check(type(snap) == "table" and snap.groups and #snap.groups > 0,
      "snapshot contains the generated population (" ..
      tostring(snap and snap.groups and #snap.groups) .. " groups)")

local health = {}
for _, h in ipairs((snap and snap.health) or {}) do health[h.key] = h.status end
check(health.ue4ssCore == "DEGRADED",
      "missing UE4SS is reported as DEGRADED, not silently ignored")
check(health.worldPopulation == "OK", "world population reports OK")
check(health.spawnCatalog ~= "OK",
      "spawn catalog does not claim OK without a real class lookup")

os.execute("rm -rf '" .. TMP .. "'")
print("")
os.exit(fails == 0 and 0 or 1)
