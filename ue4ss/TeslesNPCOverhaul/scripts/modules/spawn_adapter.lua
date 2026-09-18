-- Tesles spawn adapter: materializes a persistent TeslesNPCEntity as a physical SCUM
-- actor and captures it back safely.
--
-- Contract with the Node brain:
--   SPAWN              persistentNpcId npcClass x y z generation
--     -> MATERIALIZED  persistentNpcId runtimeId body x y z [stableKey]
--     -> MATERIALIZE_FAILED persistentNpcId reason
--   CAPTURE_AND_DESPAWN persistentNpcId runtimeId
--     -> DEMATERIALIZED persistentNpcId x y z health body
--     -> CAPTURE_FAILED persistentNpcId reason      (actor is kept alive!)
--
-- Rules that must not be broken:
--   * one persistent id maps to at most one actor (idempotent spawn),
--   * physical state is read BEFORE the actor is destroyed,
--   * a failed read never destroys the actor: losing state is worse than a leak,
--   * no capability is reported OK before it actually succeeded on this build.
local util = require("modules.util")
local compat = require("modules.compat_profile")

local M = {
  actor_by_persistent_id = {},
  persistent_by_runtime = {},
  catalog = {},
  pending = {},
  primitive = nil,
  probe_state = {cycles = 0, running = false, failed = false}
}

local cfg, ipc, probe = nil, nil, nil
local catalog_emitted = false
local cached_world = nil
local health_reader = nil

function M.configure(c, i, p, health_fn)
  cfg, ipc, probe = c, i, p
  health_reader = health_fn
  M.actor_by_persistent_id = {}
  M.persistent_by_runtime = {}
  M.catalog = {}
  M.pending = {}
end

-- ---------------------------------------------------------------- world / class

local function find_world()
  if util.safe_valid(cached_world) then return cached_world end
  local ok, w = pcall(function() return FindFirstOf("World") end)
  if ok and util.safe_valid(w) then cached_world = w; compat.record("object", "World", true, util.safe_full_name(w)); return w end
  compat.record("object", "World", false, "FindFirstOf(\"World\") returned nothing usable")
  return nil
end

local function find_class(name)
  if name == nil or name == "" then return nil end
  local candidates = {name}
  if not string.find(name, "%.") then
    table.insert(candidates, name .. "_C")
    for _, root in ipairs(cfg.class_search_roots or {}) do
      table.insert(candidates, root .. name .. "." .. name .. "_C")
      table.insert(candidates, root .. name .. "." .. name)
    end
  end
  for _, candidate in ipairs(candidates) do
    local ok, obj = pcall(function() return StaticFindObject(candidate) end)
    if ok and util.safe_valid(obj) then
      compat.record("class", name, true, candidate)
      return obj
    end
  end
  compat.record("class", name, false, "no loaded UClass matched")
  return nil
end

-- ------------------------------------------------------------------- catalog

local function family_for(name)
  for family, patterns in pairs(cfg.body_family_patterns or {}) do
    if util.contains_any(name, patterns) then return family end
  end
  return nil
end

local function level_for(name)
  local lvl = string.match(tostring(name), "Lvl_(%d)")
  return tonumber(lvl)
end

function M.scan_class_catalog()
  local found = 0
  local ok = pcall(function()
    ForEachUObject(function(obj)
      local isClass = false
      local okC, res = pcall(function() return obj:IsA("/Script/CoreUObject.Class") end)
      if okC then isClass = res end
      if not isClass then return end
      local name = util.safe_full_name(obj)
      local family = family_for(name)
      if not family then return end
      local short = name:match("([^%.%s/]+)$") or name
      if M.catalog[short] then return end
      M.catalog[short] = {className = short, fullName = name, family = family, level = level_for(short)}
      found = found + 1
      ipc.emit("NPC_CLASS_CATALOG", {
        class = short, fullName = name, family = family,
        level = M.catalog[short].level or "", verified = "true"
      })
    end)
  end)
  catalog_emitted = true
  probe.cap("npc_class_catalog", ok and found > 0, ok and (tostring(found) .. " NPC classes discovered") or "class enumeration failed")
  compat.record("capability", "npc_class_catalog", ok and found > 0, tostring(found) .. " classes")
  return found
end

-- ------------------------------------------------------------- spawn strategies

local function make_transform(x, y, z)
  return {
    Translation = {X = x, Y = y, Z = z},
    Rotation = {X = 0.0, Y = 0.0, Z = 0.0, W = 1.0},
    Scale3D = {X = 1.0, Y = 1.0, Z = 1.0}
  }
end

