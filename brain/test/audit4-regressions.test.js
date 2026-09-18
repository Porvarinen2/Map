const test=require('node:test');
const assert=require('node:assert/strict');
const fs=require('fs');
const os=require('os');
const path=require('path');
const {WorldDirector}=require('../src/director/worldDirector');
const {createNpc}=require('../src/core/entityFactory');
const {createGroup}=require('../src/groups/classes');
const {selectLeader,onLeaderDeath}=require('../src/groups/leadership');
const {loadConfig}=require('../src/server');
function npc(id,archetype='survivor',tier=2,pos={x:0,y:0,z:0}){return createNpc({npcId:id,seed:'audit4',archetype,skillTier:tier,position:pos});}

test('leaderless succession delay is not bypassed by refreshGroup during world tick',()=>{const d=new WorldDirector({population:{roamEnabled:false}});const a=npc('a','ex_military',4),b=npc('b','ex_military',4),c=npc('c','ex_military',4);const g=createGroup({groupId:'g',classId:'ex_military',level:4,members:[a,b,c]});d.world.npcs={a,b,c};d.world.groups={g};selectLeader(g);const old=g.leaderId;onLeaderDeath(g,old,{at:Date.now()});d.tick(.5);assert.equal(g.status,'LEADERLESS');assert.equal(g.leaderId,null);g.successionAt=Date.now()-1;d.tick(.5);assert.ok(g.leaderId&&g.leaderId!==old);});

test('NPC ignored at population cap can be admitted later from position snapshots when a slot frees',()=>{const d=new WorldDirector({population:{maxNpc:1,hardMaxNpc:10,roamEnabled:false}});d.ingest({type:'NPC_SEEN',npcId:'r1',stableKey:'s1',body:'BP_Guard_Lvl_1',x:0,y:0,z:0});d.ingest({type:'NPC_SEEN',npcId:'r2',stableKey:'s2',body:'BP_Guard_Lvl_2',x:1000,y:0,z:0});d.ingest({type:'NPC_DEATH',npcId:'r1',at:Date.now()});d.ingest({type:'NPC_POSITION',npcId:'r2',x:1100,y:0,z:0,at:Date.now()});const alive=Object.values(d.world.npcs).filter(n=>n.alive);assert.equal(alive.length,1);assert.equal(alive[0].runtimeId,'r2');assert.equal(alive[0].bodyProfile,'BP_Guard_Lvl_2');});

test('virtual retreat task clears after living group reaches destination',()=>{const d=new WorldDirector({population:{roamEnabled:false}});const a=npc('a'),b=npc('b','survivor',2,{x:10,y:0,z:0});const g=createGroup({groupId:'g',classId:'duo',level:2,members:[a,b]});d.world.npcs={a,b};d.world.groups={g};g.currentTask='retreat_group';g.destination={x:1000,y:0,z:0};a.destination={...g.destination};b.destination={...g.destination};a.position={...g.destination};b.position={...g.destination};d.tick(.5);assert.equal(g.currentTask,'idle');assert.equal(g.destination,null);assert.equal(a.destination,null);assert.equal(b.destination,null);});

test('user config overrides nested defaults without deleting sibling fields',()=>{const dir=fs.mkdtempSync(path.join(os.tmpdir(),'tesles-config-'));const base=path.join(dir,'installed.json'),user=path.join(dir,'user.json');fs.writeFileSync(base,JSON.stringify({server:{host:'127.0.0.1',port:17381},world:{seed:'x',tickMs:500},ipc:{eventsFile:'e',commandsFile:'c',offsetFile:'o',stateFile:'s'},population:{maxNpc:100,hardMaxNpc:250,roamEnabled:true},features:{takeoverMode:'probe',takeoverRequested:true}}));fs.writeFileSync(user,JSON.stringify({population:{maxNpc:80},features:{takeoverMode:'full'}}));const oldCfg=process.env.TESLES_NPC_CONFIG,oldUser=process.env.TESLES_NPC_USER_CONFIG;process.env.TESLES_NPC_CONFIG=base;process.env.TESLES_NPC_USER_CONFIG=user;try{const cfg=loadConfig();assert.equal(cfg.population.maxNpc,80);assert.equal(cfg.population.hardMaxNpc,250);assert.equal(cfg.population.roamEnabled,true);assert.equal(cfg.features.takeoverMode,'full');assert.equal(cfg.features.takeoverRequested,true);}finally{if(oldCfg===undefined)delete process.env.TESLES_NPC_CONFIG;else process.env.TESLES_NPC_CONFIG=oldCfg;if(oldUser===undefined)delete process.env.TESLES_NPC_USER_CONFIG;else process.env.TESLES_NPC_USER_CONFIG=oldUser;}});

test('runtime config takeover mode comes from effective config rather than hard-coded',()=>{const root=path.resolve(__dirname,'..','..');const tpl=fs.readFileSync(path.join(root,'ue4ss','TeslesNPCOverhaul','scripts','runtime_config.lua.template'),'utf8');const install=fs.readFileSync(path.join(root,'installer','Install.ps1'),'utf8');assert.match(tpl,/takeover_mode = "__TAKEOVER_MODE__"/);assert.match(install,/__TAKEOVER_MODE__/);assert.match(install,/features\.takeoverMode/);});

test('SCUM start and stop scripts honor installer server-root environment',()=>{const root=path.resolve(__dirname,'..','..');for(const rel of ['server/ScumStart_NoBattlEye.ps1','server/ScumStop_NoBattlEye.ps1'])assert.match(fs.readFileSync(path.join(root,rel),'utf8'),/TESLES_SCUM_SERVER_ROOT/);});

test('stable identity fallback does not generate collision-prone spawn-cell keys',()=>{const root=path.resolve(__dirname,'..','..');const lua=fs.readFileSync(path.join(root,'ue4ss','TeslesNPCOverhaul','scripts','modules','scum_adapter.lua'),'utf8');assert.doesNotMatch(lua,/2\.5m spawn-cell heuristic/);assert.doesNotMatch(lua,/\|spawn\|/);});

test('movement probe has separate reachable timeout paths for valid and missing actor',()=>{const root=path.resolve(__dirname,'..','..');const lua=fs.readFileSync(path.join(root,'ue4ss','TeslesNPCOverhaul','scripts','modules','scum_adapter.lua'),'utf8');assert.equal((lua.match(/elapsed>7000/g)||[]).length,2);assert.match(lua,/Probe actor\/location became unavailable/);});

test('auto mode is explicit safe probe instead of unreachable weapon_verified flag',()=>{const root=path.resolve(__dirname,'..','..');const lua=fs.readFileSync(path.join(root,'ue4ss','TeslesNPCOverhaul','scripts','modules','scum_adapter.lua'),'utf8');assert.doesNotMatch(lua,/weapon_verified/);assert.match(lua,/auto mode remains safe-probe/);});
