const test=require('node:test'); const assert=require('node:assert/strict'); const fs=require('fs'); const path=require('path');
const root=path.resolve(__dirname,'..','..');
function read(rel){return fs.readFileSync(path.join(root,rel),'utf8');}

test('brain stop script resolves this package own Windows server.js path',()=>{
 const s=read('server/StopTeslesNPCBrain.bat');
 assert.match(s,/MOD_ROOT/);
 assert.match(s,/%MOD_ROOT%\\brain\\src\\server\.js/);
 assert.match(s,/TESLES_BRAIN_TARGET/);
});

test('installer delegates SCUM stop and start to packaged server scripts',()=>{
 const s=read('installer/Install.ps1');
 assert.match(s,/ScumStop_NoBattlEye\.bat/);
 assert.match(s,/ScumStart_NoBattlEye\.bat/);
});

test('installer validates Node major version rather than any node executable',()=>{
 const s=read('installer/Install.ps1');
 assert.match(s,/Node\.js 18\+/);
 assert.match(s,/node --version|&\s*\$node\.Source\s+--version/);
});

test('installer pins the audited UE4SS build instead of tracking latest',()=>{
 const s=read('installer/Install.ps1');
 assert.match(s,/UE4SS_v3\.0\.1-944-g0196ef29\.zip/);
 assert.doesNotMatch(s,/releases\/latest/i);
});

