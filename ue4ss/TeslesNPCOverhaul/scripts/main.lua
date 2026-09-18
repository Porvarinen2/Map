local src=debug.getinfo(1,"S").source:gsub("^@","")
local dir=src:match("^(.*[\\/])") or "./"
package.path=dir.."?.lua;"..dir.."?/init.lua;"..package.path
local util=require("modules.util")
local ipc=require("modules.ipc")
local probe=require("modules.probe")
local adapter=require("modules.scum_adapter")
local okCfg,cfg=pcall(require,"runtime_config")
if not okCfg then error("TeslesNPCOverhaul: runtime_config.lua missing. Run install.bat. "..tostring(cfg)) end
ipc.configure(cfg);probe.configure(cfg,ipc)
ipc.emit("BRIDGE_STARTED",{version="0.1.5-audit24fix",takeoverRequested=cfg.takeover_requested and "true" or "false"})
adapter.configure(cfg,ipc,probe)
local scheduler_ok = type(LoopInGameThreadWithDelay)=="function" and type(ExecuteInGameThreadWithDelay)=="function"
probe.cap("bridge_scheduler",scheduler_ok,scheduler_ok and "Delayed game-thread APIs available" or "Required delayed game-thread APIs missing")
if not scheduler_ok then error("TeslesNPCOverhaul: incompatible UE4SS build; delayed game-thread APIs missing") end
NotifyOnNewObject("/Script/Engine.Pawn",function(obj)
  util.delay_game_thread(0,function() adapter.register_actor(obj) end)
end)
util.delay_game_thread(cfg.scan_delay_ms or 6000,function() adapter.scan_existing() end)
util.loop_game_thread(cfg.tick_ms or 500,function() adapter.tick() end)
util.loop_game_thread(cfg.command_poll_ms or 150,function() ipc.poll(adapter.handle_command) end)
print("[TeslesNPCOverhaul] UE4SS bridge loaded; capability-gated takeover active.\n")
