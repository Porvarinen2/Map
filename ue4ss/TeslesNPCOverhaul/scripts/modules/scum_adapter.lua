local util=require("modules.util")
local spawn_adapter=require("modules.spawn_adapter")
local weapon_adapter=require("modules.weapon_adapter")
local compat=require("modules.compat_profile")
local M={actors={},actor_by_id={},zombies={},players={}}
local cfg,ipc,probe=nil,nil,nil
local health_prop_by_class={}
local last_gunshot_by_source={}
local probe_npc_id=nil
local probe_restore_at=nil
local probe_move=nil
local movement_verified=false
local full_mode_active=false
local last_state_snapshot_at=0
local probe_retry_after=0
local function runtime_id(actor) return util.safe_full_name(actor) end
local function stable_key(actor,cls,loc)
  for _,name in ipairs({"PersistentId","PersistentID","UniqueId","UniqueID","EntityId","EntityID","Guid","GUID"}) do
    local ok,v=pcall(function() return actor:GetPropertyValue(name) end)
    if ok and v~=nil then local text=tostring(v);if text~="" and text~="nil" then probe.cap("stable_identity",true,"property:"..name);return cls.."|id|"..text end end
  end
  probe.cap("stable_identity",false,"no stable reflected id; identity remains session-scoped and will not spatially rebind")
  return nil
end
local function is_npc_name(name) return util.contains_any(name,cfg.npc_patterns) end
local function is_zombie_name(name) return util.contains_any(name,cfg.zombie_patterns) end
local function is_player_name(name) return util.contains_any(name,cfg.player_patterns) end
local function controller_of(pawn)
  local ok,c=pcall(function() return pawn.Controller end); if ok and util.safe_valid(c) then return c end
  local ok2,c2=pcall(function() return pawn:GetController() end); if ok2 and util.safe_valid(c2) then return c2 end
  return nil
end
local function brain_of(controller)
  if not util.safe_valid(controller) then return nil end
  local ok,b=pcall(function() return controller.BrainComponent end); if ok and util.safe_valid(b) then return b end
  return nil
end
local function property_short_name(prop)
  local ok,n=pcall(function() return tostring(prop:GetFName()) end); if ok then return n end
  local full=util.safe_full_name(prop); return full:match("([^%.: ]+)$") or full
end
local function health_property_for(actor)
  local clsName=util.safe_class_name(actor)
  local cached=health_prop_by_class[clsName]
  if cached then local ok,v=pcall(function() return actor:GetPropertyValue(cached) end); if ok and type(v)=="number" then return cached,v end end
  local candidates={};local ok,cls=pcall(function() return actor:GetClass() end); if not ok then return nil,nil end
  local depth=0
  while util.safe_valid(cls) and depth<12 do
    pcall(function() cls:ForEachProperty(function(prop)
      local n=property_short_name(prop); local l=string.lower(n); local score=0
      if l=="health" then score=100 elseif string.find(l,"currenthealth",1,true) then score=95 elseif string.find(l,"healthpoints",1,true) then score=90 elseif l=="hp" then score=85 elseif string.find(l,"health",1,true) and not string.find(l,"max",1,true) then score=60 elseif string.find(l,"life",1,true) and not string.find(l,"lifetime",1,true) then score=40 end
      if score>0 then table.insert(candidates,{name=n,score=score}) end
    end) end)
    local okS,super=pcall(function() return cls:GetSuperStruct() end); if not okS then break end; cls=super;depth=depth+1
  end
  table.sort(candidates,function(a,b)return a.score>b.score end)
  for _,c in ipairs(candidates) do local okV,v=pcall(function() return actor:GetPropertyValue(c.name) end); if okV and type(v)=="number" then health_prop_by_class[clsName]=c.name;probe.cap("health_read",true,clsName..":"..c.name);return c.name,v end end
  return nil,nil
end
local function register_zombie(actor,full)
  local id=full;M.zombies[id]={actor=actor,id=id};local loc=util.safe_location(actor);if loc then ipc.emit("ZOMBIE_SEEN",{zombieId=id,x=loc.x,y=loc.y,z=loc.z}) end
