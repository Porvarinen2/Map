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

check(exists(MOD .. "/output/boot.log"), "boot.log written before any module loads")
check(exists(MOD .. "/output/live_state.json"), "live_state.json written to output/")
check(exists(MOD .. "/output/director.log"), "director.log written to output/")

-- The boot log is the only diagnostic when the mod goes quiet, so it has to
-- record every stage, not just that something happened.
local bf = io.open(MOD .. "/output/boot.log", "r")
local boot_text = bf and bf:read("*a") or ""
if bf then bf:close() end
for _, marker in ipairs({ "boot ----", "mod dir", "package.path set",
                          "config.lua loaded", "modules loaded",
                          "output folder is writable", "world ready",
                          "director loop registered", "startup complete" }) do
    check(boot_text:find(marker, 1, true) ~= nil,
          "boot.log records: " .. marker)
end

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

-- ---------------------------------------------------------------------------
-- A broken install with no output folder must still leave a trace, and a
-- UE4SS build that embeds Lua 5.1 / LuaJIT must still start.
-- ---------------------------------------------------------------------------

local TMP2 = (os.getenv("TMPDIR") or "/tmp") .. "/tesles_boot2"
os.execute("rm -rf '" .. TMP2 .. "'")
os.execute("mkdir -p '" .. TMP2 .. "'")
os.execute("cp -r ../package/mod/TeslesNPCOverhaul '" .. TMP2 .. "/'")
local MOD2 = TMP2 .. "/TeslesNPCOverhaul"
os.execute("rm -rf '" .. MOD2 .. "/output'")

for k in pairs(package.loaded) do
    if k:match("^core%.") or k:match("^world%.") or k:match("^sim%.")
        or k:match("^npc%.") or k:match("^bridge%.") then
        package.loaded[k] = nil
    end
end

-- Pretend to be Lua 5.1: single-argument math.atan plus math.atan2.
local real_atan = math.atan
math.atan2 = function(y, x) return real_atan(y, x) end
math.atan = function(y) return real_atan(y) end

local delayed2 = nil
_G.ExecuteWithDelay = function(ms, fn) delayed2 = fn end
_G.LoopAsync = function() end

local chunk2, err2 = loadfile(MOD2 .. "/Scripts/main.lua")
check(chunk2 ~= nil, "main.lua loads for the 5.1 check (" .. tostring(err2) .. ")")
local ok3, res3 = pcall(chunk2)
check(ok3, "main.lua runs on a single-argument math.atan: " .. tostring(res3))
if ok3 and delayed2 then
    local ok4, err4 = pcall(delayed2)
    check(ok4, "startup completes with the atan shim: " .. tostring(err4))
end

math.atan = real_atan
math.atan2 = nil

local trace = io.open(MOD2 .. "/boot.log", "r")
check(trace ~= nil, "boot log falls back to the mod folder when output/ is gone")
if trace then
    local body = trace:read("*a")
    trace:close()
    check(body:find("math.atan shim", 1, true) ~= nil,
          "the 5.1 shim is recorded in the boot log")
    check(body:find("OUTPUT FOLDER NOT WRITABLE", 1, true) ~= nil,
          "a missing output folder is called out, not ignored")
end

os.execute("rm -rf '" .. TMP2 .. "'")
os.execute("rm -rf '" .. TMP .. "'")
print("")
os.exit(fails == 0 and 0 or 1)
