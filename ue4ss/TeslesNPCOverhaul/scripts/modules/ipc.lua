local util = require("modules.util")
local M = {}
local event_file, command_file, state_file = nil, nil, nil
local event_max_bytes = 5242880
local last_command_seq = 0

function M.configure(cfg)
  event_file, command_file, state_file = cfg.event_file, cfg.command_file, cfg.state_file
  event_max_bytes = tonumber(cfg.event_max_bytes) or 5242880
  last_command_seq = 0
  local f = io.open(event_file, "a"); if f then f:close() end
  local c = io.open(command_file, "a"); if c then c:close() end
end

local function format_line(event_type, fields)
  local parts = { tostring(util.now_ms()), tostring(event_type) }
  local keys = {}; for k,_ in pairs(fields or {}) do table.insert(keys,k) end; table.sort(keys)
  for _,k in ipairs(keys) do table.insert(parts, tostring(k).."="..util.url_encode(fields[k])) end
  return table.concat(parts,"|")
end

local function rotate_event_log_if_needed()
  if not event_file or event_max_bytes<=0 then return end
  local f=io.open(event_file,"rb"); if not f then return end
  local size=f:seek("end") or 0; f:close()
  if size<event_max_bytes then return end
  local rotated=event_file..".1"
  os.remove(rotated)
  os.rename(event_file,rotated)
end

function M.emit(event_type, fields)
  if not event_file then return end
  rotate_event_log_if_needed()
  local f = io.open(event_file, "a")
  if f then f:write(format_line(event_type,fields).."\n"); f:flush(); f:close() end
end

function M.write_state(records)
  if not state_file then return end
  local tmp=state_file..".tmp"
  local f=io.open(tmp,"w"); if not f then return end
  for _,r in ipairs(records or {}) do f:write(format_line(r.type,r.fields).."\n") end
  f:flush();f:close()
  os.remove(state_file)
  os.rename(tmp,state_file)
end

local function parse_line(line)
  local out = {}; local idx = 0
  for part in string.gmatch(line, "([^|]+)") do
    idx = idx + 1
    if idx == 1 then out.seq = tonumber(part) or 0
    elseif idx == 2 then out.type = part
    else
      local k,v = string.match(part,"^([^=]+)=(.*)$")
      if k then out[k]=util.url_decode(v) end
    end
  end
  return out
end

-- command_file is a bounded latest-command snapshot, not an append-only log.
-- The Node brain rewrites it atomically. Sequence de-duplication avoids MoveTo spam,
-- while a SCUM/UE4SS restart can safely replay the latest desired command once.
function M.poll(callback)
  if not command_file then return end
  local f=io.open(command_file,"rb"); if not f then return end
  local text=f:read("*a") or "";f:close()
  if text=="" or not string.match(text,"\n$") then return end
  local max_seq=last_command_seq
  for line in string.gmatch(text,"([^\r\n]+)") do
    if line~="" then
      local cmd=parse_line(line)
      local seq=tonumber(cmd.seq) or 0
      if seq>last_command_seq then
        callback(cmd)
        if seq>max_seq then max_seq=seq end
      end
    end
  end
  last_command_seq=max_seq
end

return M
