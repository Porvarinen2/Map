-- Runtime compatibility profile for the SCUM build this bridge is running against.
-- Every reflected class, function and property the adapters try is recorded here with
-- its exact outcome, so a broken SCUM update produces a diagnosable profile instead of
-- a silent capability loss.
local M = {profile = {build = "unknown", entries = {}}}
local cfg, ipc = nil, nil
local profile_file = nil
local dirty = false

function M.configure(c, i)
  cfg, ipc = c, i
  profile_file = c.compat_profile_file
  M.profile.build = tostring(c.scum_build or "unknown")
  M.profile.started_at = os.date("!%Y-%m-%dT%H:%M:%SZ")
end

local function key(kind, name) return tostring(kind) .. "|" .. tostring(name) end

function M.record(kind, name, ok, detail)
  local k = key(kind, name)
  local existing = M.profile.entries[k]
  if existing and existing.ok == ok and existing.detail == tostring(detail or "") then return end
  M.profile.entries[k] = {kind = kind, name = name, ok = ok == true, detail = tostring(detail or ""), at = os.date("!%Y-%m-%dT%H:%M:%SZ")}
  dirty = true
end

function M.get(kind, name)
  return M.profile.entries[key(kind, name)]
end

local function quote(s)
  return '"' .. tostring(s or ""):gsub('\\', '\\\\'):gsub('"', '\\"'):gsub('\n', ' ') .. '"'
end

function M.flush()
  if not profile_file or not dirty then return end
  local f = io.open(profile_file .. ".tmp", "w")
  if not f then return end
  f:write("{\n")
  f:write('  "build": ' .. quote(M.profile.build) .. ',\n')
  f:write('  "startedAt": ' .. quote(M.profile.started_at) .. ',\n')
  f:write('  "entries": [\n')
  local first = true
  for _, e in pairs(M.profile.entries) do
    if not first then f:write(",\n") end
    first = false
    f:write('    {"kind": ' .. quote(e.kind) .. ', "name": ' .. quote(e.name) ..
            ', "ok": ' .. tostring(e.ok) .. ', "detail": ' .. quote(e.detail) ..
            ', "at": ' .. quote(e.at) .. '}')
  end
  f:write("\n  ]\n}\n")
  f:close()
  os.remove(profile_file)
  os.rename(profile_file .. ".tmp", profile_file)
  dirty = false
end

return M
