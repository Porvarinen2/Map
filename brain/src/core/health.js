'use strict';
class HealthRegistry{constructor(){this.items={};}set(name,status,detail=''){this.items[name]={status,detail,updatedAt:Date.now()};}ok(name,detail=''){this.set(name,'OK',detail);}degraded(name,detail=''){this.set(name,'DEGRADED',detail);}failed(name,detail=''){this.set(name,'FAILED',detail);}snapshot(){return JSON.parse(JSON.stringify(this.items));}}
module.exports={HealthRegistry};
