'use strict';
// Capability status vocabulary:
//   PENDING  - capability has never been exercisable yet (no player, no actor, no bridge).
//   OK       - live proof succeeded during this bridge session.
//   DEGRADED - capability was attempted and failed; the virtual world keeps running.
//   FAILED   - required subsystem cannot safely continue.
// A capability is never painted green by default and never painted yellow before it was tried.
const STATUSES=['PENDING','OK','DEGRADED','FAILED'];
class HealthRegistry{
  constructor(){this.items={};}
  set(name,status,detail=''){if(!STATUSES.includes(status))throw new TypeError(`unknown health status ${status}`);this.items[name]={status,detail,updatedAt:Date.now()};}
  pending(name,detail=''){this.set(name,'PENDING',detail);}
  ok(name,detail=''){this.set(name,'OK',detail);}
  degraded(name,detail=''){this.set(name,'DEGRADED',detail);}
  failed(name,detail=''){this.set(name,'FAILED',detail);}
  status(name){return this.items[name]?.status||null;}
  snapshot(){return JSON.parse(JSON.stringify(this.items));}
}
module.exports={HealthRegistry,STATUSES};