end
local function register_player(actor,full)
  local id=full;M.players[id]={actor=actor,id=id};local loc=util.safe_location(actor);if loc then ipc.emit("PLAYER_SEEN",{playerId=id,x=loc.x,y=loc.y,z=loc.z}) end
end
local function owning_actor(context)
  local o=context
  for _=1,8 do
    if not util.safe_valid(o) then return nil end
    local full=util.safe_full_name(o)
    if M.actor_by_id[full] or M.zombies[full] or M.players[full] then return o end
    local ok,isActor=pcall(function() return o:IsA("/Script/Engine.Actor") end)
    if ok and isActor and (is_npc_name(full) or is_zombie_name(full) or is_player_name(full)) then return o end
    local okO,outer=pcall(function() return o:GetOuter() end);if not okO then return nil end;o=outer
  end
  return nil
end
local function hook_event(kind,context,path)
  local owner=owning_actor(context);if not owner then return end
  local full=runtime_id(owner);local rec=M.actor_by_id[full]
  if kind=="GUNSHOT" then
    local key=full.."|"..path;local now=util.now_ms();if last_gunshot_by_source[key] and now-last_gunshot_by_source[key]<1000 then return end;last_gunshot_by_source[key]=now
    local loc=util.safe_location(owner);if loc then ipc.emit("GUNSHOT",{sourceId=full,x=loc.x,y=loc.y,z=loc.z,intensity=1,functionName=path}) end
  elseif kind=="DEATH" and rec and not rec.dead then rec.dead=true;ipc.emit("NPC_DEATH",{npcId=full,persistentNpcId=rec.persistentNpcId or "",functionName=path});probe.cap("death_detection",true,"hook:"..path) end
end
local function move_request_accepted(res)
  if res==nil then return false,"nil result" end
  if type(res)=="number" then return res~=0,"numeric result="..tostring(res) end
  local text=tostring(res)
  local lower=string.lower(text)
  if string.find(lower,"failed",1,true) or string.find(lower,"failure",1,true) or string.find(lower,"invalid",1,true) or string.find(lower,"error",1,true) then return false,text end
  if string.find(text,"RequestSuccessful",1,true) or string.find(text,"AlreadyAtGoal",1,true) or string.find(lower,"success",1,true) then return true,text end
  return false,"unrecognized MoveToLocation result: "..text
end
local function stop_brain(rec,reason)
  if not rec or not util.safe_valid(rec.brain) then return false,"no brain" end
  local okStop,err=pcall(function() rec.brain:StopLogic(reason or "Tesles NPC takeover") end)
  local running=nil
  local okRun,runErr=pcall(function() running=rec.brain:IsRunning() end)
  local stopped=okStop and okRun and running==false
  rec.taken_over=stopped
  local detail
  if stopped then detail="StopLogic succeeded; IsRunning verified false"
  elseif not okStop then detail="StopLogic call failed: "..tostring(err)
  elseif not okRun then detail="StopLogic returned but IsRunning verification failed: "..tostring(runErr)
  else detail="StopLogic returned but brain still running: "..tostring(running) end
  return stopped,detail
end
local function start_capability_probe(rec)
  if probe_npc_id~=nil or movement_verified or not rec or rec.dead then return false end
  if not util.safe_valid(rec.actor) or not util.safe_valid(rec.controller) or not util.safe_valid(rec.brain) then return false end
  local loc=util.safe_location(rec.actor); if not loc then return false end
  probe_npc_id=rec.id;rec.last_probe_at=util.now_ms()
  local stopped,detail=stop_brain(rec,"Tesles capability probe");probe.cap("brain_stop",stopped,detail)
  if not stopped then probe_npc_id=nil;probe_retry_after=util.now_ms()+2000;return false end
  local target={x=loc.x+200.0,y=loc.y,z=loc.z}
  local okMove,moveRes=pcall(function() return rec.controller:MoveToLocation({X=target.x,Y=target.y,Z=target.z},30.0,true,true,false,true,nil,true) end)
  local accepted,moveDetail=false,tostring(moveRes)
  if okMove then accepted,moveDetail=move_request_accepted(moveRes) end
  if okMove and accepted then probe_move={npcId=rec.id,start={x=loc.x,y=loc.y,z=loc.z},target=target,requestedAt=util.now_ms(),result=moveDetail}
  else probe.cap("movement",false,okMove and ("MoveToLocation returned "..moveDetail) or tostring(moveRes)) end
  probe_restore_at=util.now_ms()+(tonumber(cfg.probe_restore_ms) or 5000)
  return true
