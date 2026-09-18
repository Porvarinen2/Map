'use strict';
// End-to-end smoke of the persistent world: bootstrap, virtual life, materialization
// through the bridge protocol, capture back to virtual, and honest health reporting.
const {WorldDirector}=require('../src/director/worldDirector');
const cfg=require('../config/default.json');

function check(condition,message){if(!condition)throw new Error(`smoke failed: ${message}`);}

const d=new WorldDirector({seed:'smoke',map:cfg.map,population:cfg.population,materialization:cfg.materialization,simulation:cfg.simulation});
const bootstrap=d.bootstrapPopulation({map:cfg.map,populationConfig:{...cfg.population,initialNpcCount:24},now:1700000000000});
check(bootstrap.createdNpcIds.length===24,'population bootstrap did not create 24 persistent NPCs');
check(Object.keys(d.world.groups).length>0,'bootstrap produced no squads');
check(Object.values(d.world.groups).every(g=>g.leaderId&&g.members.length<=5),'squad size or leadership invariant broken');

const health=d.healthSnapshot();
check(health.worldPopulation.status==='OK','worldPopulation must be OK after bootstrap');
check(health.physicalVirtualization.status==='PENDING','untested physical virtualization must be PENDING, not DEGRADED');

// Virtual life continues without any bridge.
d.tick(1);
check(d.compactSnapshot().npcs.length===24,'virtual world lost NPCs during a tick');

// The bridge reports what this build can provide, then a player walks in.
for(const level of [1,2,3,4,5]){
  d.ingest({type:'NPC_CLASS_CATALOG',class:`BP_Guard_Lvl_${level}`,family:'GUARD',level,at:Date.now()});
  d.ingest({type:'NPC_CLASS_CATALOG',class:`BP_Drifter_Lvl_${level}`,family:'DRIFTER',level,at:Date.now()});
}
const target=Object.values(d.world.npcs)[0];
target.position={x:0,y:0,z:0};
d.ingest({type:'PLAYER_SEEN',playerId:'smoke-player',x:500,y:0,z:0,at:Date.now()});
d.tick(0.5);
const spawn=d.drainCommands().find(c=>c.type==='SPAWN'&&c.persistentNpcId===target.npcId);
check(Boolean(spawn),'no SPAWN command was produced for an NPC inside 700 m');
check(Boolean(spawn.npcClass),'SPAWN command did not name a verified runtime class');

d.ingest({type:'MATERIALIZED',persistentNpcId:target.npcId,runtimeId:'smoke-actor-1',generation:spawn.generation,x:10,y:0,z:0,body:spawn.npcClass,at:Date.now()});
check(target.materialized===true,'MATERIALIZED did not bind the persistent entity');
check(Object.keys(d.world.npcs).length===24,'materialization created a duplicate entity');

d.world.players={};
d.tick(0.5);
target.dematerializeEligibleAt=Date.now()-1;
d.tick(0.5);
const capture=d.drainCommands().find(c=>c.type==='CAPTURE_AND_DESPAWN');
check(Boolean(capture),'no CAPTURE_AND_DESPAWN was produced after the player left');
d.ingest({type:'DEMATERIALIZED',persistentNpcId:target.npcId,x:4242,y:0,z:0,health:0.9,at:Date.now()});
check(target.materialized===false&&target.position.x===4242,'capture did not return the entity to virtual life');

const zombieDirector=new WorldDirector({seed:'smoke-zombies',map:cfg.map,population:{...cfg.population,adoptUnmanagedNpc:true}});
zombieDirector.ingest({type:'NPC_SEEN',npcId:'smoke-guard-1',body:'BP_Guard_Lvl_4',x:0,y:0,z:25000,at:Date.now()});
zombieDirector.ingest({type:'NPC_SEEN',npcId:'smoke-guard-2',body:'BP_Guard_Lvl_3',x:150,y:0,z:25000,at:Date.now()});
zombieDirector.ingest({type:'ZOMBIE_SEEN',zombieId:'smoke-zombie-1',x:250,y:50,z:25000,at:Date.now()});
zombieDirector.tick(1);
const zs=zombieDirector.snapshot();
check(zs.npcs.length===2,'adopted NPC smoke count failed');
check(zs.groups.length===1,'adopted NPC group smoke count failed');
check(Boolean(zs.groups[0].leaderId),'leadership smoke failed');
check(zs.groups[0].zombiePressure>0,'zombie pressure smoke failed');

console.log(JSON.stringify({
  ok:true,
  persistentNpcs:Object.keys(d.world.npcs).length,
  squads:Object.keys(d.world.groups).length,
  materializedRoundtrip:true,
  health:Object.fromEntries(Object.entries(d.healthSnapshot()).map(([k,v])=>[k,v.status]))
},null,2));
