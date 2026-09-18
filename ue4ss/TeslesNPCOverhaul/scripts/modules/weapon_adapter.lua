-- Tesles weapon adapter: the only place that knows how this SCUM build fires a gun.
--
-- The Node brain never names a SCUM function. It emits AIM / FIRE_START / FIRE_STOP /
-- RELOAD for a Tesles-owned actor and this module resolves them against whatever the
-- running build actually exposes. Nothing here reports success it did not observe:
-- until a real call lands on a real actor the weapon capability stays unproven.
local util = require("modules.util")
local compat = require("modules.compat_profile")

local M = {state = {}}
local cfg, ipc, probe = nil, nil, nil
local resolved = nil

local AIM_CANDIDATES = {"SetFocalPoint", "SetFocus", "SetAimTarget", "SetTargetLocation", "AimAtLocation"}
local FIRE_START_CANDIDATES = {"StartFire", "StartWeaponFire", "BeginFire", "PullTrigger", "StartShooting", "OnStartFire"}
local FIRE_STOP_CANDIDATES = {"StopFire", "StopWeaponFire", "EndFire", "ReleaseTrigger", "StopShooting", "OnStopFire"}
local RELOAD_CANDIDATES = {"Reload", "StartReload", "ReloadWeapon", "OnReload"}

function M.configure(c, i, p)
  cfg, ipc, probe = c, i, p
  resolved = nil
  M.state = {}
  for _, extra in ipairs(cfg.weapon_fire_start_candidates or {}) do table.insert(FIRE_START_CANDIDATES, 1, extra) end
  for _, extra in ipairs(cfg.weapon_fire_stop_candidates or {}) do table.insert(FIRE_STOP_CANDIDATES, 1, extra) end
  for _, extra in ipairs(cfg.weapon_aim_candidates or {}) do table.insert(AIM_CANDIDATES, 1, extra) end
  for _, extra in ipairs(cfg.weapon_reload_candidates or {}) do table.insert(RELOAD_CANDIDATES, 1, extra) end
end

local function weapon_of(actor)
  for _, prop in ipairs(cfg.weapon_property_candidates or {"CurrentWeapon", "EquippedWeapon", "Weapon", "ActiveWeapon"}) do
    local ok, value = pcall(function() return actor:GetPropertyValue(prop) end)
    if ok and util.safe_valid(value) then
      compat.record("property", "weapon:" .. prop, true, util.safe_class_name(value))
      return value, prop
    end
  end
  return nil, nil
end

local function call_first(holders, names, args)
  for _, holder in ipairs(holders) do
    if util.safe_valid(holder) then
      for _, name in ipairs(names) do
        local ok, err = pcall(function()
          if args then holder[name](holder, table.unpack(args)) else holder[name](holder) end
        end)
        compat.record("function", util.safe_class_name(holder) .. ":" .. name, ok, ok and "call accepted" or tostring(err))
        if ok then return true, util.safe_class_name(holder) .. ":" .. name end
      end
    end
  end
  return false, "no callable candidate accepted the request"
end

-- rec must carry .actor, .controller and .id of a Tesles-owned materialized NPC.
function M.handle(rec, cmd)
  if not rec or not util.safe_valid(rec.actor) then return false, "no actor" end
  local weapon = weapon_of(rec.actor)
  local holders = {weapon, rec.actor, rec.controller}
  local action = cmd.type
  if action == "AIM" then
    local x, y, z = tonumber(cmd.x), tonumber(cmd.y), tonumber(cmd.z)
    if not x or not y or not z then return false, "bad aim coordinates" end
    local ok, detail = call_first({rec.controller, rec.actor}, AIM_CANDIDATES, {{X = x, Y = y, Z = z}})
    return ok, detail
  elseif action == "FIRE_START" then
    local ok, detail = call_first(holders, FIRE_START_CANDIDATES)
    if ok then M.state[rec.id] = {firing = true, since = util.now_ms()} end
    probe.cap("weapon_use", ok, ok and ("fire start accepted: " .. tostring(detail)) or ("no fire primitive accepted the request: " .. tostring(detail)))
    return ok, detail
  elseif action == "FIRE_STOP" then
    local ok, detail = call_first(holders, FIRE_STOP_CANDIDATES)
    if ok then M.state[rec.id] = {firing = false, since = util.now_ms()} end
    return ok, detail
  elseif action == "RELOAD" then
    return call_first(holders, RELOAD_CANDIDATES)
  end
  return false, "unsupported weapon action " .. tostring(action)
end

-- Releasing a trigger before an actor is released or destroyed is mandatory:
-- an actor must never be captured or removed while still firing.
function M.release(rec)
  if not rec or not M.state[rec.id] or not M.state[rec.id].firing then return true, "not firing" end
  local ok, detail = M.handle(rec, {type = "FIRE_STOP"})
  M.state[rec.id] = nil
  return ok, detail
end

function M.forget(id)
  M.state[id] = nil
end

return M