end
local function retry_probe_if_needed(now)
  if movement_verified or probe_npc_id~=nil or full_mode_active or now<probe_retry_after then return end
  if not cfg.takeover_requested or cfg.takeover_mode=="observe" then return end
  local best=nil;local bestAt=math.huge
  for _,rec in pairs(M.actors) do
    if takeover_candidate(rec) and util.safe_valid(rec.actor) and util.safe_valid(rec.controller) and util.safe_valid(rec.brain) then
      local last=tonumber(rec.last_probe_at) or 0
      if last<bestAt then best=rec;bestAt=last end
    end
  end
  if best and (bestAt==0 or now-bestAt>=5000) then start_capability_probe(best) end
end
local function restore_brain(rec,reason)
  if not rec or rec.dead or not rec.taken_over then return true,"brain already released" end
  if not util.safe_valid(rec.brain) then return false,"brain unavailable during release" end
  local okStart,startErr=pcall(function() rec.brain:StartLogic() end)
  local running=false;local okRun=pcall(function() running=rec.brain:IsRunning() end)
  local restored=okStart and okRun and running==true
  local detail=restored and "StartLogic verified by IsRunning" or ("StartLogic failed/not running: "..tostring(startErr))
  if not restored then
    local okRestart,restartErr=pcall(function() rec.brain:RestartLogic() end)
    running=false;okRun=pcall(function() running=rec.brain:IsRunning() end)
    restored=okRestart and okRun and running==true
    detail=restored and "RestartLogic verified by IsRunning" or (detail.."; RestartLogic failed/not running: "..tostring(restartErr))
  end
  rec.taken_over=not restored
  if reason then detail=tostring(reason)..": "..detail end
  return restored,detail
end
local function release_all_takeovers(reason)
  full_mode_active=false
  local all_restored=true;local failures={}
  for id,rec in pairs(M.actors) do
    if rec.taken_over and not rec.dead then
      local restored,detail=restore_brain(rec,reason or "Tesles takeover release")
      if not restored then all_restored=false;table.insert(failures,id.."="..tostring(detail)) end
    end
  end
  probe.cap("full_takeover_ready",false,reason or "full takeover released")
  probe.cap("brain_restore",all_restored,all_restored and "all taken-over NPC brains released" or table.concat(failures,"; "))
  return all_restored
end
local function takeover_candidate(rec)
  -- Production takeover is bound to actors Tesles materialized itself. Unmanaged
  -- vanilla NPCs keep their own brain unless the server explicitly opts in.
  if not rec or rec.dead then return false end
  if cfg.adopt_unmanaged==true then return true end
  return rec.tesles_owned==true
end
local function activate_full_takeover()
  if full_mode_active then return true end
  for id,rec in pairs(M.actors) do
    if takeover_candidate(rec) then
      local stopped,detail=stop_brain(rec,"Tesles full takeover activation")
      if not stopped then
        release_all_takeovers("activation rollback: failed to stop brain for "..id)
        probe.cap("brain_stop",false,"full takeover activation failed for "..id..": "..tostring(detail))
        return false
      end
    end
  end
  full_mode_active=true
  probe.cap("brain_stop",true,"all live NPC brains stopped for full takeover")
  probe.cap("full_takeover_ready",true,"full mode active by explicit configuration; movement and brain validation remain monitored")
  return true
