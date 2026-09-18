'use strict';
function decodeSafe(v){try{return decodeURIComponent(v||'');}catch{return String(v||'');}}
function coerce(v){if(v==='true')return true;if(v==='false')return false;if(v==='null')return null;const n=Number(v);if(v!==''&&Number.isFinite(n))return n;return decodeSafe(v);}
function parseEventLine(line){const parts=String(line).trim().split('|');if(parts.length<2)return null;const rawAt=Number(parts[0]);const event={at:Number.isFinite(rawAt)?rawAt:Date.now(),type:parts[1]};for(let i=2;i<parts.length;i++){const idx=parts[i].indexOf('=');if(idx<1)continue;const key=parts[i].slice(0,idx),value=coerce(parts[i].slice(idx+1));if(key==='type')event.commandType=value;else if(key==='at')event.payloadAt=value;else event[key]=value;}return event;}
function enc(v){return encodeURIComponent(String(v));}
function formatCommand(c){const keys=Object.keys(c).filter(k=>!['seq','type'].includes(k)&&c[k]!=null);return [c.seq||0,c.type,...keys.map(k=>`${k}=${enc(c[k])}`)].join('|');}
module.exports={parseEventLine,formatCommand};
