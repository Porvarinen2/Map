local util = require("modules.util")
local M = {}
local cfg, ipc, seen_caps, probe_file = nil,nil,{},nil
local keywords = {"Move","Path","Brain","Behavior","Target","Focus","Fire","Shoot","Shot","Weapon","Attack","Damage","Death","Died","Spawn","Perception","Health"}
local hooks, event_handler = {}, nil
local dumped_classes = {}
function M.configure(c,i) cfg,ipc,probe_file=c,i,c.probe_file end
function M.set_event_handler(fn) event_handler=fn end
local function write(line)
  local f=io.open(probe_file,"a"); if f then f:write(os.date("!%Y-%m-%dT%H:%M:%SZ").." "..line.."\n");f:close() end
end
function M.cap(name, ok, detail)
  local key=name..":"..tostring(ok)..":"..tostring(detail or "")
  if seen_caps[name]==key then return end; seen_caps[name]=key
  ipc.emit("CAPABILITY",{name=name,ok=ok and "true" or "false",detail=detail or ""}); write("CAP "..name.."="..tostring(ok).." "..tostring(detail or ""))
end
local function short_function_name(full)
  local s=tostring(full or ""):gsub("^Function%s+","")
  return s:match("[:%.]([^:%.]+)$") or s
end
local function function_kind(full)
  local n=string.lower(short_function_name(full))
  if n=="onweaponfired" or n=="weaponfired" or n=="fireweapon" or n=="startfire" or n=="onfireweapon" or n=="onshotfired" or n=="shotfired" then return "GUNSHOT" end
  if n=="ondeath" or n=="died" or n=="die" or n=="handledeath" or n=="oncharacterdeath" or n=="characterdied" then return "DEATH" end
  return nil
end
local function unwrap_context(ctx)
  if ctx==nil then return nil end
  local ok,v=pcall(function() return ctx:get() end); if ok and v then return v end
  return ctx
end
local function hook_function(full,kind)
  local path=tostring(full):gsub("^Function%s+","")
  if hooks[path] then return end
  local ok,pre,post=pcall(function()
    local a,b=RegisterHook(path,function(Context,...)
      if event_handler then pcall(event_handler,kind,unwrap_context(Context),path) end
    end)
    return a,b
  end)
  if ok and pre then
    hooks[path]={pre=pre,post=post,kind=kind};write("HOOK "..kind.." "..path)
    if kind=="GUNSHOT" then M.cap("gunshot_event",true,path) elseif kind=="DEATH" then M.cap("death_hook",true,path) end
  else write("HOOK_FAIL "..kind.." "..path.." "..tostring(pre)) end
end
local function scan_class(cls,label,installHooks)
  local depth=0
  while util.safe_valid(cls) and depth<16 do
    local cname=util.safe_full_name(cls); write("CLASS "..cname)
    pcall(function() cls:ForEachFunction(function(fn)
      local n=util.safe_full_name(fn); for _,kw in ipairs(keywords) do if string.find(n,kw,1,true) then write("  FN "..n);break end end
      if installHooks then local kind=function_kind(n); if kind then hook_function(n,kind) end end
    end) end)
    pcall(function() cls:ForEachProperty(function(prop)
      local n=util.safe_full_name(prop); for _,kw in ipairs(keywords) do if string.find(n,kw,1,true) then write("  PROP "..n);break end end
    end) end)
    local okS,super=pcall(function() return cls:GetSuperStruct() end); if not okS then break end; cls=super; depth=depth+1
  end
end
function M.dump_class(obj,label,installHooks)
  if not util.safe_valid(obj) then return end
  local ok, cls=pcall(function() return obj:GetClass() end); if not ok or not util.safe_valid(cls) then return end
  local key=label.."|"..util.safe_full_name(cls)
  if dumped_classes[key] then return end
  dumped_classes[key]=true
  write("=== "..label.." "..util.safe_full_name(obj).." ===")
  scan_class(cls,label,installHooks==true)
end
function M.inspect_weapon_members(obj)
  if not util.safe_valid(obj) then return end
  local ok,cls=pcall(function() return obj:GetClass() end); if not ok then return end
  local depth=0
  while util.safe_valid(cls) and depth<8 do
    pcall(function() cls:ForEachProperty(function(prop)
      local okN,n=pcall(function() return tostring(prop:GetFName()) end); if not okN then return end
      local low=string.lower(n)
      if string.find(low,"weapon",1,true) or string.find(low,"firearm",1,true) or string.find(low,"gun",1,true) then
        local okV,v=pcall(function() return obj:GetPropertyValue(n) end)
        if okV and util.safe_valid(v) then M.dump_class(v,"WEAPON_MEMBER:"..n,true) end
      end
    end) end)
    local okS,super=pcall(function() return cls:GetSuperStruct() end); if not okS then break end; cls=super;depth=depth+1
  end
end
return M