end
function M.register_actor(actor)
  if not util.safe_valid(actor) then return end
  local full=runtime_id(actor);local cls=util.safe_class_name(actor)
  if is_zombie_name(full) or is_zombie_name(cls) then register_zombie(actor,full);return end
  if not (is_npc_name(full) or is_npc_name(cls)) then if is_player_name(full) or is_player_name(cls) then register_player(actor,full) end;return end
  local id=full;if M.actors[id] then return end
  probe.set_event_handler(hook_event)
  local loc=util.safe_location(actor)
  -- Tesles-owned actors are the materialized body of an existing persistent entity.
  -- They are never allowed to be discovered as a new, unmanaged NPC.
  local persistentNpcId=spawn_adapter.owned_persistent_id(id) or spawn_adapter.read_tesles_id(actor)
  M.actors[id]={actor=actor,id=id,persistentNpcId=persistentNpcId,tesles_owned=persistentNpcId~=nil,stableKey=stable_key(actor,cls,loc),body=cls,controller=nil,brain=nil,last_loc=loc,taken_over=false,dead=false,last_health=nil,seen_emitted=false}
  M.actor_by_id[id]=M.actors[id]
  probe.dump_class(actor,"NPC",true);probe.inspect_weapon_members(actor)
  if loc then
    ipc.emit("NPC_SEEN",{npcId=id,persistentNpcId=M.actors[id].persistentNpcId or "",stableKey=M.actors[id].stableKey,body=cls,x=loc.x,y=loc.y,z=loc.z})
    M.actors[id].seen_emitted=true
    probe.cap("location_read",true,"K2_GetActorLocation")
  else
    probe.cap("location_read",false,"K2_GetActorLocation unavailable during discovery; registration deferred until a valid location is readable")
  end
  probe.cap("npc_discovery",true,cls)
  local hpName,hp=health_property_for(actor);if hpName then M.actors[id].last_health=hp end
  local c=controller_of(actor);M.actors[id].controller=c
  if c then probe.cap("controller_read",true,util.safe_class_name(c));probe.dump_class(c,"CONTROLLER") else probe.cap("controller_read",false,"controller not readable") end
  local b=brain_of(c);M.actors[id].brain=b
  if not b then probe.cap("brain_stop",false,"BrainComponent not found");return end
  probe.dump_class(b,"BRAIN")
  if not cfg.takeover_requested or cfg.takeover_mode=="observe" then return end
  if full_mode_active and takeover_candidate(M.actors[id]) then
    local ok,detail=stop_brain(M.actors[id],"Tesles full takeover")
    if not ok then release_all_takeovers("new NPC takeover failed for "..id);probe.cap("brain_stop",false,detail) else probe.cap("brain_stop",true,detail) end
    return
  end
  if probe_npc_id==nil and not movement_verified and takeover_candidate(M.actors[id]) then start_capability_probe(M.actors[id]) end
end
function M.scan_existing()
  ForEachUObject(function(o)local ok,isPawn=pcall(function() return o:IsA("/Script/Engine.Pawn") end);if ok and isPawn then M.register_actor(o) end end)
