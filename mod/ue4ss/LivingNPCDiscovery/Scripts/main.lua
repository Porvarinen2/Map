--[[
  LivingNPC - luokkakartoitus.

  Ei muuta peliä mitenkään. Etsii SCUMin hahmo-, AI- ja spawner-luokat ja
  kirjoittaa raportin tiedostoon, jotta natiivi modi tietaa mita hookata.

  Raportti: <SCUM Server>\SCUM\Binaries\Win64\LivingNPC_classes.txt
]]

local REPORT = "LivingNPC_classes.txt"
local PATTERNS = {
  character = { "Character", "Pawn", "Puppet", "Prisoner", "Human", "NPC", "Bot" },
  ai        = { "AIController", "BehaviorTree", "Blackboard", "AIPerception", "Brain" },
  spawner   = { "Spawner", "SpawnPoint", "Spawn_", "Population" },
  world     = { "GameMode", "GameState", "WorldSettings", "Level" },
}

local function matchesAny(name, patterns)
  for _, pattern in ipairs(patterns) do
    if name:find(pattern, 1, true) then return true end
  end
  return false
end

local function safeName(object)
  local ok, name = pcall(function() return object:GetFullName() end)
  if ok and name then return name end
  return "<unnamed>"
end

--- Counts live instances of a class without keeping references around.
local function countInstances(className)
  local count = 0
  local ok = pcall(function()
    local instances = FindAllOf(className)
    if instances then count = #instances end
  end)
  if not ok then return -1 end
  return count
end

local function collect()
  local found = {}
  for group, _ in pairs(PATTERNS) do found[group] = {} end

  local ok, err = pcall(function()
    ForEachUObject(function(object, _, _)
      local class = object:GetClass()
      if not class then return end
      local className = class:GetFName():ToString()
      for group, patterns in pairs(PATTERNS) do
        if matchesAny(className, patterns) then
          local bucket = found[group]
          bucket[className] = (bucket[className] or 0) + 1
          break
        end
      end
    end)
  end)
  if not ok then print("[LivingNPC] UObject-kierros epaonnistui: " .. tostring(err) .. "\n") end
  return found
end

local function writeReport(found)
  local file, err = io.open(REPORT, "w")
  if not file then
    print("[LivingNPC] Raporttia ei voitu kirjoittaa: " .. tostring(err) .. "\n")
    return
  end

  file:write("SCUM Living NPC - luokkakartoitus\n")
  file:write("UE4SS: " .. tostring(UE4SS and UE4SS.GetVersion and UE4SS.GetVersion() or "?") .. "\n\n")

  local order = { "character", "ai", "spawner", "world" }
  for _, group in ipairs(order) do
    file:write("== " .. group:upper() .. " ==\n")
    local names = {}
    for name in pairs(found[group] or {}) do names[#names + 1] = name end
    table.sort(names)
    for _, name in ipairs(names) do
      file:write(string.format("%-60s objects=%d live=%d\n", name, found[group][name], countInstances(name)))
    end
    file:write("\n")
  end

  local player = nil
  pcall(function() player = FindFirstOf("PlayerController") end)
  if player and player:IsValid() then
    file:write("PlayerController: " .. safeName(player) .. "\n")
  end
  local gameMode = nil
  pcall(function() gameMode = FindFirstOf("GameModeBase") end)
  if gameMode and gameMode:IsValid() then
    file:write("GameMode: " .. safeName(gameMode) .. "\n")
  end

  file:close()
  print("[LivingNPC] Raportti kirjoitettu: " .. REPORT .. "\n")
end

local function run()
  print("[LivingNPC] Kartoitetaan luokat...\n")
  writeReport(collect())
end

-- Aja kun peli/serveri on ladannut maailman, ja uudelleen komennolla.
ExecuteWithDelay(15000, run)
RegisterConsoleCommandHandler("livingnpc_scan", function()
  run()
  return true
end)