test('installer patches engine version override using current UE4SS section keys',()=>{
 const s=read('installer/Install.ps1');
 assert.match(s,/EngineVersionOverride/);
 assert.match(s,/MajorVersion['\"]?\s*,?\s*['\"]?4/);
 assert.match(s,/MinorVersion['\"]?\s*,?\s*['\"]?27/);
 assert.doesNotMatch(s,/MajorVersionOverride/);
 assert.doesNotMatch(s,/MinorVersionOverride/);
});

test('installer minimally patches required hooks and keeps EngineTick available for game-thread work',()=>{
 const s=read('installer/Install.ps1');
 assert.match(s,/HookEngineTick/);
 assert.match(s,/["']1["']/);
 assert.match(s,/Set-IniSectionKey/);
});

test('installer preserves runtime state across updates and has transactional rollback',()=>{
 const s=read('installer/Install.ps1');
 assert.match(s,/Restoring persistent runtime\/world data/i);
 assert.match(s,/old-ue-mod/);
 assert.match(s,/Restore-File/);
 assert.match(s,/rollback|Rolling back/i);
});

test('installer never creates enabled.txt and removes stale enabled.txt in its own mod only',()=>{
 const s=read('installer/Install.ps1');
 assert.doesNotMatch(s,/New-Item[^\n]*enabled\.txt/i);
 assert.match(s,/enabled\.txt/);
});

test('installer enables Tesles mod while preserving shared mods lists',()=>{
 const s=read('installer/Install.ps1');
 assert.match(s,/mods\.json/);
 assert.match(s,/mods\.txt/);
 assert.match(s,/Where-Object\s*\{\s*\$_.mod_name -ne \$name\s*\}/);
});

test('uninstaller removes only Tesles entry from UE4SS mod lists and uses packaged SCUM scripts',()=>{
 const s=read('installer/Uninstall.ps1');
 assert.match(s,/TeslesNPCOverhaul/);
 assert.match(s,/mods\.json/);
 assert.match(s,/mods\.txt/);
 assert.match(s,/ScumStop_NoBattlEye\.bat/);
 assert.match(s,/ScumStart_NoBattlEye\.bat/);
});

test('runtime config and installer provide bounded state snapshot IPC',()=>{
 const cfg=read('ue4ss/TeslesNPCOverhaul/scripts/runtime_config.lua.template');
 const ipc=read('ue4ss/TeslesNPCOverhaul/scripts/modules/ipc.lua');
 const install=read('installer/Install.ps1');
 assert.match(cfg,/state_file\s*=\s*\[\[__STATE_FILE__\]\]/);
 assert.match(ipc,/function M\.write_state/);
 assert.match(ipc,/os\.rename\(tmp,state_file\)/);
 assert.match(install,/__STATE_FILE__/);
});

test('movement capability probe proves observed progress to an offset target',()=>{
 const s=read('ue4ss/TeslesNPCOverhaul/scripts/modules/scum_adapter.lua');
 assert.match(s,/loc\.x\+200/);
 assert.match(s,/moved>=20/);
 assert.match(s,/d1<d0/);
 assert.match(s,/MoveTo request produced no observed progress/);
});

test('brain restore probe verifies IsRunning after StartLogic',()=>{
 const s=read('ue4ss/TeslesNPCOverhaul/scripts/modules/scum_adapter.lua');
 assert.match(s,/StartLogic\(\)/);
 assert.match(s,/IsRunning\(\)/);
 assert.match(s,/brain_restore/);
});

test('high-frequency position telemetry uses state snapshots rather than append event log',()=>{
 const s=read('ue4ss/TeslesNPCOverhaul/scripts/modules/scum_adapter.lua');
 const tickSection=s.slice(s.indexOf('function M.tick'));
 assert.match(tickSection,/ipc\.write_state\(records\)/);
 assert.doesNotMatch(tickSection,/ipc\.emit\("NPC_POSITION"/);
});

test('package metadata consistently reports current version',()=>{
 const version=read('VERSION').trim();
 assert.equal(version,'0.1.5-audit24fix');
 const manifest=JSON.parse(read('manifest.json'));
 assert.equal(manifest.version,version);
 const pkg=JSON.parse(read('brain/package.json'));
 assert.equal(pkg.version,version);
 const main=read('ue4ss/TeslesNPCOverhaul/scripts/main.lua');
 assert.match(main,new RegExp('version=\"'+version.replace(/[.*+?^${}()|[\]\\]/g,'\\$&')+'\"'));
});


test('map viewer marks background teleport altitude as approximate instead of silently pretending it is exact',()=>{
 const s=read('web/public/app.js');
 assert.match(s,/approxZ/);
 assert.match(s,/approximate/i);
 assert.match(s,/nearest/i);
});

test('UE4SS utility never falls back to manipulating UObjects directly from an async thread',()=>{
 const s=read('ue4ss/TeslesNPCOverhaul/scripts/modules/util.lua');
 assert.doesNotMatch(s,/ExecuteAsync\(function\(\)\s*fn\(\)/);
 assert.match(s,/game.thread scheduler unavailable/i);
});

test('probe allows enough time to observe movement before restoring vanilla brain',()=>{
 const cfg=read('ue4ss/TeslesNPCOverhaul/scripts/runtime_config.lua.template');
 const lua=read('ue4ss/TeslesNPCOverhaul/scripts/modules/scum_adapter.lua');
 assert.match(cfg,/probe_restore_ms\s*=\s*9000/);
 assert.match(lua,/>7000/);
});

test('package docs and Node metadata do not advertise superseded probe behavior',()=>{
 const pkg=JSON.parse(read('brain/package.json'));
 assert.equal(pkg.version,'0.1.5-audit24fix');
 const readme=read('README.txt');
 assert.match(readme,/0\.1\.5-audit24fix/);
 assert.doesNotMatch(readme,/harmless current-position MoveToLocation probe/i);
});

test('default development paths point to package-level runtime rather than nonexistent brain/runtime',()=>{
 const cfg=JSON.parse(read('brain/config/default.json'));
 for(const key of ['eventsFile','commandsFile','offsetFile','stateFile']) assert.match(cfg.ipc[key],/^\.\.\/\.\.\/runtime\//);
 const server=read('brain/src/server.js');
 assert.match(server,/\.\.'\s*,\s*'\.\.'\s*,\s*'runtime'\s*,\s*'world\.json'/);
});

test('command IPC is a bounded latest-command snapshot and Lua de-duplicates by sequence',()=>{
 const server=read('brain/src/server.js');
 const ipc=read('ue4ss/TeslesNPCOverhaul/scripts/modules/ipc.lua');
 assert.match(server,/class CommandSnapshotWriter/);
 assert.doesNotMatch(server,/appendFileSync\(file,formatCommand/);
 assert.match(ipc,/last_command_seq/);
 assert.doesNotMatch(ipc,/local event_file, command_file, state_file, offset/);
});

test('mods.json writers force JSON arrays even with zero or one enabled mod',()=>{
 const install=read('installer/Install.ps1');
 const uninstall=read('installer/Uninstall.ps1');
 assert.match(install,/ConvertTo-Json\s+-InputObject\s+\$arr/);
 assert.match(uninstall,/ConvertTo-Json\s+-InputObject\s+\$arr/);
});

test('purge uninstall restarts SCUM before scheduling deletion of its own package scripts',()=>{
 const s=read('installer/Uninstall.ps1');
 const restart=s.indexOf("ScumStart_NoBattlEye.bat");
 const purge=s.indexOf('Scheduling Tesles package deletion');
 assert.ok(restart>=0&&purge>restart);
});

test('probe restore has RestartLogic fallback and retries instead of abandoning a stopped brain',()=>{
 const s=read('ue4ss/TeslesNPCOverhaul/scripts/modules/scum_adapter.lua');
 assert.match(s,/RestartLogic\(\)/);
 assert.match(s,/probe_restore_at\s*=\s*util\.now_ms\(\)\+2000/);
 assert.match(s,/probe_npc_id=nil/);
});

test('diagnostics enumerates UE4SS log paths safely and captures bounded state snapshot',()=>{
 const s=read('diagnostics/CollectDiagnostics.ps1');
 assert.match(s,/\$logs=@\(\(Join-Path \$win64 'UE4SS\.log'\),\(Join-Path \$win64 'ue4ss\\UE4SS\.log'\)\)/);
 assert.match(s,/scum-state\.log/);
});

test('package bundles a tiled 14k map pyramid for zoomable high-resolution viewing',()=>{
 const manifest=JSON.parse(read('web/public/map/manifest.json'));
 assert.equal(manifest.tileSize,512);
 assert.equal(manifest.maxZoom,5);
 assert.equal(manifest.imageWidth,14481);
 assert.equal(manifest.imageHeight,14481);
 assert.equal(manifest.levels['5'].cols,29);
 assert.equal(manifest.levels['5'].rows,29);
 assert.ok(fs.existsSync(path.join(root,'web/public/map/tiles/5/28_28.jpg')));
});

test('map viewer exposes zoom controls, drag pan and health detail text',()=>{
 const html=read('web/public/index.html');
 const css=read('web/public/styles.css');
 const js=read('web/public/app.js');
 assert.match(html,/zoomIn/);
 assert.match(html,/zoomOut/);
 assert.match(html,/zoomReset/);
 assert.match(html,/Drag to pan/i);
 assert.match(html,/Wheel to zoom/i);
 assert.match(js,/pointerdown/);
 assert.match(js,/detail/);
 assert.match(css,/mapHud/);
});

test('map viewer picks tile resolution from screen scale and paints overview beneath detailed tiles',()=>{
 const js=read('web/public/app.js');
 assert.match(js,/function selectTileLevel\(/);
 assert.match(js,/fullMapScreenPx/);
 assert.match(js,/drawTileLayer\(levels\[0\],\{placeholder:true,pad:0\}\)/);
 assert.match(js,/drawTileLayer\(best,\{placeholder:false,pad:0\.75\}\)/);
 assert.doesNotMatch(js,/const z=clamp\(Math\.round\(view\.zoom\)/);
});

test('map world X axis matches legacy SCUM coordinate orientation so tile columns are not reversed',()=>{
 const js=read('web/public/app.js');
 assert.match(js,/x:\(view\.centerX-x\)\*ppw\+r\.width\/2/);
 assert.match(js,/x:view\.centerX-\(px-r\.width\/2\)\/ppw/);
 assert.match(js,/view\.centerX\+=dx\/ppw/);
 assert.match(js,/function worldFracX\(x\)\{return \(cfg\.maxX-x\)\/mapWidth\(\)\}/);
});
