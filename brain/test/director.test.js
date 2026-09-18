const test=require('node:test'); const assert=require('node:assert/strict'); const fs=require('fs'); const os=require('os'); const path=require('path');
const {saveWorld,loadWorld}=require('../src/persistence/worldStore');
const {parseEventLine,formatCommand}=require('../src/bridge/protocol');
const {WorldDirector}=require('../src/director/worldDirector');
const {legacyDirector}=require('./helpers/legacyDirector');

test('world save/load is atomic and round-trips',()=>{
 const dir=fs.mkdtempSync(path.join(os.tmpdir(),'tesles-')); const file=path.join(dir,'world.json');
 const world={version:1,npcs:{a:{npcId:'a',alive:true,position:{x:1,y:2,z:3}}},groups:{}};
 saveWorld(file,world);
 const loaded=loadWorld(file);
 assert.equal(loaded.version,6);
 assert.equal(loaded.npcs.a.npcId,'a');
 assert.deepEqual(loaded.npcs.a.position,{x:1,y:2,z:3});
 assert.equal(loaded.npcs.a.runtimeId,null);
 assert.equal(loaded.npcs.a.materialized,false);
 assert.equal(fs.existsSync(file+'.tmp'),false);
});

test('line IPC event and command protocol preserves coordinates and ids',()=>{
 const e=parseEventLine('1000|NPC_SEEN|npcId=n1|body=BP_Guard_Lvl_1|x=12.5|y=-9|z=300'); assert.equal(e.type,'NPC_SEEN'); assert.equal(e.npcId,'n1'); assert.equal(e.x,12.5); assert.equal(e.y,-9);
 const c=formatCommand({seq:7,type:'MOVE',npcId:'n1',x:1,y:2,z:3}); assert.match(c,/^7\|MOVE\|npcId=n1\|x=1\|y=2\|z=3/);
});

test('director creates persistent entity from observed SCUM NPC and updates position',()=>{
 const d=legacyDirector({seed:'world'}); d.ingest({type:'NPC_SEEN',npcId:'actor-1',body:'BP_Guard_Lvl_1',x:10,y:20,z:30,at:1}); assert.ok(d.world.npcs['actor-1']); d.ingest({type:'NPC_POSITION',npcId:'actor-1',x:50,y:60,z:70,at:2}); assert.equal(d.world.npcs['actor-1'].position.x,50);
});

test('director health registry exposes degraded SCUM adapter without crashing simulation',()=>{
 const d=legacyDirector({seed:'world'}); d.ingest({type:'CAPABILITY',name:'brain_stop',ok:false,detail:'not found'}); const h=d.healthSnapshot(); assert.equal(h.scumAdapter.status,'DEGRADED'); d.tick(1); assert.ok(d.world.time>=1);
});

test('position event proves actor is materialized and distance LOD does not fake despawn',()=>{
 const d=legacyDirector({seed:'lod'});
 d.ingest({type:'NPC_SEEN',npcId:'npc-lod',body:'BP_Guard_Lvl_1',x:0,y:0,z:0,at:Date.now()});
 d.ingest({type:'PLAYER_SEEN',playerId:'p1',x:100000,y:0,z:0,at:Date.now()});
 d.tick(.5);
 assert.equal(d.world.npcs['npc-lod'].materialized,true);
 assert.equal(d.world.npcs['npc-lod'].desiredSimulationLod,'VIRTUAL');
 d.ingest({type:'NPC_POSITION',npcId:'npc-lod',x:20,y:0,z:0,at:Date.now()});
 assert.equal(d.world.npcs['npc-lod'].materialized,true);
});

test('stale players and zombies are pruned from live world state',()=>{
 const d=legacyDirector({seed:'prune'});
 const old=Date.now()-120000;
 d.world.players.old={id:'old',position:{x:0,y:0,z:0},lastSeenAt:old};
 d.world.zombies.old={id:'old',position:{x:0,y:0,z:0},lastSeenAt:old};
 d.tick(.5);
 assert.equal(d.world.players.old,undefined);
 assert.equal(d.world.zombies.old,undefined);
});

test('physical NPC receives STOP intent when its previous movement no longer has a target',()=>{
 const d=legacyDirector({seed:'stop-intent',featureFlags:{takeoverRequested:true,takeoverMode:'full'}});
 d.ingest({type:'NPC_SEEN',npcId:'n1',body:'BP_Guard_Lvl_1',x:0,y:0,z:0,at:Date.now()});
 const n=d.world.npcs.n1;
 n.navigation={movementCommanded:true};
 n.destination=null;
 d._aiEval();
 assert.equal(n.aiIntent?.type,'STOP');
 assert.equal(n.aiIntent?.npcId,'n1');
 assert.equal(n.navigation.movementCommanded,false);
});
