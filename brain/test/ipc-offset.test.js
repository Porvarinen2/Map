const test=require('node:test'); const assert=require('node:assert/strict'); const fs=require('fs'); const os=require('os'); const path=require('path');
const {FileIpcReader}=require('../src/server');

test('file IPC offset survives brain restart and does not replay old events',()=>{
 const dir=fs.mkdtempSync(path.join(os.tmpdir(),'tesles-ipc-'));
 const events=path.join(dir,'events.log'), offset=path.join(dir,'offset.json');
 fs.writeFileSync(events,'1|GUNSHOT|x=1|y=2|z=3\n');
 const first=[]; new FileIpcReader(events,offset).poll(e=>first.push(e)); assert.equal(first.length,1);
 fs.appendFileSync(events,'2|GUNSHOT|x=4|y=5|z=6\n');
 const second=[]; new FileIpcReader(events,offset).poll(e=>second.push(e));
 assert.equal(second.length,1); assert.equal(second[0].x,4);
});

test('command snapshot writer keeps only latest command per NPC and does not grow append-only',()=>{
 const {CommandSnapshotWriter}=require('../src/server');
 const dir=fs.mkdtempSync(path.join(os.tmpdir(),'tesles-cmd-')); const file=path.join(dir,'commands.log');
 const w=new CommandSnapshotWriter(file,{initialSeq:100});
 w.submit({type:'MOVE',npcId:'a',x:1,y:2,z:3});
 w.submit({type:'MOVE',npcId:'a',x:4,y:5,z:6});
 w.submit({type:'STOP',npcId:'b'});
 const lines=fs.readFileSync(file,'utf8').trim().split(/\r?\n/);
 assert.equal(lines.length,2);
 assert.match(lines.find(x=>x.includes('npcId=a')),/x=4/);
 assert.match(lines.find(x=>x.includes('npcId=b')),/STOP/);
 assert.equal(fs.existsSync(file+'.tmp'),false);
});

test('command snapshot writer can forget stale NPC commands',()=>{
 const {CommandSnapshotWriter}=require('../src/server');
 const dir=fs.mkdtempSync(path.join(os.tmpdir(),'tesles-cmd-remove-')); const file=path.join(dir,'commands.log');
 const w=new CommandSnapshotWriter(file,{initialSeq:10});
 w.submit({type:'MOVE',npcId:'gone',x:1,y:2,z:3});
 w.remove('gone');
 assert.equal(fs.readFileSync(file,'utf8'),'');
});
