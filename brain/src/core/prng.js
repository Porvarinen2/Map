'use strict';
function hashSeed(input) {
  const s = String(input);
  let h = 2166136261 >>> 0;
  for (let i = 0; i < s.length; i++) { h ^= s.charCodeAt(i); h = Math.imul(h, 16777619); }
  return h >>> 0;
}
function createRng(seed) {
  let a = hashSeed(seed) || 0x6d2b79f5;
  return function rng() {
    a |= 0; a = (a + 0x6D2B79F5) | 0;
    let t = Math.imul(a ^ (a >>> 15), 1 | a);
    t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t;
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}
function normalish(rng) { return (rng()+rng()+rng()+rng()+rng()+rng())/6; }
function clamp(v, lo=0, hi=1) { return Math.max(lo, Math.min(hi, v)); }
module.exports = { createRng, normalish, clamp, hashSeed };
