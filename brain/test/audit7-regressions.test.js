const test=require('node:test');
const assert=require('node:assert/strict');
const fs=require('fs');
const os=require('os');
const path=require('path');
const {parseEventLine}=require('../src/bridge/protocol');
const {WorldDirector}=require('../src/director/worldDirector');
const {FileIpcReader}=require('../src/server');

const root=path.resolve(__dirname,'..','..');
function read(rel){return fs.readFileSync(path.join(root,rel),'utf8');}

test('malformed percent encoding in IPC payload cannot crash event parsing',()=>{
  assert.doesNotThrow(()=>parseEventLine('1|CAPABILITY|name=movement|detail=bad%ZZvalue'));
  const e=parseEventLine('1|CAPABILITY|name=movement|detail=bad%ZZvalue');
  assert.equal(e.type,'CAPABILITY');
  assert.equal(e.detail,'bad%ZZvalue');
});

test('invalid NPC damage payload cannot poison persistent health with NaN',()=>{
  const d=new WorldDirector({featureFlags:{groups:false}});
  d.ingest({type:'NPC_SEEN',npcId:'runtime-1',body:'BP_Drifter_Lvl_1',x:0,y:0,z:0,at:1});
  const n=d.world.npcs['runtime-1'];
  const before=n.health;
  d.ingest({type:'NPC_DAMAGE',npcId:'runtime-1',damageFraction:'nope',healthNormalized:'also-nope',at:2});
  assert.equal(n.health,before);
  assert.equal(n.injuries.length,0);
  assert.ok(Number.isFinite(n.health));
});


test('relative SCUM damage fractions compose multiplicatively without cumulative over-damage drift',()=>{
  const d=new WorldDirector({featureFlags:{groups:false}});
  d.ingest({type:'NPC_SEEN',npcId:'runtime-hp',body:'BP_Drifter_Lvl_1',x:0,y:0,z:0,at:1});
  const n=d.world.npcs['runtime-hp'];
  d.ingest({type:'NPC_DAMAGE',npcId:'runtime-hp',damageFraction:0.10,at:2}); // 100 -> 90
  d.ingest({type:'NPC_DAMAGE',npcId:'runtime-hp',damageFraction:1/9,at:3});  // 90 -> 80
  assert.ok(Math.abs(n.health-0.8)<1e-9,`expected 0.8, got ${n.health}`);
});
test('failed STOP result re-arms a bounded stop retry instead of forgetting a still-moving NPC',()=>{
  const d=new WorldDirector({featureFlags:{groups:false}});
  d.ingest({type:'NPC_SEEN',npcId:'runtime-1',body:'BP_Drifter_Lvl_1',x:0,y:0,z:0,at:1});
  const n=d.world.npcs['runtime-1'];
  n.navigation={movementCommanded:false,lastTarget:null};
  d.ingest({type:'COMMAND_RESULT',commandType:'STOP',npcId:'runtime-1',ok:false,detail:'StopMovement failed',at:1000,seq:9});
  assert.equal(n.navigation.movementCommanded,true);
  assert.equal(n.navigation.stopRetryAfter,2000);
  assert.equal(n.navigation.lastCommandFailure.commandType,'STOP');
});

test('event log rotation drains unread tail from .1 before reading the new current file',()=>{
  const dir=fs.mkdtempSync(path.join(os.tmpdir(),'tesles-ipc-'));
  const file=path.join(dir,'events.log');
  const offsetFile=path.join(dir,'offset.json');
  const first='100|CAPABILITY|name=first|ok=true\n';
  const second='200|CAPABILITY|name=second|ok=true\n';
  fs.writeFileSync(file,first+second);
  fs.writeFileSync(offsetFile,JSON.stringify({version:1,file:path.resolve(file),offset:Buffer.byteLength(first)}));
  const reader=new FileIpcReader(file,offsetFile);
  fs.renameSync(file,file+'.1');
  fs.writeFileSync(file,'300|CAPABILITY|name=third|ok=true\n');
  const names=[];
  reader.poll(e=>names.push(e.name));
  assert.deepEqual(names,['second','third']);
});