local function strategy_gameplay_statics(cls, x, y, z)
  local world = find_world()
  if not world then return nil, "no world object" end
  local gs = StaticFindObject("/Script/Engine.Default__GameplayStatics")
  if not util.safe_valid(gs) then return nil, "GameplayStatics default object unavailable" end
  local transform = make_transform(x, y, z)
  local collision = tonumber(cfg.spawn_collision_handling) or 2
  local actor = nil
  local ok, err = pcall(function()
    actor = gs:BeginDeferredActorSpawnFromClass(world, cls, transform, collision, nil)
  end)
  if not ok or not util.safe_valid(actor) then return nil, "BeginDeferredActorSpawnFromClass failed: " .. tostring(err) end
  local okFinish, finishErr = pcall(function() gs:FinishSpawningActor(actor, transform) end)
  if not okFinish then return nil, "FinishSpawningActor failed: " .. tostring(finishErr) end
  if not util.safe_valid(actor) then return nil, "actor became invalid after FinishSpawningActor" end
  return actor, "GameplayStatics deferred spawn"
end

local function strategy_world_spawn_actor(cls, x, y, z)
  local world = find_world()
  if not world then return nil, "no world object" end
  local actor = nil
  local ok, err = pcall(function()
    actor = world:SpawnActor(cls, {X = x, Y = y, Z = z}, {Pitch = 0.0, Yaw = 0.0, Roll = 0.0})
  end)
  if not ok or not util.safe_valid(actor) then return nil, "UWorld:SpawnActor unavailable: " .. tostring(err) end
  return actor, "UWorld:SpawnActor"
end

local function strategy_configured(cls, x, y, z)
  for _, candidate in ipairs(cfg.spawn_function_candidates or {}) do
    local holder = StaticFindObject(candidate.object or "")
    if util.safe_valid(holder) then
      local actor = nil
      local ok, err = pcall(function()
        actor = holder[candidate.fn](holder, cls, {X = x, Y = y, Z = z})
      end)
      if ok and util.safe_valid(actor) then return actor, "configured spawner " .. tostring(candidate.object) .. ":" .. tostring(candidate.fn) end
      compat.record("function", tostring(candidate.object) .. ":" .. tostring(candidate.fn), false, tostring(err))
    end
  end
  return nil, "no configured spawn function produced an actor"
end

local strategies = {
  {name = "gameplay_statics", fn = strategy_gameplay_statics},
  {name = "world_spawn_actor", fn = strategy_world_spawn_actor},
  {name = "configured", fn = strategy_configured}
}

local function spawn_actor(cls, x, y, z)
  local errors = {}
  local ordered = {}
  if M.primitive then
    for _, s in ipairs(strategies) do if s.name == M.primitive then table.insert(ordered, s) end end
  end
  for _, s in ipairs(strategies) do if s.name ~= M.primitive then table.insert(ordered, s) end end
  for _, s in ipairs(ordered) do
    local actor, detail = s.fn(cls, x, y, z)
    compat.record("spawn_strategy", s.name, actor ~= nil, tostring(detail))
    if actor then
      M.primitive = s.name
      return actor, s.name .. ": " .. tostring(detail)
    end
    table.insert(errors, s.name .. "=" .. tostring(detail))
  end
  return nil, table.concat(errors, "; ")
end

-- -------------------------------------------------------------- identity tag

local function tag_actor(actor, persistentNpcId)
  local tag = "TESLES_ID:" .. tostring(persistentNpcId)
  local ok = pcall(function()
    local tags = actor.Tags
    if tags ~= nil and type(tags.Add) == "function" then tags:Add(tag) end
  end)
  local verified = false
  if ok then
    pcall(function()
      local tags = actor.Tags
      if tags ~= nil and type(tags.ForEach) == "function" then
        tags:ForEach(function(_, value)
          local okV, text = pcall(function() return tostring(value:get()) end)
          if okV and text == tag then verified = true end
        end)
      end
    end)
  end
  probe.cap("tesles_identity_tag", verified, verified and ("actor tag " .. tag .. " written and read back")
    or "actor Tags array not writable on this build; persistent identity stays in the bridge map only")
  compat.record("capability", "tesles_identity_tag", verified, tag)
  return verified
end

function M.read_tesles_id(actor)
  local found = nil
  pcall(function()
    local tags = actor.Tags
    if tags ~= nil and type(tags.ForEach) == "function" then
      tags:ForEach(function(_, value)
        local okV, text = pcall(function() return tostring(value:get()) end)
        if okV then
          local id = string.match(text, "^TESLES_ID:(.+)$")
          if id then found = id end
        end
      end)
    end
  end)
  return found
