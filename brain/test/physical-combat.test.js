'use strict';
const test=require('node:test');
const assert=require('node:assert/strict');
const fs=require('fs');
const path=require('path');
const {buildWeaponCommands,releaseTrigger}=require('../src/combat/physicalCombat');
const {WorldDirector}=require('../src/director/worldDirector');
const cfg=require('../config/default.json');

const root=path.resolve(__dirname,'..','..');
function shooter(overrides={}){
  return {npcId:'npc-00001',runtimeId:'actor-1',alive:true,materialized:true,desiredAccuracyMultiplier:0.8,...overrides};
}
const PROVEN={weapon_use:{ok:true,detail:'proven'}};

test('no weapon command is produced before the weapon primitive is proven',()=>{
  const n=shooter();
  const out=buildWeaponCommands(n,{action:'ATTACK',target:{x:10,y:0,z:0},capabilities:{}});
  assert.deepEqual(out.commands,[]);
  assert.equal(out.blockedReason,'WEAPON_CAPABILITY_UNPROVEN');
  const failed=buildWeaponCommands(n,{action:'ATTACK',target:{x:10,y:0,z:0},capabilities:{weapon_use:{ok:false}}});
  assert.deepEqual(failed.commands,[]);
});

test('an attacking NPC aims and pulls the trigger exactly once',()=>{
  const n=shooter();
  const first=buildWeaponCommands(n,{action:'ATTACK',target:{x:10,y:20,z:30},capabilities:PROVEN,now:1000});
  assert.deepEqual(first.commands.map(c=>c.type),['AIM','FIRE_START']);
  assert.equal(first.commands[0].x,10);
  assert.equal(first.commands[0].accuracyMultiplier,0.8,'stress accuracy must reach the weapon adapter');
  const second=buildWeaponCommands(n,{action:'ATTACK',target:{x:11,y:20,z:30},capabilities:PROVEN,now:1100});
  assert.deepEqual(second.commands.map(c=>c.type),['AIM'],'the trigger is not re-pulled every tick');
});

test('suppression is aiming fire, and leaving combat releases the trigger',()=>{
  const n=shooter();
  const suppress=buildWeaponCommands(n,{action:'SUPPRESS',target:{x:5,y:5,z:0},capabilities:PROVEN,now:1000});
  assert.equal(suppress.commands[0].suppress,'true');
  const stop=buildWeaponCommands(n,{action:'RETREAT',capabilities:PROVEN,now:1200});
  assert.deepEqual(stop.commands.map(c=>c.type),['FIRE_STOP']);
  assert.equal(n.combatIntent.firing,false);
  assert.deepEqual(buildWeaponCommands(n,{action:'RETREAT',capabilities:PROVEN,now:1300}).commands,[]);
});

test('a firing NPC releases the trigger when the capability is lost mid-fight',()=>{
  const n=shooter();
  buildWeaponCommands(n,{action:'ATTACK',target:{x:5,y:0,z:0},capabilities:PROVEN,now:1000});
  const lost=buildWeaponCommands(n,{action:'ATTACK',target:{x:5,y:0,z:0},capabilities:{weapon_use:{ok:false}},now:1100});
  assert.deepEqual(lost.commands.map(c=>c.type),['FIRE_STOP']);
});

test('a virtual or dead NPC never receives weapon commands',()=>{
  assert.deepEqual(buildWeaponCommands(shooter({materialized:false}),{action:'ATTACK',target:{x:1,y:1,z:1},capabilities:PROVEN}).commands,[]);
  assert.deepEqual(buildWeaponCommands(shooter({alive:false}),{action:'ATTACK',target:{x:1,y:1,z:1},capabilities:PROVEN}).commands,[]);
  assert.equal(releaseTrigger(shooter()),null);
});

test('physical combat health is PENDING until a real weapon attempt happens',()=>{
  const d=new WorldDirector({seed:'combat',map:cfg.map,population:cfg.population});
  assert.equal(d.healthSnapshot().physicalCombat.status,'PENDING');
  d.ingest({type:'CAPABILITY',name:'weapon_use',ok:false,detail:'no fire primitive accepted the request',at:1});
  assert.equal(d.healthSnapshot().physicalCombat.status,'DEGRADED');
  assert.match(d.healthSnapshot().physicalCombat.detail,/no fire primitive/);
  d.ingest({type:'CAPABILITY',name:'weapon_use',ok:true,detail:'fire start accepted',at:2});
  assert.equal(d.healthSnapshot().physicalCombat.status,'OK');
});

test('the weapon adapter owns every build-specific call and the brain names none',()=>{
  const lua=fs.readFileSync(path.join(root,'ue4ss','TeslesNPCOverhaul','scripts','modules','weapon_adapter.lua'),'utf8');
  assert.match(lua,/FIRE_START/);
  assert.match(lua,/FIRE_STOP/);
  assert.match(lua,/RELOAD/);
  assert.match(lua,/function M\.release/);
  assert.match(lua,/probe\.cap\("weapon_use"/);
  const node=fs.readFileSync(path.join(root,'brain','src','combat','physicalCombat.js'),'utf8');
  for(const scumName of ['StartFire','StopFire','SetFocalPoint','CurrentWeapon','MoveToLocation'])
    assert.doesNotMatch(node,new RegExp(scumName),`Node must not name the SCUM function ${scumName}`);
});

test('an actor is never captured or destroyed while still firing',()=>{
  const adapter=fs.readFileSync(path.join(root,'ue4ss','TeslesNPCOverhaul','scripts','modules','scum_adapter.lua'),'utf8');
  const capture=adapter.slice(adapter.indexOf('elseif cmd.type=="CAPTURE_AND_DESPAWN"'));
  const release=capture.indexOf('weapon_adapter.release');
  const despawn=capture.indexOf('spawn_adapter.capture_and_despawn');
  assert.ok(release>=0&&despawn>release,'the trigger must be released before capture');
  const force=adapter.slice(adapter.indexOf('elseif cmd.type=="FORCE_DESTROY"'));
  assert.ok(force.indexOf('weapon_adapter.release')<force.indexOf('spawn_adapter.force_destroy'));
});