test('full-mode UE4SS command handling refuses MOVE when that actor brain was not taken over',()=>{
  const lua=read('ue4ss/TeslesNPCOverhaul/scripts/modules/scum_adapter.lua');
  const start=lua.indexOf('function M.handle_command');
  const end=lua.indexOf('function M.configure',start);
  const block=lua.slice(start,end);
  assert.match(block,/taken_over/);
  assert.match(block,/brain not taken over|not taken over/i);
});

test('installer health check honors effective configured map port instead of hard-coding 17381',()=>{
  const ps=read('installer/Install.ps1');
  assert.match(ps,/server\.port/i);
  assert.match(ps,/Get-BrainEndpoint|brainEndpoint|healthUri/i);
});

test('installer preserves shared UE4SS edits made after a previous install as the new uninstall baseline',()=>{
  const ps=read('installer/Install.ps1');
  assert.match(ps,/patched\.sha256/i);
  assert.match(ps,/changed since last install|new uninstall baseline|refresh.*baseline/i);
  assert.match(ps,/Copy-Item[^\n]*\$settings[^\n]*\$origSettings/i);
});

test('SCUM process verification keeps exact-path fallback while new launches bind to the trusted PID handshake',()=>{
  const ps=read('installer/Install.ps1');
  const testStart=ps.indexOf('function Test-ScumRunning');
  const startStart=ps.indexOf('function Start-Scum');
  const testBlock=ps.slice(testStart,startStart);
  const startBlock=ps.slice(startStart,ps.indexOf('function Test-BrainProcess',startStart));
  assert.match(testBlock,/ExecutablePath/);
  assert.match(startBlock,/Get-ScumPidFile/);
  assert.match(startBlock,/Get-Process\s+-Id\s+\$managedPid/i);
  assert.doesNotMatch(startBlock,/Get-Process\s+-Name\s+['"]?SCUMServer['"]?/i);
});

test('brain stop script targets only its own exact server.js path',()=>{
  const bat=read('server/StopTeslesNPCBrain.bat');
  assert.match(bat,/MOD_ROOT/);
  assert.match(bat,/server\.js/);
  assert.match(bat,/target/i);
  assert.doesNotMatch(bat,/\$needle='TeslesNPCOverhaul\\brain\\src\\server\.js'/);
});


test('fresh bridge session is announced before adapter configuration emits fresh capabilities',()=>{
  const main=read('ue4ss/TeslesNPCOverhaul/scripts/main.lua');
  const started=main.indexOf('ipc.emit("BRIDGE_STARTED"');
  const configured=main.indexOf('adapter.configure');
  assert.ok(started>=0&&configured>=0&&started<configured,'BRIDGE_STARTED must precede adapter.configure capability emissions');
});

test('brain reclaim watchdog verifies StopLogic outcome and fail-closes takeover on unsuppressed reclaim',()=>{
  const lua=read('ue4ss/TeslesNPCOverhaul/scripts/modules/scum_adapter.lua');
  const tick=lua.slice(lua.indexOf('function M.tick'),lua.indexOf('local function move',lua.indexOf('function M.tick')));
  assert.match(tick,/stop_brain\(rec,"Tesles takeover watchdog"\)/);
  assert.match(tick,/full_takeover_ready/);
  assert.match(tick,/brain_stop/);
});

test('diagnostics resolves the configured brain endpoint instead of assuming default port 17381',()=>{
  const ps=read('diagnostics/CollectDiagnostics.ps1');
  assert.match(ps,/installed\.json/);
  assert.match(ps,/user\.json/);
  assert.match(ps,/server\.port/i);
});
test('uninstaller tolerates malformed optional mods.json and still uses mods.txt as authoritative fallback',()=>{
  const ps=read('installer/Uninstall.ps1');
  const start=ps.indexOf('function Disable-UE4SSMod');
  const end=ps.indexOf('$ServerRoot=',start);
  const block=ps.slice(start,end);
  assert.match(block,/try\s*\{/);
  assert.match(block,/mods\.txt remains authoritative|mods\.json.*could not/i);
});