end
function M.tick()
  if (cfg.takeover_mode=="probe" or cfg.takeover_mode=="auto" or cfg.takeover_mode=="full") and probe_npc_id and probe_restore_at and util.now_ms()>=probe_restore_at then
    local rec=M.actor_by_id[probe_npc_id]
    if not rec or not util.safe_valid(rec.actor) then probe_npc_id=nil;probe_restore_at=nil;probe_move=nil;probe_retry_after=util.now_ms()+1000
    elseif util.safe_valid(rec.brain) and rec.taken_over then
      local okStart,startErr=pcall(function() rec.brain:StartLogic() end);local running=false;local okRun=pcall(function() running=rec.brain:IsRunning() end);local restored=okStart and okRun and running==true;local detail=restored and "StartLogic verified by IsRunning" or ("StartLogic failed/not running: "..tostring(startErr))
      if not restored then local okRestart,restartErr=pcall(function() rec.brain:RestartLogic() end);running=false;okRun=pcall(function() running=rec.brain:IsRunning() end);restored=okRestart and okRun and running==true;detail=restored and "RestartLogic verified by IsRunning" or (detail.."; RestartLogic failed/not running: "..tostring(restartErr)) end
      rec.taken_over=not restored;probe.cap("brain_restore",restored,detail);ipc.emit("PROBE_RESTORED",{npcId=probe_npc_id,ok=restored and "true" or "false"})
      if restored then
        probe_restore_at=nil
        local completed_id=probe_npc_id
        probe_npc_id=nil;probe_move=nil
        if cfg.takeover_mode=="full" and movement_verified then activate_full_takeover()
        elseif cfg.takeover_mode=="auto" then probe.cap("full_takeover_ready",false,"auto mode remains safe-probe until a build-specific weapon command primitive is implemented and verified")
        elseif cfg.takeover_mode=="full" then probe.cap("full_takeover_ready",false,"full mode waiting for a successful movement capability probe") end
        ipc.emit("PROBE_SLOT_RELEASED",{npcId=completed_id or ""})
        if not movement_verified then probe_retry_after=util.now_ms()+1000 end
      else probe_restore_at=util.now_ms()+2000 end
    else probe_npc_id=nil;probe_restore_at=nil;probe_move=nil;probe_retry_after=util.now_ms()+1000 end
  end
  for id,rec in pairs(M.actors) do
    if not util.safe_valid(rec.actor) then M.actors[id]=nil;M.actor_by_id[id]=nil;ipc.emit("NPC_GONE",{npcId=id})
    else
      local loc=util.safe_location(rec.actor)
      if loc then
        rec.last_loc=loc
        if not rec.seen_emitted then
          ipc.emit("NPC_SEEN",{npcId=id,persistentNpcId=rec.persistentNpcId or "",stableKey=rec.stableKey,body=rec.body,x=loc.x,y=loc.y,z=loc.z})
          rec.seen_emitted=true
          probe.cap("location_read",true,"K2_GetActorLocation recovered after deferred discovery")
        end
      end
      local hpName,hp=health_property_for(rec.actor)
      if hpName and type(hp)=="number" then
        if rec.last_health and hp<rec.last_health and hp>0 and not rec.dead then ipc.emit("NPC_DAMAGE",{npcId=id,persistentNpcId=rec.persistentNpcId or "",health=hp,previousHealth=rec.last_health,damageFraction=math.min(1,math.max(0,(rec.last_health-hp)/math.max(math.abs(rec.last_health),1))),property=hpName}) end
        if rec.last_health and rec.last_health>0 and hp<=0 and not rec.dead then rec.dead=true;ipc.emit("NPC_DEATH",{npcId=id,persistentNpcId=rec.persistentNpcId or "",health=hp,property=hpName});probe.cap("death_detection",true,"numeric health crossed zero: "..hpName) end
        rec.last_health=hp
      end
      if rec.taken_over and util.safe_valid(rec.brain) and not rec.dead then
        local running=false
        local okRun,runErr=pcall(function() running=rec.brain:IsRunning() end)
        if not okRun then
          release_all_takeovers("BrainComponent IsRunning inspection failed for "..id)
          probe.cap("brain_stop",false,"takeover verification lost because IsRunning failed for "..id..": "..tostring(runErr))
        elseif running then
          local suppressed,detail=stop_brain(rec,"Tesles takeover watchdog")
          ipc.emit("BRAIN_RECLAIM",{npcId=id,suppressed=suppressed and "true" or "false",detail=detail})
          if not suppressed then release_all_takeovers("unsuppressed vanilla brain reclaim for "..id);probe.cap("brain_stop",false,"brain reclaim could not be suppressed for "..id..": "..tostring(detail)) end
        end
      end
    end
  end
  if probe_move then
    local rec=M.actor_by_id[probe_move.npcId];local loc=rec and util.safe_valid(rec.actor) and util.safe_location(rec.actor) or nil;local elapsed=util.now_ms()-probe_move.requestedAt
    if loc then
      local moved=math.sqrt((loc.x-probe_move.start.x)^2+(loc.y-probe_move.start.y)^2+(loc.z-probe_move.start.z)^2)
      local d0=math.sqrt((probe_move.target.x-probe_move.start.x)^2+(probe_move.target.y-probe_move.start.y)^2)
      local d1=math.sqrt((probe_move.target.x-loc.x)^2+(probe_move.target.y-loc.y)^2)
      if moved>=20 and d1<d0 then
        movement_verified=true;probe.cap("movement",true,"Observed movement toward offset probe target; request="..probe_move.result);probe_move=nil
      elseif elapsed>7000 then
        probe.cap("movement",false,"MoveTo request produced no observed progress; request="..probe_move.result);probe_move=nil
      end
    elseif elapsed>7000 then
      probe.cap("movement",false,"Probe actor/location became unavailable before movement could be verified");probe_move=nil
    end
  end
  local now=util.now_ms();retry_probe_if_needed(now);if now-last_state_snapshot_at>=(tonumber(cfg.state_snapshot_ms) or 1000) then
    local records={}
    for id,rec in pairs(M.actors) do if util.safe_valid(rec.actor) then local loc=util.safe_location(rec.actor);if loc then table.insert(records,{type="NPC_POSITION",fields={npcId=id,persistentNpcId=rec.persistentNpcId or "",x=loc.x,y=loc.y,z=loc.z}}) end end end
    for id,rec in pairs(M.zombies) do if not util.safe_valid(rec.actor) then M.zombies[id]=nil else local loc=util.safe_location(rec.actor);if loc then table.insert(records,{type="ZOMBIE_SEEN",fields={zombieId=id,x=loc.x,y=loc.y,z=loc.z}}) end end end
    for id,rec in pairs(M.players) do if not util.safe_valid(rec.actor) then M.players[id]=nil else local loc=util.safe_location(rec.actor);if loc then table.insert(records,{type="PLAYER_SEEN",fields={playerId=id,x=loc.x,y=loc.y,z=loc.z}}) end end end
    ipc.write_state(records);last_state_snapshot_at=now
  end
  spawn_adapter.tick()