end

-- ------------------------------------------------------------------- spawning

local function emit_materialized(persistentNpcId, actor, runtimeId, className)
  local loc = util.safe_location(actor) or {x = 0, y = 0, z = 0}
  ipc.emit("MATERIALIZED", {
    persistentNpcId = persistentNpcId,
    runtimeId = runtimeId,
    body = className,
    x = loc.x, y = loc.y, z = loc.z,
    generation = M.actor_by_persistent_id[persistentNpcId] and M.actor_by_persistent_id[persistentNpcId].generation or ""
  })
end

local function fail(persistentNpcId, reason)
  ipc.emit("MATERIALIZE_FAILED", {persistentNpcId = persistentNpcId, reason = tostring(reason)})
  return false, reason
end

function M.spawn(args)
  local persistentNpcId = args.persistentNpcId
  if persistentNpcId == nil or persistentNpcId == "" then return false, "missing persistentNpcId" end
  local existing = M.actor_by_persistent_id[persistentNpcId]
  if existing and util.safe_valid(existing.actor) then
    -- Idempotent: a repeated SPAWN for a live actor re-reports it instead of cloning it.
    existing.generation = args.generation or existing.generation
    emit_materialized(persistentNpcId, existing.actor, existing.runtimeId, existing.className)
    return true, "already materialized"
  end
  local className = args.npcClass
  local cls = find_class(className)
  if not util.safe_valid(cls) then return fail(persistentNpcId, "class not found: " .. tostring(className)) end
  local x, y, z = tonumber(args.x), tonumber(args.y), tonumber(args.z)
  if not x or not y or not z then return fail(persistentNpcId, "bad spawn coordinates") end
  local actor, detail = spawn_actor(cls, x, y, z)
  if not actor then
    probe.cap("spawn_actor", false, tostring(detail))
    return fail(persistentNpcId, "spawn rejected: " .. tostring(detail))
  end
  local loc = util.safe_location(actor)
  if not loc then
    M.destroy_actor(actor)
    probe.cap("spawn_actor", false, "spawned actor had no readable location; destroyed again")
    return fail(persistentNpcId, "spawned actor location unreadable")
  end
  local runtimeId = util.safe_full_name(actor)
  M.actor_by_persistent_id[persistentNpcId] = {
    actor = actor, runtimeId = runtimeId, className = className,
    generation = args.generation or "", spawnedAt = util.now_ms()
  }
  M.persistent_by_runtime[runtimeId] = persistentNpcId
  probe.cap("spawn_actor", true, "spawned " .. tostring(className) .. " via " .. tostring(detail))
  tag_actor(actor, persistentNpcId)
  if type(M.on_actor_spawned) == "function" then pcall(M.on_actor_spawned, actor, persistentNpcId, runtimeId, className) end
  emit_materialized(persistentNpcId, actor, runtimeId, className)
  compat.flush()
  return true, runtimeId
end

-- ------------------------------------------------------------------ destroying

function M.destroy_actor(actor)
  if not util.safe_valid(actor) then return true, "actor already gone" end
  local ok, err = pcall(function() actor:K2_DestroyActor() end)
  if not ok then
    probe.cap("destroy_actor", false, "K2_DestroyActor failed: " .. tostring(err))
    return false, "K2_DestroyActor failed: " .. tostring(err)
  end
  local removed = not util.safe_valid(actor)
  probe.cap("destroy_actor", removed, removed and "actor destroyed and verified invalid" or "K2_DestroyActor returned but actor is still valid")
  return removed, removed and "destroyed" or "actor still valid after destroy"
end

function M.force_destroy(runtimeId)
  local persistentNpcId = M.persistent_by_runtime[runtimeId or ""]
  local record = persistentNpcId and M.actor_by_persistent_id[persistentNpcId] or nil
  if record then
    M.destroy_actor(record.actor)
    M.actor_by_persistent_id[persistentNpcId] = nil
    M.persistent_by_runtime[runtimeId] = nil
    return true, "forced destroy of " .. tostring(persistentNpcId)
  end
  return false, "no Tesles-owned actor for runtime id " .. tostring(runtimeId)
end

-- ------------------------------------------------------------------- capturing

