'use strict';
const test=require('node:test');
const assert=require('node:assert/strict');
const fs=require('fs');
const os=require('os');
const path=require('path');
const {CommandBroker,commandKeyFor}=require('../src/bridge/commandBroker');
const {CommandSnapshotWriter}=require('../src/server');
const {parseEventLine,formatCommand}=require('../src/bridge/protocol');

const root=path.resolve(__dirname,'..','..');
function lua(name){return fs.readFileSync(path.join(root,'ue4ss','TeslesNPCOverhaul','scripts','modules',name),'utf8');}
function tmpFile(prefix){return path.join(fs.mkdtempSync(path.join(os.tmpdir(),prefix)),'commands.log');}

test('spawn commands for different NPCs coexist in one snapshot',()=>{
  const b=new CommandBroker({initialSeq:1});
  b.submit({type:'SPAWN',persistentNpcId:'npc-00001',npcClass:'BP_Guard_Lvl_3',x:1,y:2,z:3});
  b.submit({type:'SPAWN',persistentNpcId:'npc-00002',npcClass:'BP_Guard_Lvl_1',x:4,y:5,z:6});
  const records=b.snapshotRecords();
  assert.equal(records.length,2);
  assert.deepEqual(records.map(r=>r.commandKey),['spawn:npc-00001','spawn:npc-00002']);
  assert.ok(records[0].seq<records[1].seq);
});

test('a repeated request for the same NPC replaces its command instead of duplicating work',()=>{
  const b=new CommandBroker({initialSeq:1});
  b.submit({type:'SPAWN',persistentNpcId:'npc-00001',x:1,y:1,z:1});
  b.submit({type:'SPAWN',persistentNpcId:'npc-00001',x:9,y:9,z:9});
  const records=b.snapshotRecords();
  assert.equal(records.length,1);
  assert.equal(records[0].x,9);
});

test('a stale ACK can never retire a newer command',()=>{
  const b=new CommandBroker({initialSeq:10});
  const first=b.submit({type:'MOVE',npcId:'actor-1',x:1,y:1,z:1});
  const second=b.submit({type:'MOVE',npcId:'actor-1',x:2,y:2,z:2});
  assert.equal(b.ack({seq:first,commandKey:'nav:actor-1'}),false);
  assert.equal(b.snapshotRecords().length,1);
  assert.equal(b.ack({seq:second,commandKey:'nav:actor-1'}),true);
  assert.equal(b.snapshotRecords().length,0);
});

test('STOP supersedes a pending MOVE for the same actor',()=>{
  const b=new CommandBroker({initialSeq:1});
  b.submit({type:'MOVE',npcId:'actor-1',x:1,y:1,z:1});
  b.submit({type:'STOP',npcId:'actor-1'});
  const records=b.snapshotRecords();
  assert.equal(records.length,1);
  assert.equal(records[0].type,'STOP');
});

test('command keys are stable and separate spawn, despawn, navigation and weapon work',()=>{
  assert.equal(commandKeyFor({type:'SPAWN',persistentNpcId:'npc-1'}),'spawn:npc-1');
  assert.equal(commandKeyFor({type:'CAPTURE_AND_DESPAWN',persistentNpcId:'npc-1'}),'despawn:npc-1');
  assert.equal(commandKeyFor({type:'MOVE',npcId:'actor-1'}),'nav:actor-1');
  assert.equal(commandKeyFor({type:'AIM',persistentNpcId:'npc-1'}),'aim:npc-1');
  assert.equal(commandKeyFor({type:'FIRE_START',persistentNpcId:'npc-1'}),'trigger:npc-1');
  assert.equal(commandKeyFor({type:'FIRE_STOP',persistentNpcId:'npc-1'}),'trigger:npc-1');
});

test('spawn and navigation commands survive together in the written snapshot file',()=>{
  const file=tmpFile('tesles-spawn-');
  const w=new CommandSnapshotWriter(file,{initialSeq:100});
  w.submit({type:'SPAWN',persistentNpcId:'npc-00001',npcClass:'BP_Guard_Lvl_3',x:1,y:2,z:3,generation:1});
  w.submit({type:'MOVE',npcId:'actor-9',x:5,y:6,z:7});
  const lines=fs.readFileSync(file,'utf8').trim().split(/\r?\n/);
  assert.equal(lines.length,2);
  const spawn=parseEventLine(lines.find(l=>l.includes('SPAWN')));
  assert.equal(spawn.type,'SPAWN');
  assert.equal(spawn.persistentNpcId,'npc-00001');
  assert.equal(spawn.npcClass,'BP_Guard_Lvl_3');
  assert.equal(spawn.commandKey,'spawn:npc-00001');
});

