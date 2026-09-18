'use strict';
class EventBus{constructor(){this.handlers=new Map();}on(type,fn){if(!this.handlers.has(type))this.handlers.set(type,new Set());this.handlers.get(type).add(fn);return()=>this.handlers.get(type)?.delete(fn);}emit(type,payload){for(const fn of this.handlers.get(type)||[])fn(payload);for(const fn of this.handlers.get('*')||[])fn({type,payload});}}
module.exports={EventBus};
