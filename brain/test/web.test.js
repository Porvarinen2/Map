const test=require('node:test'); const assert=require('node:assert/strict');
const {buildTeleportCommand,createHttpServer}=require('../src/server');
const {WorldDirector}=require('../src/director/worldDirector');
const {legacyDirector}=require('./helpers/legacyDirector');

test('teleport command uses exact coordinates and optional player last',()=>{
 assert.equal(buildTeleportCommand({x:1.25,y:-2,z:300}), '#Teleport 1.25 -2 300');
 assert.equal(buildTeleportCommand({x:1,y:2,z:3},'Player Name'), '#Teleport 1 2 3 Player Name');
});

test('HTTP API serves snapshot and health', async()=>{
 const d=legacyDirector({seed:'web'}); d.ingest({type:'NPC_SEEN',npcId:'n1',body:'BP_Guard_Lvl_1',x:1,y:2,z:3,at:1});
 const server=createHttpServer({director:d,publicDir:null,mapConfig:{minX:-750000,maxX:750000,minY:-750000,maxY:750000,defaultZ:30000}});
 await new Promise(r=>server.listen(0,'127.0.0.1',r)); const port=server.address().port;
 const res=await fetch(`http://127.0.0.1:${port}/api/snapshot`); assert.equal(res.status,200); const body=await res.json(); assert.equal(body.npcs.length,1); assert.equal(body.npcs[0].npcId,'n1');
 const h=await fetch(`http://127.0.0.1:${port}/api/health`); assert.equal((await h.json()).brain.status,'OK');
 await new Promise(r=>server.close(r));
});

test('HTTP teleport endpoint rejects non-finite coordinates', async()=>{
 const d=legacyDirector({seed:'web-invalid'});
 const server=createHttpServer({director:d,publicDir:null,mapConfig:{defaultZ:30000}});
 await new Promise(r=>server.listen(0,'127.0.0.1',r)); const port=server.address().port;
 const res=await fetch(`http://127.0.0.1:${port}/api/teleport?x=wat&y=2&z=3`);
 assert.equal(res.status,400);
 await new Promise(r=>server.close(r));
});

test('HTTP teleport endpoint requires explicit Z instead of silently inventing altitude', async()=>{
 const d=legacyDirector({seed:'web-no-z'});
 const server=createHttpServer({director:d,publicDir:null,mapConfig:{defaultZ:30000}});
 await new Promise(r=>server.listen(0,'127.0.0.1',r)); const port=server.address().port;
 const res=await fetch(`http://127.0.0.1:${port}/api/teleport?x=1&y=2`);
 assert.equal(res.status,400);
 const body=await res.json(); assert.match(body.error,/z is required/i);
 await new Promise(r=>server.close(r));
});

test('HTTP teleport endpoint returns exact explicit coordinates', async()=>{
 const d=legacyDirector({seed:'web-z'});
 const server=createHttpServer({director:d,publicDir:null,mapConfig:{defaultZ:30000}});
 await new Promise(r=>server.listen(0,'127.0.0.1',r)); const port=server.address().port;
 const res=await fetch(`http://127.0.0.1:${port}/api/teleport?x=123&y=-456&z=789`);
 assert.equal(res.status,200);
 assert.equal((await res.json()).command,'#Teleport 123 -456 789');
 await new Promise(r=>server.close(r));
});


test('HTTP map-config exposes bundled tile pyramid metadata', async()=>{
 const d=legacyDirector({seed:'web-mapcfg'});
 const mapConfig={minX:-750000,maxX:750000,minY:-750000,maxY:750000,defaultZ:30000,tiles:{enabled:true,tileSize:512,maxZoom:5,imageWidth:14481,imageHeight:14481,pathTemplate:'map/tiles/{z}/{x}_{y}.jpg',levels:{5:{cols:29,rows:29}}}};
 const server=createHttpServer({director:d,publicDir:null,mapConfig});
 await new Promise(r=>server.listen(0,'127.0.0.1',r)); const port=server.address().port;
 const res=await fetch(`http://127.0.0.1:${port}/api/map-config`);
 assert.equal(res.status,200);
 const body=await res.json();
 assert.equal(body.tiles.enabled,true);
 assert.equal(body.tiles.tileSize,512);
 assert.equal(body.tiles.levels['5'].cols,29);
 await new Promise(r=>server.close(r));
});
