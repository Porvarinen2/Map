'use strict';
// Idempotent command broker for the file-snapshot bridge.
//
// The commands file is a *latest intent per key* snapshot, not a log. Each logical
// target gets its own key, so a SPAWN for one NPC can never evict a MOVE for
// another. Every record carries a monotonic seq; an ACK only retires the record it
// was issued for, so a late ACK from a previous command can never delete newer work.
// MOVE and STOP deliberately share one navigation key: a STOP must supersede a
// pending MOVE for the same actor instead of racing it. AIM, trigger and RELOAD are
// separate keys because they are complementary parts of one firing decision.
const COMMAND_KEYS={
  SPAWN:c=>`spawn:${c.persistentNpcId}`,
  CAPTURE_AND_DESPAWN:c=>`despawn:${c.persistentNpcId}`,
  FORCE_DESTROY:c=>`despawn:${c.persistentNpcId||c.runtimeId}`,
  MOVE:c=>`nav:${c.npcId}`,
  STOP:c=>`nav:${c.npcId}`,
  AIM:c=>`aim:${c.persistentNpcId||c.npcId}`,
  FIRE_START:c=>`trigger:${c.persistentNpcId||c.npcId}`,
  FIRE_STOP:c=>`trigger:${c.persistentNpcId||c.npcId}`,
  RELOAD:c=>`reload:${c.persistentNpcId||c.npcId}`
};

function commandKeyFor(cmd){
  if(!cmd||!cmd.type)throw new TypeError('command type required');
  const builder=COMMAND_KEYS[cmd.type];
  if(builder){
    const key=builder(cmd);
    if(!/(undefined|null)$/.test(key))return key;
  }
  const id=cmd.persistentNpcId||cmd.npcId;
  return id?`${String(cmd.type).toLowerCase()}:${id}`:`__${cmd.type}`;
}

class CommandBroker{
  constructor({initialSeq=Date.now()*1000}={}){
    this.seq=Number(initialSeq)||0;
    this.records=new Map();
    this.acked=new Map();
  }
  nextSeq(){return ++this.seq;}
  submit(cmd){
    const commandKey=commandKeyFor(cmd);
    const seq=Number.isSafeInteger(cmd.seq)?cmd.seq:this.nextSeq();
    if(seq>this.seq)this.seq=seq;
    const record={...cmd,commandKey,seq,submittedAt:Number(cmd.submittedAt)||Date.now()};
    this.records.set(commandKey,record);
    return seq;
  }
  ack({seq,commandKey}={}){
    if(!commandKey)return false;
    const record=this.records.get(commandKey);
    const ackSeq=Number(seq);
    const previous=this.acked.get(commandKey);
    if(Number.isFinite(ackSeq)&&(previous==null||ackSeq>previous))this.acked.set(commandKey,ackSeq);
    if(!record)return false;
    // Stale ACK for an older command must not retire the newer record.
    if(!Number.isFinite(ackSeq)||ackSeq<record.seq)return false;
    this.records.delete(commandKey);
    return true;
  }
  isAcked(commandKey,seq){
    const known=this.acked.get(commandKey);
    return known!=null&&Number(seq)<=known;
  }
  pending(commandKey){return this.records.get(commandKey)||null;}
  retire(commandKey){return this.records.delete(commandKey);}
  prune(activeKeys){
    const keep=new Set(activeKeys||[]);
    let changed=false;
    for(const key of [...this.records.keys()]){
      if(key.startsWith('__')||keep.has(key))continue;
      this.records.delete(key);
      changed=true;
    }
    return changed;
  }
  // Convenience for callers that think in entity ids rather than command keys.
  pruneByEntityIds(activeIds){
    const keep=new Set(activeIds||[]);
    let changed=false;
    for(const [key,record] of [...this.records.entries()]){
      if(key.startsWith('__'))continue;
      const id=record.persistentNpcId||record.npcId||record.runtimeId;
      if(id&&keep.has(id))continue;
      this.records.delete(key);
      changed=true;
    }
    return changed;
  }
  removeByEntityId(id){
    let changed=false;
    for(const [key,record] of [...this.records.entries()]){
      if((record.persistentNpcId||record.npcId||record.runtimeId)===id){this.records.delete(key);changed=true;}
    }
    return changed;
  }
  snapshotRecords(){return [...this.records.values()].sort((a,b)=>a.seq-b.seq);}
  size(){return this.records.size;}
}
module.exports={CommandBroker,commandKeyFor,COMMAND_KEYS};
