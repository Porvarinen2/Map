local M = {}
-- Lua os.clock() reports process CPU time, not reliable wall-clock elapsed time.
-- Capability timeouts and debounce windows must follow real elapsed time even if
-- the game thread is sleeping or lightly loaded, so use wall time. One-second
-- resolution is conservative but correct for the >=1 s windows used by this bridge.
local _last_ms = os.time() * 1000
function M.now_ms()
  local now = os.time() * 1000
  if now < _last_ms then now = _last_ms end
  _last_ms = now
  return now
end
function M.safe_valid(o)
  if o == nil then return false end
  local ok, v = pcall(function() return o:IsValid() end)
  return ok and v == true
end
function M.contains_any(s, patterns)
  s = tostring(s or "")
  for _, p in ipairs(patterns or {}) do if string.find(s, p, 1, true) then return true end end
  return false
end
function M.url_encode(str)
  str = tostring(str or "")
  return (str:gsub("([^%w%-%._~])", function(c) return string.format("%%%02X", string.byte(c)) end))
end
function M.url_decode(str)
  return (tostring(str or ""):gsub("%%(%x%x)", function(h) return string.char(tonumber(h,16)) end))
end
function M.fmt_num(v)
  local n = tonumber(v) or 0
  return string.format("%.4f", n)
end
function M.safe_full_name(o)
  local ok, name = pcall(function() return o:GetFullName() end)
  return ok and tostring(name) or "<invalid>"
end
function M.safe_class_name(o)
  local ok, name = pcall(function() return tostring(o:GetClass():GetFName()) end)
  if ok then return name end
  local ok2, full = pcall(function() return o:GetClass():GetFullName() end)
  return ok2 and tostring(full) or "UnknownClass"
end
function M.safe_location(actor)
  local ok, loc = pcall(function() return actor:K2_GetActorLocation() end)
  if not ok or loc == nil then return nil end
  local ok2, x, y, z = pcall(function() return tonumber(loc.X), tonumber(loc.Y), tonumber(loc.Z) end)
  if not ok2 or x == nil or y == nil or z == nil then return nil end
  return {x=x,y=y,z=z}
end
function M.loop_game_thread(ms, fn)
  if type(LoopInGameThreadWithDelay) == "function" then
    return LoopInGameThreadWithDelay(ms, fn)
  end
  error("TeslesNPCOverhaul: game-thread scheduler unavailable (LoopInGameThreadWithDelay missing)")
end
function M.delay_game_thread(ms, fn)
  if type(ExecuteInGameThreadWithDelay) == "function" then
    return ExecuteInGameThreadWithDelay(ms, fn)
  end
  error("TeslesNPCOverhaul: game-thread scheduler unavailable (ExecuteInGameThreadWithDelay missing)")
end
return M