test('pruning by entity id keeps live work and drops finished work',()=>{
  const file=tmpFile('tesles-prune-');
  const w=new CommandSnapshotWriter(file,{initialSeq:1});
  w.submit({type:'SPAWN',persistentNpcId:'npc-live',x:0,y:0,z:0});
  w.submit({type:'SPAWN',persistentNpcId:'npc-done',x:0,y:0,z:0});
  w.prune(['npc-live']);
  const text=fs.readFileSync(file,'utf8');
  assert.match(text,/npc-live/);
  assert.doesNotMatch(text,/npc-done/);
});

test('command formatting round-trips every spawn field the bridge needs',()=>{
  const line=formatCommand({seq:42,type:'SPAWN',commandKey:'spawn:npc-1',persistentNpcId:'npc-1',npcClass:'BP_Guard_Lvl_3',x:-1234.5,y:99,z:0,generation:3});
  const parsed=parseEventLine(line);
  assert.equal(parsed.type,'SPAWN');
  assert.equal(parsed.x,-1234.5);
  assert.equal(parsed.generation,3);
});

test('the UE4SS bridge ships a spawn adapter with an idempotent persistent id map',()=>{
  const s=lua('spawn_adapter.lua');
  assert.match(s,/actor_by_persistent_id/);
  assert.match(s,/function M\.spawn/);
  assert.match(s,/function M\.capture_and_despawn/);
  assert.match(s,/TESLES_ID:/);
  assert.match(s,/MATERIALIZED/);
  assert.match(s,/MATERIALIZE_FAILED/);
  assert.match(s,/DEMATERIALIZED/);
  assert.match(s,/CAPTURE_FAILED/);
});

test('capture reads physical state before the actor is ever destroyed',()=>{
  const s=lua('spawn_adapter.lua');
  const capture=s.slice(s.indexOf('function M.capture_and_despawn'));
  const readIndex=capture.indexOf('safe_location');
  const healthIndex=capture.indexOf('health_reader');
  const fieldsIndex=capture.indexOf('local fields');
  const destroyIndex=capture.indexOf('M.destroy_actor');
  assert.ok(readIndex>=0&&healthIndex>=0&&fieldsIndex>=0&&destroyIndex>=0);
  assert.ok(readIndex<destroyIndex,'final position must be captured before the actor is destroyed');
  assert.ok(healthIndex<destroyIndex,'health must be captured before the actor is destroyed');
  assert.ok(fieldsIndex<destroyIndex,'the captured snapshot must exist before destruction');
  // A failed read must return before destruction is even attempted.
  assert.ok(capture.indexOf('position unreadable')<destroyIndex);
  assert.match(s,/function M\.destroy_actor[\s\S]*K2_DestroyActor/);
  assert.match(capture,/CAPTURE_FAILED/);
  assert.match(capture,/capture failed/i);
});

test('the spawn adapter proves its primitive with repeated spawn and destroy cycles',()=>{
  const s=lua('spawn_adapter.lua');
  assert.match(s,/probe_cycles/);
  assert.match(s,/spawn_actor/);
  assert.match(s,/destroy_actor/);
  assert.match(s,/tesles_identity_tag/);
  assert.match(s,/npc_class_catalog/);
});

test('the Lua command reader de-duplicates per command key rather than one global sequence',()=>{
  const s=fs.readFileSync(path.join(root,'ue4ss','TeslesNPCOverhaul','scripts','modules','ipc.lua'),'utf8');
  assert.match(s,/last_seq_by_key/);
  assert.doesNotMatch(s,/if seq>last_command_seq then/);
});

test('command results echo the command key so acknowledgements cannot cross commands',()=>{
  const adapter=lua('scum_adapter.lua');
  assert.match(adapter,/commandKey=/);
});