end
local function move(rec,cmd)
  if not rec or not util.safe_valid(rec.controller) then return false,"no controller" end
  local x,y,z=tonumber(cmd.x),tonumber(cmd.y),tonumber(cmd.z);if not x or not y or not z then return false,"bad coordinates" end
  local ok,res=pcall(function() return rec.controller:MoveToLocation({X=x,Y=y,Z=z},tonumber(cmd.acceptanceRadius) or 150.0,true,true,true,true,nil,true) end)
  if not ok then return false,tostring(res) end
  local accepted,detail=move_request_accepted(res)
  if not accepted then return false,"MoveToLocation returned "..detail end
  return true,detail
end
local function result(cmd,ok,detail,extra)
  local fields={seq=cmd.seq or 0,commandKey=cmd.commandKey or "",commandType=cmd.type,npcId=cmd.npcId or "",persistentNpcId=cmd.persistentNpcId or "",ok=ok and "true" or "false",detail=tostring(detail or "")}
  for k,v in pairs(extra or {}) do fields[k]=v end
  ipc.emit("COMMAND_RESULT",fields)
end
local function owned_record(cmd)
  local persistentNpcId=cmd.persistentNpcId
  local record=persistentNpcId and spawn_adapter.actor_by_persistent_id[persistentNpcId] or nil
  if not record then return nil end
  local rec=M.actor_by_id[record.runtimeId or ""]
  if rec then return rec end
  return {id=record.runtimeId,actor=record.actor,controller=controller_of(record.actor),persistentNpcId=persistentNpcId,tesles_owned=true}