-- Order is non-negotiable: verify ownership, read every proven piece of physical
-- state, emit it, and only then destroy the actor.
function M.capture_and_despawn(args)
  local persistentNpcId = args.persistentNpcId
  local record = M.actor_by_persistent_id[persistentNpcId or ""]
  if not record then
    ipc.emit("CAPTURE_FAILED", {persistentNpcId = persistentNpcId or "", reason = "no Tesles-owned actor for this persistent id"})
    return false, "unknown persistent id"
  end
  if not util.safe_valid(record.actor) then
    -- The actor vanished on its own: the entity is virtual again but nothing was lost.
    M.actor_by_persistent_id[persistentNpcId] = nil
    if record.runtimeId then M.persistent_by_runtime[record.runtimeId] = nil end
    ipc.emit("DEMATERIALIZED", {persistentNpcId = persistentNpcId, body = record.className or "", lost = "true"})
    return true, "actor already gone"
  end
  if args.runtimeId ~= nil and args.runtimeId ~= "" and args.runtimeId ~= record.runtimeId then
    ipc.emit("CAPTURE_FAILED", {persistentNpcId = persistentNpcId, reason = "runtime id mismatch"})
    return false, "runtime id mismatch"
  end
  local loc = util.safe_location(record.actor)
  if not loc then
    -- capture failed: keep the actor, Node will retry.
    ipc.emit("CAPTURE_FAILED", {persistentNpcId = persistentNpcId, reason = "final position unreadable"})
    return false, "position unreadable"
  end
  local health = nil
  if type(health_reader) == "function" then
    local okH, value = pcall(health_reader, record.actor)
    if okH and type(value) == "number" then health = value end
  end
  local fields = {persistentNpcId = persistentNpcId, x = loc.x, y = loc.y, z = loc.z, body = record.className or ""}
  if health ~= nil then fields.health = health end
  if type(M.on_before_destroy) == "function" then pcall(M.on_before_destroy, record.actor, persistentNpcId) end
  local destroyed, detail = M.destroy_actor(record.actor)
  if not destroyed then
    ipc.emit("CAPTURE_FAILED", {persistentNpcId = persistentNpcId, reason = "destroy failed: " .. tostring(detail)})
    return false, detail
  end
  M.actor_by_persistent_id[persistentNpcId] = nil
  if record.runtimeId then M.persistent_by_runtime[record.runtimeId] = nil end
  ipc.emit("DEMATERIALIZED", fields)
  compat.flush()
  return true, "dematerialized"
end

-- ---------------------------------------------------------------- probe cycles

-- Spawn/destroy is only declared stable after repeated clean cycles on this build.
function M.probe_spawn_primitive()
  if M.probe_state.running or M.probe_state.failed then return false end
  if not cfg.spawn_probe_enabled then return false end
  local className = nil
  for name, entry in pairs(M.catalog) do
    if cfg.spawn_probe_family == nil or entry.family == cfg.spawn_probe_family then className = name break end
  end
  if not className then return false end
  local cls = find_class(className)
  if not util.safe_valid(cls) then return false end
  local origin = cfg.spawn_probe_location
  if not origin then return false end
  M.probe_state.running = true
  local cycles = tonumber(cfg.spawn_probe_cycles) or 10
  local completed = 0
  for _ = 1, cycles do
    local actor, detail = spawn_actor(cls, origin.x, origin.y, origin.z)
    if not actor then
      M.probe_state.failed = true
      M.probe_state.running = false
      probe.cap("spawn_actor", false, "probe cycle failed: " .. tostring(detail))
      return false
    end
    local loc = util.safe_location(actor)
    local controllerOk = false
    pcall(function() controllerOk = util.safe_valid(actor.Controller) end)
    tag_actor(actor, "probe-" .. tostring(completed))
    local destroyed = M.destroy_actor(actor)
    if not loc or not destroyed then
      M.probe_state.failed = true
      M.probe_state.running = false
      probe.cap("spawn_actor", false, "probe cycle could not be cleaned up")
      return false
    end
    compat.record("spawn_probe", "cycle" .. tostring(completed), true, "controller=" .. tostring(controllerOk))
    completed = completed + 1
  end
  M.probe_state.cycles = completed
  M.probe_state.running = false
  probe.cap("spawn_actor", true, tostring(completed) .. " clean spawn/destroy cycles")
  compat.flush()
  return true
end

function M.tick()
  if not catalog_emitted then M.scan_class_catalog() end
  for persistentNpcId, record in pairs(M.actor_by_persistent_id) do
    if not util.safe_valid(record.actor) then
      M.actor_by_persistent_id[persistentNpcId] = nil
      if record.runtimeId then M.persistent_by_runtime[record.runtimeId] = nil end
      ipc.emit("NPC_GONE", {npcId = record.runtimeId or "", persistentNpcId = persistentNpcId})
    end
  end
  compat.flush()
end

function M.owned_persistent_id(runtimeId)
  return M.persistent_by_runtime[runtimeId or ""]
end

return M