end
function M.handle_command(cmd)
  local rec=M.actor_by_id[cmd.npcId or ""]
  local blocked = rec and not rec.taken_over
  if cmd.type=="MOVE" then
    local ok,detail
    if blocked then ok,detail=false,"brain not taken over for this actor"
    else ok,detail=move(rec,cmd) end
    result(cmd,ok,detail,{accuracyMultiplier=cmd.accuracyMultiplier or ""})
  elseif cmd.type=="STOP" then
    local ok,detail=false,"no controller"
    if blocked then detail="brain not taken over for this actor"
    elseif rec and util.safe_valid(rec.controller) then
      local callOk,err=pcall(function() rec.controller:StopMovement() end)
      ok=callOk;detail=tostring(err or "")
    end
    result(cmd,ok,detail)
  elseif cmd.type=="SPAWN" then
    local ok,detail=spawn_adapter.spawn(cmd)
    result(cmd,ok,detail)
  elseif cmd.type=="CAPTURE_AND_DESPAWN" then
    -- Stop shooting and moving before the body is read and removed.
    local owned=owned_record(cmd)
    if owned then
      weapon_adapter.release(owned)
      if util.safe_valid(owned.controller) then pcall(function() owned.controller:StopMovement() end) end
    end
    local ok,detail=spawn_adapter.capture_and_despawn(cmd)
    result(cmd,ok,detail)
  elseif cmd.type=="FORCE_DESTROY" then
    local owned=owned_record(cmd)
    if owned then weapon_adapter.release(owned) end
    local ok,detail=spawn_adapter.force_destroy(cmd.runtimeId or (owned and owned.id))
    result(cmd,ok,detail)
  elseif cmd.type=="AIM" or cmd.type=="FIRE_START" or cmd.type=="FIRE_STOP" or cmd.type=="RELOAD" then
    local owned=owned_record(cmd) or rec
    local ok,detail=false,"no Tesles-owned actor for this command"
    if owned and (owned.tesles_owned or cfg.adopt_unmanaged==true) then ok,detail=weapon_adapter.handle(owned,cmd) end
    result(cmd,ok,detail)
  else
    result(cmd,false,"unsupported command type "..tostring(cmd.type))
  end
end
function M.configure(c,i,p)
  cfg,ipc,probe=c,i,p
  compat.configure(c,i)
  spawn_adapter.configure(c,i,p,function(actor) local _,hp=health_property_for(actor); return hp end)
  weapon_adapter.configure(c,i,p)
  spawn_adapter.on_actor_spawned=function(actor,persistentNpcId,runtimeId,className)
    -- Bind immediately so the freshly spawned body can never be discovered as a new NPC.
    M.actors[runtimeId]={actor=actor,id=runtimeId,persistentNpcId=persistentNpcId,tesles_owned=true,stableKey=nil,body=className,controller=nil,brain=nil,last_loc=util.safe_location(actor),taken_over=false,dead=false,last_health=nil,seen_emitted=true}
    M.actor_by_id[runtimeId]=M.actors[runtimeId]
    local controller=controller_of(actor)
    M.actors[runtimeId].controller=controller
    if controller then probe.cap("controller_read",true,util.safe_class_name(controller)) end
    local brain=brain_of(controller)
    M.actors[runtimeId].brain=brain
    if brain and cfg.takeover_requested and cfg.takeover_mode~="observe" then
      local stopped,detail=stop_brain(M.actors[runtimeId],"Tesles takeover of materialized NPC")
      probe.cap("brain_stop",stopped,detail)
      if stopped then probe.cap("full_takeover_ready",true,"vanilla decision AI stopped on a Tesles-owned actor") end
    end
  end
  spawn_adapter.on_before_destroy=function(actor,persistentNpcId)
    local runtimeId=util.safe_full_name(actor)
    weapon_adapter.forget(runtimeId)
    M.actors[runtimeId]=nil
    M.actor_by_id[runtimeId]=nil
  end
  if cfg.takeover_mode=="auto" then probe.cap("weapon_use",false,"build-specific weapon command primitive not yet verified; auto takeover stays in safe probe mode")
  elseif cfg.takeover_mode=="full" then full_mode_active=false;probe.cap("full_takeover_ready",false,"full mode armed; waiting for reversible brain + movement capability probe") end
end
return M
