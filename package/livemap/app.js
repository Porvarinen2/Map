/* TESLES NPC OVERHAUL - live map client.
   Reads the director's snapshot from /api/state and draws the persistent
   world population over the SCUM map. Everything shown here is what the mod
   reports: a moving marker is a virtual position unless the group is flagged
   physical, and subsystem status is passed through unchanged. */
"use strict";

// The director ships its calibration in every snapshot; this is only the
// bootstrap value used before the first successful poll.
const CAL_DEFAULT = { xWest: 619646.8573, xEast: -905369.0266,
                      yNorth: 619659.7258, ySouth: -904357.5270 };

const ROWS = ["D", "C", "B", "A", "Z"];
const COLS = ["4", "3", "2", "1", "0"];

const CLASS_COLOR = {
  lone_wanderer:   "#c9d1dc",
  pair:            "#a8b6c8",
  hunters:         "#9fd67a",
  scavengers:      "#e0b673",
  police_patrol:   "#6fa8ff",
  military_group:  "#8fd0c0",
  radiation_group: "#c479ff",
  bunker_group:    "#7ac4d6",
  bandit_gang:     "#f07070",
  survivor_group:  "#e8e0c0",
  militia_cell:    "#d6a05f",
  elite_unit:      "#ff9d4f",
  island_residents:"#7ee0b8",
};

// Point-of-interest kinds on the hand-marked map (tools/poi_source.json).
const POI_STYLE = {
  CITY:             { c: "#ffd166", fi: "City",              shape: "square",  r: 6.5 },
  MILITARY:         { c: "#ff6b5b", fi: "Military base",     shape: "tri",     r: 6.5 },
  BUNKER:           { c: "#ff3b3b", fi: "Bunker",            shape: "square",  r: 5 },
  ABANDONED_BUNKER: { c: "#a07cff", fi: "Abandoned bunker",  shape: "square",  r: 5 },
  RESEARCH:         { c: "#4fd1a5", fi: "Research facility", shape: "hex",     r: 5.5 },
  INDUSTRIAL:       { c: "#c9a27a", fi: "Industrial",        shape: "square",  r: 4.5 },
  MEDICAL:          { c: "#ff8fc2", fi: "Hospital",          shape: "cross",   r: 5.5 },
  LANDMARK:         { c: "#f4a340", fi: "Landmark",          shape: "dot",     r: 4 },
  VILLAGE:          { c: "#6cc070", fi: "Village",           shape: "dot",     r: 3.2 },
  HUNTING:          { c: "#b5d86a", fi: "Hunting tower",     shape: "tick",    r: 3 },
  OUTPOST:          { c: "#3ee07a", fi: "Outpost (no NPCs)", shape: "ring", r: 7 },
};
// The mod keeps its groups this far from every outpost (world/pois.lua).
const OUTPOST_MARGIN_UU = 45000;
const ZONES = window.TESLES_ZONES || {};
const POIS = (window.TESLES_POIS || []).map(p => Object.assign({
  named: !/^[A-Z][0-4] /.test(p.n) }, p));

const STATE_FI = {
  IDLE: "Waiting", TRAVEL: "Travelling", SEARCH: "Searching buildings",
  HUNT: "Hunting", CAMP: "Camping", PATROL: "Patrolling", REST: "Resting",
  HOLD: "Guarding the area", COMBAT: "Fighting", RETREAT: "Retreating",
};

const canvas = document.getElementById("map");
const ctx = canvas.getContext("2d");
const wrap = document.getElementById("mapWrap");
const tipEl = document.getElementById("tip");

let state = { groups: [], events: [], health: [], stats: {}, calibration: CAL_DEFAULT };
let selected = null, selectedMember = null;
let tab = "world", filter = "all", query = "";
let view = { scale: 0, ox: 0, oy: 0 };
let show = { routes: true, trails: true, labels: false, grid: true, pois: true, queue: true };
let trails = new Map();
let hover = null, dragging = null;
let pollFails = 0, lastError = "";

/* ------------------------------------------------------------- map image */

const mapImg = new Image();
let mapReady = false;
let mapMissing = false;
// The packaged base map, then the names a user-supplied download tends to
// have, so a renamed or replaced file still shows something.
const MAP_CANDIDATES = [
  "map/scum_map.png", "map/scum_map_hires.png", "map/scum_map_hires.jpg",
  "map/scum_map_hires.jpeg", "map/scum_map_hires.webp", "map/scum_map_hires",
];
let mapCandidate = 0;
// Drawing a multi-thousand-pixel image scaled down, every frame, is what made
// panning lag. Halved copies are made once; each frame draws the smallest one
// that still has at least one image pixel per screen pixel.
let mapMips = [];
function buildMips() {
  mapMips = [{ img: mapImg, w: mapImg.naturalWidth }];
  let src = mapImg, w = mapImg.naturalWidth, h = mapImg.naturalHeight;
  while (w > 768) {
    w = Math.round(w / 2); h = Math.round(h / 2);
    const c = document.createElement("canvas");
    c.width = w; c.height = h;
    const g = c.getContext("2d");
    g.imageSmoothingEnabled = true; g.imageSmoothingQuality = "high";
    g.drawImage(src, 0, 0, w, h);
    mapMips.push({ img: c, w });
    src = c;
  }
}
mapImg.onload = () => {
  mapReady = true; mapMissing = false;
  try { buildMips(); } catch (e) { mapMips = [{ img: mapImg, w: mapImg.naturalWidth }]; }
  if (!view.scale) fit(); else draw();
};
mapImg.onerror = () => {
  mapCandidate++;
  if (mapCandidate < MAP_CANDIDATES.length) {
    mapImg.src = MAP_CANDIDATES[mapCandidate];
  } else {
    mapMissing = true;
    lastError = "no map image in livemap\\map\\";
    draw();
  }
};
mapImg.src = MAP_CANDIDATES[0];

// A tiled pyramid produced by SETUP_HIRES_MAP.bat takes over when present.
let tiles = null;
const tileCache = new Map();
fetch("map/tiles/meta.json").then(r => r.ok ? r.json() : null).then(meta => {
  if (meta && meta.levels && meta.levels.length) {
    tiles = meta;
    mapReady = true;
    if (!view.scale) fit(); else draw();
  }
}).catch(() => {});

function mapSize() {
  if (tiles) return { w: tiles.width, h: tiles.height };
  if (mapImg.naturalWidth) return { w: mapImg.naturalWidth, h: mapImg.naturalHeight };
  return { w: 2048, h: 2048 };
}

/* ------------------------------------------------------- coordinate maths */

function cal() { return Object.assign({}, CAL_DEFAULT, state.calibration || {}); }

function worldToNorm(x, y) {
  const c = cal();
  return { u: (c.xWest - x) / (c.xWest - c.xEast),
           v: (c.yNorth - y) / (c.yNorth - c.ySouth) };
}
function normToWorld(u, v) {
  const c = cal();
  return { x: c.xWest - u * (c.xWest - c.xEast),
           y: c.yNorth - v * (c.yNorth - c.ySouth) };
}
function sectorOf(x, y) {
  const n = worldToNorm(x, y);
  if (n.u < 0 || n.u >= 1 || n.v < 0 || n.v >= 1) return "OUT";
  return ROWS[Math.floor(n.v * 5)] + COLS[Math.floor(n.u * 5)];
}
function imgToScreen(px, py) {
  return { x: view.ox + px * view.scale, y: view.oy + py * view.scale };
}
function screenToImg(sx, sy) {
  return { x: (sx - view.ox) / view.scale, y: (sy - view.oy) / view.scale };
}
function worldToScreen(x, y) {
  const n = worldToNorm(x, y), s = mapSize();
  return imgToScreen(n.u * s.w, n.v * s.h);
}
function screenToWorld(sx, sy) {
  const p = screenToImg(sx, sy), s = mapSize();
  return normToWorld(p.x / s.w, p.y / s.h);
}

/* ------------------------------------------------------------- view state */

function resize() {
  const r = canvas.getBoundingClientRect();
  const d = window.devicePixelRatio || 1;
  canvas.width = Math.max(1, Math.round(r.width * d));
  canvas.height = Math.max(1, Math.round(r.height * d));
  ctx.setTransform(d, 0, 0, d, 0, 0);
  if (!view.scale) fit(); else draw();
}

function fit() {
  const r = canvas.getBoundingClientRect(), s = mapSize();
  if (!s.w) return;
  const k = Math.min(r.width / s.w, r.height / s.h);
  view.scale = k;
  view.ox = (r.width - s.w * k) / 2;
  view.oy = (r.height - s.h * k) / 2;
  draw();
}

function zoomAt(sx, sy, factor) {
  const before = screenToImg(sx, sy);
  const s = mapSize();
  const r = canvas.getBoundingClientRect();
  const minScale = Math.min(r.width / s.w, r.height / s.h) * 0.85;
  // Deepest zoom: about 3 screen pixels per map pixel of the sharpest map
  // (past that there is nothing more to see, only blur).
  const maxScale = 3 * (tiles ? 1 : 14481 / s.w) / Math.max(1, (window.devicePixelRatio || 1) * 0.75);
  view.scale = Math.max(minScale, Math.min(maxScale, view.scale * factor));
  const after = screenToImg(sx, sy);
  view.ox += (after.x - before.x) * view.scale;
  view.oy += (after.y - before.y) * view.scale;
  draw();
}

/* -------------------------------------------------------------- drawing */

function drawBase(r) {
  ctx.fillStyle = "#05060a";
  ctx.fillRect(0, 0, r.width, r.height);
  const s = mapSize();
  if (tiles) {
    // The whole island at low detail first, so a tile still loading never
    // leaves a black hole; the sharp tiles are painted over it.
    if (mapReady && mapImg.naturalWidth && mapMips.length) {
      const o0 = imgToScreen(0, 0);
      const need0 = s.w * view.scale;
      let pick0 = mapMips[0];
      for (const m of mapMips) if (m.w >= need0 / 2) pick0 = m;
      ctx.imageSmoothingEnabled = true; ctx.imageSmoothingQuality = "high";
      ctx.drawImage(pick0.img, o0.x, o0.y, s.w * view.scale, s.h * view.scale);
    }
    drawTiles(r, s);
    const o = imgToScreen(0, 0);
    ctx.fillStyle = "rgba(6,8,12,.22)";
    ctx.fillRect(o.x, o.y, s.w * view.scale, s.h * view.scale);
  } else if (mapReady && mapImg.naturalWidth) {
    const o = imgToScreen(0, 0);
    const need = s.w * view.scale;
    let pick = mapMips[0] || { img: mapImg, w: s.w };
    for (const m of mapMips) if (m.w >= need) pick = m;
    ctx.imageSmoothingEnabled = true; ctx.imageSmoothingQuality = "high";
    ctx.drawImage(pick.img, o.x, o.y, s.w * view.scale, s.h * view.scale);
    ctx.fillStyle = "rgba(6,8,12,.22)";
    ctx.fillRect(o.x, o.y, s.w * view.scale, s.h * view.scale);
  } else if (mapMissing) {
    drawMissingMap(r);
  } else {
    ctx.fillStyle = "#6d7684";
    ctx.font = "13px Inter, sans-serif";
    ctx.fillText("Loading the map…", 20, 30);
  }
}

// The grid alone looks like a broken page; say what is actually wrong.
function drawMissingMap(r) {
  const lines = [
    "No map image found.",
    "",
    "Save the map as  livemap\\map\\scum_map.png",
    "or run tools\\SETUP_HIRES_MAP.bat to make it from the 14k map.",
    "",
    "Squads are still drawn on the grid.",
  ];
  ctx.save();
  ctx.textAlign = "center";
  const cx = r.width / 2;
  let y = r.height / 2 - lines.length * 11;
  lines.forEach((t, i) => {
    ctx.font = i === 0 ? "600 15px Inter, sans-serif" : "13px Inter, sans-serif";
    ctx.fillStyle = i === 0 ? "#e8c25a" : "#98a1ad";
    ctx.fillText(t, cx, y);
    y += 22;
  });
  ctx.restore();
}

// Picks the pyramid level whose pixels are closest to one screen pixel, then
// paints only the tiles inside the viewport.
function drawTiles(r, s) {
  // The smallest level with at least one image pixel per screen pixel
  // (device pixels): sharp at every zoom, never more than needed.
  const want = s.w * view.scale * (window.devicePixelRatio || 1);
  let best = tiles.levels[tiles.levels.length - 1];
  for (const lv of tiles.levels) { if (lv.width >= want * 0.9) { best = lv; break; } }
  const k = view.scale * (s.w / best.width);
  const ts = best.tile;
  const x0 = Math.max(0, Math.floor((-view.ox) / (ts * k)));
  const y0 = Math.max(0, Math.floor((-view.oy) / (ts * k)));
  const x1 = Math.min(best.cols - 1, Math.ceil((r.width - view.ox) / (ts * k)));
  const y1 = Math.min(best.rows - 1, Math.ceil((r.height - view.oy) / (ts * k)));
  ctx.imageSmoothingEnabled = true; ctx.imageSmoothingQuality = "high";
  for (let ty = y0; ty <= y1; ty++) {
    for (let tx = x0; tx <= x1; tx++) {
      const key = best.z + "/" + tx + "/" + ty;
      let img = tileCache.get(key);
      if (img === undefined) {
        img = new Image();
        img.onload = () => draw();
        img.onerror = () => tileCache.set(key, null);
        img.src = "map/tiles/" + best.z + "/" + tx + "_" + ty + "." + (tiles.ext || "jpg");
        tileCache.set(key, img);
      }
      if (img && img.complete && img.naturalWidth) {
        // Half a pixel of overlap hides the seams between tiles.
        const tw = img.naturalWidth * k, th = img.naturalHeight * k;
        ctx.drawImage(img, view.ox + tx * ts * k - 0.25, view.oy + ty * ts * k - 0.25,
                      tw + 0.5, th + 0.5);
      }
    }
  }
}

function drawGrid() {
  const s = mapSize();
  ctx.save();
  ctx.strokeStyle = "rgba(255,255,255,.13)";
  ctx.lineWidth = 1;
  ctx.font = "600 12px Inter, sans-serif";
  ctx.fillStyle = "rgba(255,255,255,.5)";
  ctx.shadowColor = "rgba(0,0,0,.8)"; ctx.shadowBlur = 0;
  for (let i = 0; i <= 5; i++) {
    const a = imgToScreen(i / 5 * s.w, 0), b = imgToScreen(i / 5 * s.w, s.h);
    ctx.beginPath(); ctx.moveTo(a.x, a.y); ctx.lineTo(b.x, b.y); ctx.stroke();
    const c = imgToScreen(0, i / 5 * s.h), d = imgToScreen(s.w, i / 5 * s.h);
    ctx.beginPath(); ctx.moveTo(c.x, c.y); ctx.lineTo(d.x, d.y); ctx.stroke();
  }
  for (let row = 0; row < 5; row++) {
    for (let col = 0; col < 5; col++) {
      const p = imgToScreen((col + 0.03) / 5 * s.w, (row + 0.11) / 5 * s.h);
      ctx.fillText(ROWS[row] + COLS[col], p.x, p.y);
    }
  }
  ctx.restore();
}

// Own classes (ryhmat.lua) bring their colour; without one, a stable colour
// is made from the class name.
function classColor(key) {
  if (CLASS_COLOR[key]) return CLASS_COLOR[key];
  const def = (state.classDefs || []).find(d => d.key === key);
  if (def && def.color) return def.color;
  let h = 0;
  for (const ch of String(key)) h = (h * 31 + ch.charCodeAt(0)) >>> 0;
  return `hsl(${h % 360},70%,68%)`;
}
function colorFor(g) { return classColor(g.class); }
// Colour with an alpha suffix (hex "aa"), whatever form the colour is in.
function withAlpha(c, hex) {
  if (/^#[0-9a-f]{6}$/i.test(c)) return c + hex;
  if (/^#[0-9a-f]{3}$/i.test(c)) return "#" + c[1] + c[1] + c[2] + c[2] + c[3] + c[3] + hex;
  const a = (parseInt(hex, 16) / 255).toFixed(2);
  if (c.startsWith("hsl(")) return c.replace("hsl(", "hsla(").replace(")", `,${a})`);
  return c;
}

function poiShape(x, y, st, k) {
  const r = st.r * k;
  ctx.beginPath();
  switch (st.shape) {
    case "square": ctx.rect(x - r, y - r, r * 2, r * 2); break;
    case "tri": ctx.moveTo(x, y - r * 1.15); ctx.lineTo(x + r, y + r * 0.8);
      ctx.lineTo(x - r, y + r * 0.8); ctx.closePath(); break;
    case "hex": for (let i = 0; i < 6; i++) {
        const a = Math.PI / 3 * i + Math.PI / 6;
        ctx[i ? "lineTo" : "moveTo"](x + r * Math.cos(a), y + r * Math.sin(a));
      } ctx.closePath(); break;
    case "cross": { const t = r * 0.38;
      ctx.rect(x - t, y - r, t * 2, r * 2); ctx.rect(x - r, y - t, r * 2, t * 2); break; }
    case "tick": ctx.moveTo(x, y - r * 1.3); ctx.lineTo(x + r, y + r * 0.7);
      ctx.lineTo(x - r, y + r * 0.7); ctx.closePath(); break;
    default: ctx.arc(x, y, r, 0, Math.PI * 2);
  }
}

// C0: the radiation squads' zone, closed to everyone else, with Krsko's five
// sweep areas. The area a selected radiation squad is working is lit.
function drawZones(moving) {
  const rz = ZONES.radiation;
  if (!rz) return;
  const s = mapSize();
  const ri = ROWS.indexOf(rz.sector[0]), ci = COLS.indexOf(rz.sector[1]);
  const a = imgToScreen(ci / 5 * s.w, ri / 5 * s.h);
  const b = imgToScreen((ci + 1) / 5 * s.w, (ri + 1) / 5 * s.h);
  ctx.save();
  ctx.fillStyle = "rgba(196,121,255,.07)";
  ctx.fillRect(a.x, a.y, b.x - a.x, b.y - a.y);
  ctx.strokeStyle = "rgba(196,121,255,.8)";
  ctx.setLineDash([10, 6]); ctx.lineWidth = 2;
  ctx.strokeRect(a.x, a.y, b.x - a.x, b.y - a.y);
  ctx.setLineDash([]);
  if (!moving) {
    ctx.font = "600 11px Inter, sans-serif";
    ctx.textAlign = "left"; ctx.textBaseline = "top";
    ctx.lineWidth = 3; ctx.strokeStyle = "rgba(0,0,0,.85)";
    const t = "☢ RADIATION ZONE · radiation squads only";
    ctx.strokeText(t, a.x + 6, a.y + 18);
    ctx.fillStyle = "#d9a8ff"; ctx.fillText(t, a.x + 6, a.y + 18);
  }
  const sel = selected && state.groups.find(g => g.gid === selected.gid);
  const lit = sel && sel.sweep_area;
  (ZONES.sweep || []).forEach(z => {
    ctx.beginPath();
    z.poly.forEach((p, i) => {
      const q = worldToScreen(p[0], p[1]);
      if (i) ctx.lineTo(q.x, q.y); else ctx.moveTo(q.x, q.y);
    });
    ctx.closePath();
    const on = lit === z.id;
    ctx.fillStyle = on ? "rgba(255,0,255,.28)" : "rgba(255,0,255,.09)";
    ctx.fill();
    ctx.strokeStyle = on ? "rgba(255,120,255,.95)" : "rgba(255,0,255,.45)";
    ctx.lineWidth = on ? 2 : 1;
    ctx.stroke();
    if (!moving && view.scale > 0.9) {
      let cx = 0, cy = 0;
      z.poly.forEach(p => { cx += p[0]; cy += p[1]; });
      const c = worldToScreen(cx / z.poly.length, cy / z.poly.length);
      ctx.font = "bold 13px Inter, sans-serif";
      ctx.textAlign = "center"; ctx.textBaseline = "middle";
      ctx.lineWidth = 3; ctx.strokeStyle = "rgba(0,0,0,.85)";
      ctx.strokeText(String(z.id), c.x, c.y);
      ctx.fillStyle = "#ffb3ff"; ctx.fillText(String(z.id), c.x, c.y);
    }
  });
  ctx.restore();
}

// The places groups actually travel to. Minor places (villages, hunting
// towers) appear as the map is zoomed in; names follow at closer zoom.
function drawPois(moving) {
  if (!POIS.length) return;
  const r = canvas.getBoundingClientRect();
  const z = view.scale;
  const k = Math.max(0.75, Math.min(1.6, 0.7 + z * 0.35));
  ctx.save();
  for (const p of POIS) {
    if (p.k === "HUNTING" && z < 0.75) continue;
    if (p.k === "VILLAGE" && z < 0.45) continue;
    const s = worldToScreen(p.x, p.y);
    if (s.x < -60 || s.y < -60 || s.x > r.width + 60 || s.y > r.height + 60) continue;
    const st = POI_STYLE[p.k] || POI_STYLE.LANDMARK;
    if (p.k === "OUTPOST") {
      const e = worldToScreen(p.x + OUTPOST_MARGIN_UU, p.y);
      const rr = Math.abs(e.x - s.x);
      ctx.fillStyle = "rgba(62,224,122,.07)";
      ctx.strokeStyle = "rgba(62,224,122,.55)";
      ctx.setLineDash([5, 4]); ctx.lineWidth = 1.2;
      ctx.beginPath(); ctx.arc(s.x, s.y, rr, 0, Math.PI * 2); ctx.fill(); ctx.stroke();
      ctx.setLineDash([]);
      ctx.lineWidth = 2.2; ctx.strokeStyle = st.c;
      ctx.beginPath(); ctx.arc(s.x, s.y, st.r * k, 0, Math.PI * 2); ctx.stroke();
    } else {
      poiShape(s.x, s.y, st, k);
      ctx.fillStyle = st.c; ctx.fill();
      ctx.lineWidth = 1.2; ctx.strokeStyle = "rgba(0,0,0,.75)"; ctx.stroke();
    }
    if (moving) continue;
    if ((p.named && z >= 0.7) || z >= 2.2) {
      ctx.font = (p.named ? "600 " : "") + "11px Inter, sans-serif";
      ctx.textAlign = "left"; ctx.textBaseline = "middle";
      ctx.lineWidth = 3; ctx.strokeStyle = "rgba(0,0,0,.8)";
      ctx.strokeText(p.n, s.x + st.r * k + 4, s.y);
      ctx.fillStyle = p.named ? "#f2f4f7" : "#c3c9d2";
      ctx.fillText(p.n, s.x + st.r * k + 4, s.y);
    }
  }
  ctx.restore();
}

// The three places planned after the current goal: a thin chain from the goal
// through numbered stops. The selected group gets the full version.
function drawQueue(g, isSel) {
  const q = g.queue || [];
  if (!q.length) return;
  const col = colorFor(g);
  let from = (g.goal_x != null) ? worldToScreen(g.goal_x, g.goal_y) : worldToScreen(g.x, g.y);
  ctx.save();
  ctx.lineWidth = isSel ? 2 : 1;
  ctx.strokeStyle = isSel ? col : withAlpha(col, "70");
  ctx.setLineDash(isSel ? [4, 4] : [2, 5]);
  ctx.beginPath(); ctx.moveTo(from.x, from.y);
  const pts = q.map(p => worldToScreen(p.x, p.y));
  pts.forEach(p => ctx.lineTo(p.x, p.y));
  ctx.stroke();
  ctx.setLineDash([]);
  // Zoomed out, other groups' stops are plain dots: thirty sets of numbers
  // at once only hide the map.
  const small = !isSel && view.scale < 0.8;
  const rad = isSel ? 8 : small ? 2.5 : 5.5;
  pts.forEach((p, i) => {
    ctx.beginPath(); ctx.arc(p.x, p.y, rad, 0, Math.PI * 2);
    ctx.fillStyle = isSel ? "rgba(10,12,16,.92)" : "rgba(10,12,16,.75)";
    ctx.fill();
    ctx.lineWidth = isSel ? 2 : 1.2; ctx.strokeStyle = col; ctx.stroke();
    if (small) return;
    ctx.fillStyle = col;
    ctx.font = `bold ${isSel ? 10 : 8}px Inter, sans-serif`;
    ctx.textAlign = "center"; ctx.textBaseline = "middle";
    ctx.fillText(String(i + 1), p.x, p.y + 0.5);
    // The POI layer already names a named place at this zoom.
    const named = show.pois && view.scale >= 0.7 && !/^[A-Z][0-4] /.test(q[i].label || "");
    if (isSel && !named) {
      const label = q[i].label || q[i].id;
      ctx.font = "11px Inter, sans-serif"; ctx.textAlign = "left";
      ctx.lineWidth = 3; ctx.strokeStyle = "rgba(0,0,0,.85)";
      ctx.strokeText(label, p.x + 11, p.y);
      ctx.fillStyle = "#fff"; ctx.fillText(label, p.x + 11, p.y);
    }
  });
  ctx.restore();
}

function drawRoute(g) {
  if (!g.route || g.route.length < 2) return;
  ctx.save();
  const isSel = selected && g.gid === selected.gid;
  ctx.strokeStyle = isSel ? "rgba(255,206,130,.98)" : "rgba(224,182,115,.62)";
  ctx.lineWidth = isSel ? 2.6 : 1.5;
  // shadowBlur was the single most expensive thing on this canvas: a blur
  // pass per route per frame. A dark under-stroke gives the same contrast.
  ctx.beginPath();
  g.route.forEach((p, i) => {
    const s = worldToScreen(p[0], p[1]);
    if (i === 0) ctx.moveTo(s.x, s.y); else ctx.lineTo(s.x, s.y);
  });
  if (isSel) {
    const c = ctx.strokeStyle, w = ctx.lineWidth;
    ctx.strokeStyle = "rgba(0,0,0,.55)"; ctx.lineWidth = w + 2.5;
    ctx.stroke();
    ctx.strokeStyle = c; ctx.lineWidth = w;
  }
  ctx.setLineDash(isSel ? [] : [7, 5]);
  ctx.stroke();
  const end = g.route[g.route.length - 1];
  const e = worldToScreen(end[0], end[1]);
  ctx.setLineDash([]);
  // Destination marker: hollow diamond, so it never reads as a group.
  ctx.strokeStyle = "rgba(255,206,130,.95)";
  ctx.lineWidth = 1.6;
  ctx.beginPath();
  ctx.moveTo(e.x, e.y - 6); ctx.lineTo(e.x + 6, e.y);
  ctx.lineTo(e.x, e.y + 6); ctx.lineTo(e.x - 6, e.y);
  ctx.closePath(); ctx.stroke();
  ctx.restore();
}

function drawTrail(g) {
  const t = trails.get(g.gid);
  if (!t || t.length < 2) return;
  ctx.save();
  ctx.strokeStyle = withAlpha(colorFor(g), g === selected ? "cc" : "55");
  ctx.lineWidth = g === selected ? 2 : 1;
  ctx.beginPath();
  t.forEach((p, i) => {
    const s = worldToScreen(p[0], p[1]);
    if (i === 0) ctx.moveTo(s.x, s.y); else ctx.lineTo(s.x, s.y);
  });
  ctx.stroke();
  ctx.restore();
}

function drawGroup(g) {
  const p = worldToScreen(g.x, g.y);
  const col = colorFor(g);
  const isSel = selected && g.gid === selected.gid;
  const r = 5 + Math.min(4, g.members_alive * 0.7);

  ctx.save();
  if (g.physical_members > 0) {
    ctx.beginPath();
    ctx.arc(p.x, p.y, r + 6, 0, Math.PI * 2);
    ctx.strokeStyle = "rgba(95,214,127,.75)";
    ctx.lineWidth = 1.6;
    ctx.stroke();
  }
  // Mood ring: how the squad is holding up.
  const MOOD_RING = { PANIC: "rgba(255,70,70,.95)", ROUT: "rgba(255,70,70,.95)",
    SHOCK: "rgba(255,255,255,.9)",
    SHAKEN: "rgba(255,150,60,.85)", TENSE: "rgba(240,200,80,.7)",
    ZOMBIES: "rgba(150,230,120,.9)", INVESTIGATE: "rgba(120,190,255,.85)",
    AVOID: "rgba(200,170,255,.8)", HOLD: "rgba(200,200,200,.7)", COVER: "rgba(255,120,200,.9)",
    CHASE_PLAYER: "rgba(255,90,90,.9)", CHASE_ZOMBIE: "rgba(150,230,120,.9)", CHASE_ANIMAL: "rgba(190,220,110,.85)",
    FIGHT: "rgba(255,70,70,.95)" };
  const mr = MOOD_RING[g.mood];
  if (mr) {
    ctx.beginPath();
    ctx.arc(p.x, p.y, r + 3.5, 0, Math.PI * 2);
    ctx.strokeStyle = mr;
    ctx.lineWidth = (g.mood === "PANIC" || g.mood === "ROUT") ? 3 : 2;
    ctx.setLineDash(g.mood === "HOLD" || g.mood === "AVOID" ? [3, 3] : []);
    ctx.stroke();
    ctx.setLineDash([]);
  }
  if (g.state === "COMBAT") {
    ctx.beginPath();
    ctx.arc(p.x, p.y, r + 10, 0, Math.PI * 2);
    ctx.strokeStyle = "rgba(240,112,112,.8)";
    ctx.lineWidth = 2;
    ctx.stroke();
  }
  // Heading from the last trail step: a small wedge in front of the marker.
  const t = trails.get(g.gid);
  if (t && t.length >= 2) {
    const a = t[t.length - 2], b = t[t.length - 1];
    const sa = worldToScreen(a[0], a[1]), sb = worldToScreen(b[0], b[1]);
    const ang = Math.atan2(sb.y - sa.y, sb.x - sa.x);
    if (Math.hypot(sb.x - sa.x, sb.y - sa.y) > 0.3) {
      ctx.beginPath();
      ctx.moveTo(p.x + Math.cos(ang) * (r + 7), p.y + Math.sin(ang) * (r + 7));
      ctx.lineTo(p.x + Math.cos(ang + 2.5) * (r + 1), p.y + Math.sin(ang + 2.5) * (r + 1));
      ctx.lineTo(p.x + Math.cos(ang - 2.5) * (r + 1), p.y + Math.sin(ang - 2.5) * (r + 1));
      ctx.closePath();
      ctx.fillStyle = col; ctx.fill();
      ctx.lineWidth = 1; ctx.strokeStyle = "rgba(0,0,0,.7)"; ctx.stroke();
    }
  }
  // A soft drop shadow, then the disc lit from the top-left.
  ctx.save();
  ctx.shadowColor = "rgba(0,0,0,.65)"; ctx.shadowBlur = 9; ctx.shadowOffsetY = 2;
  ctx.beginPath();
  ctx.arc(p.x, p.y, r + 1.5, 0, Math.PI * 2);
  ctx.fillStyle = "rgba(8,10,14,.85)";
  ctx.fill();
  ctx.restore();
  const grad = ctx.createRadialGradient(p.x - r * 0.35, p.y - r * 0.4, r * 0.15, p.x, p.y, r);
  grad.addColorStop(0, "rgba(255,255,255,.55)");
  grad.addColorStop(0.35, col);
  grad.addColorStop(1, col);
  ctx.beginPath();
  ctx.arc(p.x, p.y, r, 0, Math.PI * 2);
  ctx.fillStyle = grad;
  ctx.fill();
  ctx.lineWidth = isSel ? 2.4 : 1.2;
  ctx.strokeStyle = isSel ? "#fff" : "rgba(0,0,0,.7)";
  ctx.stroke();

  // Member count badge
  ctx.font = "bold 10px Inter, sans-serif";
  ctx.textAlign = "center";
  ctx.textBaseline = "middle";
  ctx.fillStyle = "#07080a";
  ctx.fillText(String(g.members_alive), p.x, p.y + 0.5);

  if (show.labels || isSel) {
    const label = g.gid + "  " + (STATE_FI[g.state] || g.state)
      + (g.mood && g.mood !== "CALM" ? " · " + (g.mood_fi || g.mood) : "");
    ctx.font = "11px Inter, sans-serif";
    ctx.textAlign = "left";
    const w = ctx.measureText(label).width;
    ctx.fillStyle = "rgba(7,8,10,.86)";
    ctx.beginPath();
    if (ctx.roundRect) ctx.roundRect(p.x + r + 6, p.y - 9, w + 12, 18, 6);
    else ctx.rect(p.x + r + 6, p.y - 9, w + 12, 18);
    ctx.fill();
    ctx.strokeStyle = col; ctx.globalAlpha = 0.55; ctx.lineWidth = 1; ctx.stroke(); ctx.globalAlpha = 1;
    ctx.fillStyle = "#eef0f3";
    ctx.fillText(label, p.x + r + 12, p.y + 0.5);
  }
  ctx.restore();
}

// Every mouse move, wheel step, tile load and poll used to repaint the whole
// canvas on the spot. Requests are now merged into one paint per frame.
let drawQueued = false;
let lastInteraction = 0;
function draw() {
  if (drawQueued) return;
  drawQueued = true;
  requestAnimationFrame(() => { drawQueued = false; drawNow(); });
}

function drawNow() {
  const r = canvas.getBoundingClientRect();
  drawBase(r);
  if (show.grid) drawGrid();

  // While the map is being dragged or zoomed only the markers are drawn; the
  // trails and every group's route come back as soon as it stops.
  const moving = performance.now() - lastInteraction < 180;
  if (moving) setTimeout(draw, 200);
  if (show.pois) { drawZones(moving); drawPois(moving); }
  const list = visibleGroups();
  if (show.trails && !moving) list.forEach(drawTrail);
  if (show.queue && !moving) list.forEach(g => {
    if (!selected || g.gid !== selected.gid) drawQueue(g, false);
  });
  if (show.routes && !moving) list.forEach(g => { if (g !== selected) drawRoute(g); });
  list.forEach(g => { if (!selected || g.gid !== selected.gid) drawGroup(g); });
  if (selected) {
    const live = state.groups.find(g => g.gid === selected.gid);
    if (live) {
      if (show.queue) drawQueue(live, true);
      if (show.routes) drawRoute(live);
      drawGroup(live);
    }
  }
  (state.players || []).forEach(drawPlayer);
}

// A player: white diamond with a dashed ring at the materialise distance, so
// it is obvious how close a group has to be before it becomes real in game.
function drawPlayer(p) {
  const s = worldToScreen(p.x, p.y);
  const lod = state.lod || {};
  const ring = worldToScreen(p.x + (lod.render_m || 1000) * 100, p.y);
  const rr = Math.abs(ring.x - s.x);
  if (rr > 4) {
    ctx.save();
    ctx.setLineDash([6, 5]);
    ctx.strokeStyle = "rgba(255,255,255,0.55)";
    ctx.lineWidth = 1.5;
    ctx.beginPath(); ctx.arc(s.x, s.y, rr, 0, Math.PI * 2); ctx.stroke();
    ctx.restore();
  }
  ctx.save();
  ctx.translate(s.x, s.y); ctx.rotate(Math.PI / 4);
  ctx.fillStyle = "#ffffff"; ctx.strokeStyle = "#111"; ctx.lineWidth = 2;
  ctx.fillRect(-6, -6, 12, 12); ctx.strokeRect(-6, -6, 12, 12);
  ctx.restore();
  ctx.font = "12px system-ui, sans-serif";
  ctx.fillStyle = "#fff"; ctx.strokeStyle = "rgba(0,0,0,0.8)"; ctx.lineWidth = 3;
  const label = "PLAYER" + (p.nearest_m != null
    ? `  nearest squad ${(p.nearest_m / 1000).toFixed(1)} km` : "");
  ctx.strokeText(label, s.x + 12, s.y - 10);
  ctx.fillText(label, s.x + 12, s.y - 10);
}

/* --------------------------------------------------------------- filters */

function visibleGroups() {
  return (state.groups || []).filter(g => {
    if (filter === "physical" && !(g.physical_members > 0)) return false;
    if (filter === "travel" && g.state !== "TRAVEL") return false;
    if (filter === "working" && ["TRAVEL", "IDLE"].includes(g.state)) return false;
    if (filter === "combat" && g.state !== "COMBAT") return false;
    if (query) {
      const hay = [g.gid, g.name, g.class_fi, g.goal, g.intent, g.sector,
                   ...(g.members || []).map(m => m.name)].join(" ").toLowerCase();
      if (!hay.includes(query)) return false;
    }
    return true;
  });
}

/* ----------------------------------------------------------------- panel */

const esc = v => String(v ?? "").replace(/[&<>"']/g,
  c => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]));

function bar(v, max, cls) {
  const pct = Math.max(0, Math.min(100, (Number(v) || 0) / (max || 1) * 100));
  return `<div class="bar ${cls || ""}"><i style="width:${pct}%"></i></div>`;
}

function renderWorld() {
  const s = state.stats || {};
  const lod = state.lod || {};
  const players = (state.players || []).map(p => `
      <div class="h"><div><div class="k">Player on the map</div>
        <div class="d">nearest squad ${esc(p.nearest_gid || "-")} · ${
          p.nearest_m != null ? (p.nearest_m / 1000).toFixed(2) + " km" : "-"} ·
          fyysinen alle ${esc(lod.render_m || 1000)} m</div></div>
        <div class="s OK">ONLINE</div></div>`).join("");
  const playersSection = `
    <div class="section"><h2>Players</h2><div class="health">${players ||
      '<div class="h"><div><div class="k">No players</div><div class="d">A player shows up ' +
      'a few seconds after joining.</div></div><div class="s PENDING">-</div></div>'}</div></div>`;
  const waiting = state.waiting ? `
    <div class="section">
      <h2>Waiting for data</h2>
      <div class="health">
        <div class="h"><div><div class="k">${esc(state.reason || "")}</div>
          <div class="d">Mod output: ${esc(state.output || "unknown")}</div></div>
          <div class="s PENDING">WAITING</div></div>
      </div>
      <div class="note">
        1. Is the SCUM server running? The mod starts 25 s after the server.<br>
        2. Look at output\\boot.log in the mod folder - it shows how far the mod got.<br>
        3. If boot.log is missing, UE4SS does not load the mod: check the line
           "TeslesNPCOverhaul : 1" in Mods\\mods.txt, and UE4SS.log.<br>
        4. DIAGNOSE.bat collects all of this into one zip.
      </div>
    </div>` : "";
  const health = (state.health || []).map(h => `
    <div class="h">
      <div><div class="k">${esc(h.key)}</div><div class="d">${esc(h.detail)}</div></div>
      <div class="s ${esc(h.status)}">${esc(h.status)}</div>
    </div>`).join("");

  return `<div class="pad">
    ${waiting}
    ${playersSection}
    <div class="section">
      <h2>Population</h2>
      <div class="grid2">
        <div class="stat"><div class="v">${s.alive ?? 0}</div><div class="l">NPCs alive</div></div>
        <div class="stat"><div class="v">${s.groups ?? 0}</div><div class="l">Squads</div></div>
        <div class="stat"><div class="v">${s.physical ?? 0}</div><div class="l">Physical</div></div>
        <div class="stat"><div class="v">${s.arrivals ?? 0}</div><div class="l">Arrivals</div></div>
      </div>
    </div>

    <div class="section">
      <h2>Subsystems</h2>
      <div class="health">${health || '<div class="empty">No data</div>'}</div>
      <div class="note">Only what the server has proven. OK in spawnCatalog
        means the NPC classes were found, not that spawning, movement or
        combat work.</div>
    </div>

    <div class="section">
      <h2>Routing and movement</h2>
      <div class="kv">
        <b>Routes</b><span>${s.routes ?? 0} (failed ${s.route_fail ?? 0})</span>
        <b>Move orders</b><span>${s.commands ?? 0}</span>
        <b>Re-plans</b><span>${s.replans ?? 0}</span>
        <b>Spawns</b><span>${s.spawns ?? 0} (failed ${s.spawn_fail ?? 0})</span>
        <b>Encounters</b><span>${s.contacts ?? 0}</span>
        <b>Deaths</b><span>${s.deaths ?? 0}</span>
      </div>
    </div>

    <div class="section">
      <h2>Render circle</h2>
      <div class="kv">
        <b>Physical</b><span>≤ ${lod.render_m ?? "–"} m from a player (on the map, height ignored)</span>
        <b>Virtual</b><span>&gt; ${lod.render_m ?? "–"} m</span>
      </div>
      <div class="note">A marker is a virtual position unless the squad is
        marked physical. Green ring = the squad has real bodies in the game.</div>
    </div>
  </div>`;
}

function groupCard(g) {
  const sel = selected && selected.gid === g.gid ? " sel" : "";
  const phys = g.physical_members > 0
    ? `<span class="pill phys">PHYSICAL ${g.physical_members}</span>`
    : `<span class="pill virt">VIRTUAL</span>`;
  return `<div class="card${sel}" data-gid="${esc(g.gid)}">
    <div class="top">
      <span class="name" style="color:${colorFor(g)}">${esc(g.gid)}</span>
      ${phys}
    </div>
    <div class="meta">
      ${esc(g.class_fi)} · level ${g.level} · ${g.members_alive}/${g.members_total} NPCs · ${esc(g.sector)}<br>
      ${esc(g.intent || STATE_FI[g.state] || g.state)}
      ${g.route_km ? ` · ${g.route_km} km (${esc(g.route_kind || "")})` : ""}
      ${(g.queue || []).length ? `<br><span class="q">Next: ${g.queue.map(q => esc(q.label)).join(" → ")}</span>` : ""}
    </div>
    ${bar(g.morale, 1)}
  </div>`;
}

function renderGroups() {
  const list = visibleGroups().slice().sort((a, b) => a.gid.localeCompare(b.gid));
  const btn = (k, label) =>
    `<button data-filter="${k}" class="${filter === k ? "on" : ""}">${label}</button>`;
  return `<div class="pad">
    <input id="search" placeholder="Search squads, characters or places…" value="${esc(query)}">
    <div class="filters">
      ${btn("all", "All")}${btn("travel", "Travelling")}${btn("working", "At a place")}
      ${btn("physical", "Physical")}${btn("combat", "Fighting")}
    </div>
    ${list.length ? list.map(groupCard).join("") : '<div class="empty">No matches</div>'}
  </div>`;
}

function memberBlock(m) {
  const cls = "member" + (m.leader ? " leader" : "") + (m.alive ? "" : " dead");
  // Names arrive once per snapshot in traitDefs/skillDefs; each NPC carries
  // only the values, in the same order.
  const tdefs = state.traitDefs || [];
  const sdefs = state.skillDefs || [];
  const traits = (m.traits || []).map((v, i) => {
    const d = tdefs[i] || { name: "?", key: "", effect: "" };
    const hi = v >= 0.66 ? " hi" : "";
    const bg = d.effect === "profile" ? " bg" : "";
    return `<div class="t${hi}${bg}" title="${esc(d.key)} · ${esc(d.effect)}">
      <span class="n">${esc(d.name)}</span><span class="v">${v.toFixed(2)}</span></div>`;
  }).join("");
  const skills = (m.skills || []).map((v, i) => {
    const d = sdefs[i] || { name: "?" };
    return `<div class="t${v >= 0.66 ? " hi" : ""}">
      <span class="n">${esc(d.name)}</span><span class="v">${v.toFixed(2)}</span></div>`;
  }).join("");
  const mem = (m.memories || []).slice().reverse().map(x =>
    `<div class="feedrow"><span class="k">${esc(x.kind)}</span>${esc(x.detail || "")}</div>`
  ).join("");

  return `<div class="${cls}">
    <div class="top">
      <div>
        <div class="nm">${esc(m.name)}${m.leader ? " ★" : ""}</div>
        <div class="rl">${esc(m.archetype_fi)} · level ${m.level} ${esc(m.level_name || "")}
          ${m.physical ? " · physical" : ""}${m.alive ? "" : " · dead"}</div>
      </div>
      <span class="pill">${esc(m.action_fi || m.action || "")}</span>
    </div>
    <div class="kv" style="margin-top:7px">
      <b>Health</b><span>${m.health}</span>
      <b>Stress</b><span>${m.stress.toFixed(2)} · ${esc(m.stress_fi)}${m.reaction ? ` <i style="color:#e8a060">(${esc(m.reaction)})</i>` : ""}</span>
      <b>Morale</b><span>${m.morale.toFixed(2)}</span>
      ${m.traumas ? `<b>Traumas</b><span>${esc(m.traumas)}</span>` : ""}
      <b>Experience</b><span>${(m.xp && m.xp.fights) || 0} fights ·
        ${Math.round(((m.xp && m.xp.distance) || 0) / 100000)} km</span>
    </div>
    <div class="section" style="margin:10px 0 0">
      <h2>Skills (12)</h2><div class="traitgrid">${skills}</div>
    </div>
    <div class="section" style="margin:10px 0 0">
      <h2>Personality traits (38)</h2><div class="traitgrid">${traits}</div>
      <div class="note">Faded traits are background personality: they
        have no action of their own in the decision scoring.</div>
    </div>
    ${mem ? `<div class="section" style="margin:10px 0 0"><h2>Memories</h2>${mem}</div>` : ""}
  </div>`;
}

function renderDetail() {
  if (!selected) return `<div class="pad"><div class="empty">Pick a squad on the map or in the list.</div></div>`;
  const g = state.groups.find(x => x.gid === selected.gid) || selected;
  const rel = (g.relations || []).map(r =>
    `<div class="feedrow"><span class="k">${esc(r.tier)}</span>${esc(r.gid)} (${r.value})</div>`
  ).join("");
  const hist = (g.history || []).slice().reverse()
    .map(h => `<div class="feedrow">${esc(h)}</div>`).join("");
  const STEP_FI = {
    BUILDING_DISCOVERY: "Building found",
    DOOR_DISCOVERY: "Door found",
    DOOR_APPROACH: "Walked to the door",
    DOOR_INTERACTION: "Door handled",
    INTERIOR_NAVIGATION: "Inside",
  };
  const proof = g.search_proof ? Object.entries(g.search_proof).map(([k, v]) =>
    `<div class="h"><div class="k">${esc(STEP_FI[k] || k)}</div>
      <div class="s ${v ? "OK" : "PENDING"}">${v ? "PROVEN" : "NOT PROVEN"}</div></div>`
  ).join("") : "";

  return `<div class="pad">
    <div class="section">
      <h2>${esc(g.gid)} · ${esc(g.class_fi)}</h2>
      <div class="kv">
        <b>State</b><span>${esc(g.intent || g.state)}</span>
        <b>Mood</b><span>${esc(g.mood_fi || "–")}${g.zombie_note ? " · " + esc(g.zombie_note) : ""}</span>
        <b>Destination</b><span>${esc(g.goal || "none chosen")}
          ${g.goal_kind ? `(${esc((POI_STYLE[g.goal_kind] || {}).fi || g.goal_kind)})` : ""}</span>
        <b>Queued</b><span>${(g.queue || []).length
          ? g.queue.map((q, i) => `${i + 1}. ${esc(q.label)} <i style="color:${(POI_STYLE[q.kind] || {}).c || "#ccc"}">${esc((POI_STYLE[q.kind] || {}).fi || q.kind)}</i>`).join("<br>")
          : "–"}</span>
        <b>Memory</b><span>${g.recent ?? 0} / ${g.class === "radiation_group" ? 2 : 10} places visited last</span>
        ${g.sweep_dir ? `<b>Krsko-sweep</b><span>area ${g.sweep_area ?? "–"} · direction ${g.sweep_dir > 0 ? "1→5" : "5→1"} · ${g.sweep_done ?? 0} % done</span>` : ""}
        <b>Route</b><span>${g.route_km || 0} km · ${esc(g.route_kind || "–")}
          · point ${g.route_index}</span>
        <b>Position</b><span>${g.x}, ${g.y} · ${esc(g.sector)}</span>
        <b>Distance state</b><span>${esc(g.lod)}${g.player_distance_m >= 0
          ? ` · player ${g.player_distance_m} m` : " · no player near"}</span>
        <b>Physical</b><span>${g.physical_members} / ${g.members_alive}</span>
        <b>Leader</b><span>${esc(g.leader || (g.leaderless ? "no leader" : "–"))}</span>
        <b>Morale</b><span>${g.morale} · cohesion ${g.cohesion}</span>
        <b>Squad stress</b><span>${g.stress}</span>
        <b>Strength</b><span>${g.power}</span>
        <b>Fatigue</b><span>${g.fatigue} / 100</span>
        <b>Supplies</b><span>${g.supply} / 100</span>
        <b>Travelled</b><span>${g.distance_km} km · ${g.journeys} journeys</span>
        <b>Move orders</b><span>${g.commands} · stalls ${g.stalls}</span>
        ${g.spawn_note ? `<b>Spawn</b><span class="s DEGRADED">${esc(g.spawn_note)}</span>` : ""}
      </div>
    </div>
    ${proof ? `<div class="section"><h2>Building search</h2>
      <div class="health">${proof}</div>
      <div class="note">${esc(g.search_note || "steps are marked only once the game confirms them")}</div></div>` : ""}
    ${rel ? `<div class="section"><h2>Relations to other squads</h2>${rel}</div>` : ""}
    ${hist ? `<div class="section"><h2>Squad history</h2>${hist}</div>` : ""}
    <div class="section">
      <h2>Members (${g.members_alive}/${g.members_total})</h2>
      ${(g.members || []).map(memberBlock).join("")}
    </div>
  </div>`;
}

function renderFeed() {
  const rows = (state.events || []).slice().reverse().map(e => {
    const d = new Date(e.t * 1000);
    const hh = String(d.getHours()).padStart(2, "0");
    const mm = String(d.getMinutes()).padStart(2, "0");
    const ss = String(d.getSeconds()).padStart(2, "0");
    return `<div class="feedrow"><time>${hh}:${mm}:${ss}</time>
      <span class="k">${esc(e.kind)}</span>${esc(e.subject)} ${esc(e.detail)}</div>`;
  }).join("");
  return `<div class="pad">${rows || '<div class="empty">No events yet</div>'}</div>`;
}

// The panel is rebuilt on every poll. Replacing identical HTML still makes the
// browser tear down and lay out hundreds of trait rows, so skip it.
let lastPanelHtml = "";
function renderPanel() {
  const el = document.getElementById("panel");
  const html = tab === "world" ? renderWorld()
    : tab === "groups" ? renderGroups()
    : tab === "detail" ? renderDetail()
    : renderFeed();
  if (html === lastPanelHtml) return;
  lastPanelHtml = html;
  const keep = el.scrollTop;
  el.innerHTML = html;
  el.scrollTop = keep;
  const s = document.getElementById("search");
  if (s) {
    s.addEventListener("input", e => { query = e.target.value.toLowerCase(); renderPanel(); draw(); });
  }
}

function renderLegend() {
  const seen = new Map();
  (state.groups || []).forEach(g => seen.set(g.class, g.class_fi));
  const rows = [...seen.entries()].map(([k, fi]) =>
    `<span class="row"><i class="sw" style="background:${classColor(k)}"></i>${esc(fi)}</span>`
  ).join("");
  const kinds = Object.entries(POI_STYLE).map(([k, st]) =>
    `<span class="row"><i class="sw poi ${st.shape}" style="background:${st.c}"></i>${esc(st.fi)}</span>`
  ).join("");
  document.getElementById("legend").innerHTML = (rows || "Waiting for squad data…") +
    (show.pois ? `<div class="lg2">${kinds}</div>` : "");
}

function renderHud() {
  const s = state.stats || {};
  document.getElementById("chipPop").innerHTML =
    `NPCs <b>${s.alive ?? 0}</b> · Squads <b>${s.groups ?? 0}</b>`;
  document.getElementById("chipPhys").innerHTML =
    `Physical <b>${s.physical ?? 0}</b> · Zoom <b>${view.scale.toFixed(2)}</b>`;
  document.getElementById("chipTick").textContent =
    `tick ${state.tick || 0} · ${state.uptime ? Math.round(state.uptime / 60) + " min" : "–"}`;
  document.getElementById("verLabel").textContent = state.version ? "v" + state.version : "–";
}

/* ---------------------------------------------------------------- polling */

async function poll() {
  try {
    const r = await fetch("api/state?t=" + Date.now(), { cache: "no-store" });
    if (!r.ok) throw new Error("HTTP " + r.status);
    const data = await r.json();
    state = data;
    pollFails = 0;
    if (data.waiting) {
      // The server answered, the mod has not written a snapshot yet.
      document.getElementById("chipLink").innerHTML =
        `<b style="color:#e8c25a">WAITING</b> · ${esc(data.reason || "no state yet")}`;
    } else {
      document.getElementById("chipLink").innerHTML =
        `<b style="color:#5fd67f">LIVE</b> · updated ${new Date().toLocaleTimeString()}`;
    }
    (data.groups || []).forEach(g => {
      let t = trails.get(g.gid);
      if (!t) { t = []; trails.set(g.gid, t); }
      const last = t[t.length - 1];
      if (!last || Math.hypot(last[0] - g.x, last[1] - g.y) > 1500) {
        t.push([g.x, g.y]);
        if (t.length > 400) t.shift();
      }
    });
    if (selected) {
      const live = data.groups.find(g => g.gid === selected.gid);
      if (live) selected = live;
    }
    renderHud(); renderLegend(); renderPanel(); draw();
    checkCommandResults();
  } catch (e) {
    pollFails++;
    lastError = String(e.message || e);
    document.getElementById("chipLink").innerHTML =
      `<b style="color:#f07070">OFFLINE</b> · ${esc(lastError)} ` +
      `· is START_LIVEMAP.bat running?`;
    if (pollFails === 1) draw();
  }
}

/* ----------------------------------------------------------------- input */

wrap.addEventListener("mousedown", e => {
  if (e.button !== 0) return;
  dragging = { x: e.clientX, y: e.clientY, ox: view.ox, oy: view.oy, moved: false };
  wrap.classList.add("dragging");
});
window.addEventListener("mousemove", e => {
  const r = canvas.getBoundingClientRect();
  if (dragging) {
    const dx = e.clientX - dragging.x, dy = e.clientY - dragging.y;
    if (Math.abs(dx) + Math.abs(dy) > 3) dragging.moved = true;
    view.ox = dragging.ox + dx;
    view.oy = dragging.oy + dy;
    lastInteraction = performance.now();
    draw();
    return;
  }
  const sx = e.clientX - r.left, sy = e.clientY - r.top;
  if (sx < 0 || sy < 0 || sx > r.width || sy > r.height) { hideTip(); return; }
  const w = screenToWorld(sx, sy);
  document.getElementById("chipCoords").textContent =
    `X ${Math.round(w.x)} / Y ${Math.round(w.y)} / ${sectorOf(w.x, w.y)}`;
  const g = pick(sx, sy);
  if (g) { showTip(g, e.clientX - r.left, e.clientY - r.top); return; }
  const p = show.pois ? pickPoi(sx, sy) : null;
  if (p) showPoiTip(p, sx, sy); else hideTip();
});
window.addEventListener("mouseup", e => {
  if (dragging && !dragging.moved) {
    const r = canvas.getBoundingClientRect();
    const g = pick(e.clientX - r.left, e.clientY - r.top);
    if (g) { selected = g; tab = "detail"; syncTabs(); renderPanel(); }
  }
  dragging = null;
  wrap.classList.remove("dragging");
});
wrap.addEventListener("wheel", e => {
  lastInteraction = performance.now();
  e.preventDefault();
  const r = canvas.getBoundingClientRect();
  zoomAt(e.clientX - r.left, e.clientY - r.top, e.deltaY < 0 ? 1.18 : 1 / 1.18);
  renderHud();
}, { passive: false });

/* ---------------------------------------------------------- context menu */

// Right click on the map: copy a SCUM admin teleport command for that spot,
// ready to paste into the in-game chat. Z 0 is what the community maps use;
// the game puts the player on the ground.
const ctxMenu = document.createElement("div");
ctxMenu.id = "ctxMenu";
wrap.appendChild(ctxMenu);
let toastTimer = null;

function copyText(text) {
  const done = () => showToast("Copied: " + text);
  if (navigator.clipboard && window.isSecureContext) {
    navigator.clipboard.writeText(text).then(done, () => fallbackCopy(text, done));
  } else fallbackCopy(text, done);
}
function fallbackCopy(text, done) {
  const ta = document.createElement("textarea");
  ta.value = text; ta.style.position = "fixed"; ta.style.opacity = "0";
  document.body.appendChild(ta); ta.select();
  let ok = false;
  try { ok = document.execCommand("copy"); } catch (e) {}
  ta.remove();
  if (ok) done(); else window.prompt("Copy the command:", text);
}
function showToast(text) {
  let t = document.getElementById("toast");
  if (!t) { t = document.createElement("div"); t.id = "toast"; wrap.appendChild(t); }
  t.textContent = text; t.style.display = "block";
  clearTimeout(toastTimer);
  toastTimer = setTimeout(() => { t.style.display = "none"; }, 2200);
}
function hideCtx() { ctxMenu.style.display = "none"; }

wrap.addEventListener("contextmenu", e => {
  e.preventDefault();
  const r = canvas.getBoundingClientRect();
  const sx = e.clientX - r.left, sy = e.clientY - r.top;
  const w = screenToWorld(sx, sy);
  const x = Math.round(w.x), y = Math.round(w.y);
  const tp = `#Teleport ${x} ${y} 0`;
  const g = pick(sx, sy);
  const gtp = g ? `#Teleport ${Math.round(g.x)} ${Math.round(g.y)} 0` : null;
  ctxMenu.dataset.x = x; ctxMenu.dataset.y = y;
  ctxMenu.innerHTML = `
    <div class="hd">${esc(sectorOf(w.x, w.y))} · X ${x} / Y ${y}</div>
    <button data-copy="${esc(tp)}">Copy teleport command</button>
    ${gtp ? `<button data-copy="${esc(gtp)}">Teleport to squad ${esc(g.gid)}</button>` : ""}
    <button data-copy="${x} ${y} 0">Copy coordinates</button>
    <div class="sep"></div>
    <button data-open-spawn="1">Spawn a squad here…</button>
    ${g ? `<button class="danger" data-remove="${esc(g.gid)}">Remove squad ${esc(g.gid)}</button>` : ""}
    <div class="spawnform" id="spawnForm" style="display:none"></div>`;
  ctxMenu.style.display = "block";
  ctxMenu.style.left = Math.min(sx, wrap.clientWidth - 250) + "px";
  ctxMenu.style.top = Math.max(4, Math.min(sy, wrap.clientHeight - 330)) + "px";
  hideTip();
});
ctxMenu.addEventListener("mousedown", e => e.stopPropagation());
ctxMenu.addEventListener("click", e => {
  const b = e.target.closest("[data-copy]");
  if (b) { copyText(b.dataset.copy); hideCtx(); return; }
  if (e.target.closest("[data-open-spawn]")) { openSpawnForm(); return; }
  const r = e.target.closest("[data-remove]");
  if (r) {
    if (confirm(`Remove squad ${r.dataset.remove} for good?`)) {
      sendCommand({ op: "remove", gid: r.dataset.remove });
    }
    hideCtx();
    return;
  }
  if (e.target.closest("[data-do-spawn]")) {
    const cls = document.getElementById("spawnClass").value;
    const size = document.getElementById("spawnSize").value;
    sendCommand({ op: "spawn", class: cls, size, x: ctxMenu.dataset.x, y: ctxMenu.dataset.y });
    hideCtx();
  }
});
ctxMenu.addEventListener("change", e => {
  if (e.target.id === "spawnClass") fillSizes();
});

/* ------------------------------------------------- spawn / remove squads */

// The server hands its session token only to this page; commands carry it.
let cmdToken = null;
const pendingCmds = new Map();
async function fetchToken() {
  try {
    const r = await fetch("api/status?t=" + Date.now(), { cache: "no-store" });
    const j = await r.json();
    cmdToken = j.token || null;
  } catch (e) { cmdToken = null; }
}
fetchToken();

function classDefs() {
  return (state.classDefs && state.classDefs.length) ? state.classDefs : [];
}

function openSpawnForm() {
  const f = document.getElementById("spawnForm");
  const defs = classDefs();
  if (!defs.length) { showToast("No class data yet - wait until the map is LIVE"); return; }
  const last = localStorageGet("spawnClass") || "police_patrol";
  f.innerHTML = `
    <label>Squad type<select id="spawnClass">${defs.map(d =>
      `<option value="${esc(d.key)}"${d.key === last ? " selected" : ""}>${esc(d.fi)}</option>`).join("")}</select></label>
    <label>Size<select id="spawnSize"></select></label>
    <button class="go" data-do-spawn="1">Spawn</button>`;
  f.style.display = "block";
  fillSizes();
}

function fillSizes() {
  const cls = document.getElementById("spawnClass");
  const sel = document.getElementById("spawnSize");
  if (!cls || !sel) return;
  const d = classDefs().find(x => x.key === cls.value) || { min: 1, max: 5 };
  let html = "";
  for (let i = d.min; i <= d.max; i++) html += `<option${i === d.max ? " selected" : ""}>${i}</option>`;
  sel.innerHTML = html;
  localStorageSet("spawnClass", cls.value);
}

function localStorageGet(k) { try { return localStorage.getItem("tesles." + k); } catch (e) { return null; } }
function localStorageSet(k, v) { try { localStorage.setItem("tesles." + k, v); } catch (e) {} }

async function sendCommand(params) {
  if (!cmdToken) await fetchToken();
  if (!cmdToken) { showToast("The map server does not answer - is START_LIVEMAP.bat running?"); return; }
  const q = new URLSearchParams(Object.assign({}, params, { token: cmdToken }));
  try {
    const r = await fetch("api/command?" + q.toString(), { cache: "no-store" });
    const j = await r.json();
    if (j.ok) {
      pendingCmds.set(j.id, Date.now());
      showToast("Request sent to the mod…");
    } else {
      if ((j.error || "").includes("token")) cmdToken = null;
      showToast("Failed: " + (j.error || "unknown error"));
    }
  } catch (e) {
    showToast("No connection to the map server");
  }
}

// The mod reports each command's outcome in the live state.
function checkCommandResults() {
  for (const r of (state.commandResults || [])) {
    if (pendingCmds.has(r.id)) {
      pendingCmds.delete(r.id);
      showToast((r.ok ? "✔ " : "✖ ") + r.text);
    }
  }
  for (const [id, t] of pendingCmds) {
    if (Date.now() - t > 20000) {
      pendingCmds.delete(id);
      showToast("The mod did not answer - is the server running?");
    }
  }
}
window.addEventListener("mousedown", e => { if (e.button !== 2) hideCtx(); });
window.addEventListener("keydown", e => { if (e.key === "Escape") hideCtx(); });
wrap.addEventListener("wheel", hideCtx, { passive: true });

function pick(sx, sy) {
  let best = null, bestD = 18;
  for (const g of visibleGroups()) {
    const p = worldToScreen(g.x, g.y);
    const d = Math.hypot(p.x - sx, p.y - sy);
    if (d < bestD) { best = g; bestD = d; }
  }
  return best;
}

function pickPoi(sx, sy) {
  let best = null, bestD = 10;
  const z = view.scale;
  for (const p of POIS) {
    if ((p.k === "HUNTING" && z < 0.75) || (p.k === "VILLAGE" && z < 0.45)) continue;
    const s = worldToScreen(p.x, p.y);
    const d = Math.hypot(s.x - sx, s.y - sy);
    if (d < bestD) { best = p; bestD = d; }
  }
  return best;
}

function showPoiTip(p, x, y) {
  const st = POI_STYLE[p.k] || {};
  const heading = (state.groups || []).filter(g =>
    g.goal_id === p.id || (g.queue || []).some(q => q.id === p.id)).map(g => g.gid);
  tipEl.innerHTML = `<b>${esc(p.n)}</b><br>
    <span style="color:${st.c}">${esc(st.fi || p.k)}</span> · ${esc(sectorOf(p.x, p.y))}<br>
    ${heading.length ? "Coming: " + heading.map(esc).join(", ") : "No squads heading here"}`;
  tipEl.style.display = "block";
  tipEl.style.left = Math.min(x + 16, wrap.clientWidth - 330) + "px";
  tipEl.style.top = Math.min(y + 16, wrap.clientHeight - 120) + "px";
}

function showTip(g, x, y) {
  const lead = (g.members || []).find(m => m.leader);
  tipEl.innerHTML = `<b>${esc(g.gid)} · ${esc(g.class_fi)}</b><br>
    ${g.members_alive}/${g.members_total} NPCs · level ${g.level} ·
    ${g.physical_members > 0 ? "physical" : "virtual"}<br>
    ${esc(g.intent || g.state)}${g.mood && g.mood !== "CALM" ? " · <b>" + esc(g.mood_fi) + "</b>" : ""}<br>
    ${g.sweep_dir ? `Krsko: area ${g.sweep_area ?? "–"} (${g.sweep_dir > 0 ? "1→5" : "5→1"}), ${g.sweep_done ?? 0} %<br>` : ""}
    ${(g.queue || []).length ? "Queue: " + g.queue.map(q => esc(q.label)).join(" → ") + "<br>" : ""}
    ${lead ? "Leader: " + esc(lead.name) + " (" + esc(lead.archetype_fi) + ")<br>" : ""}
    Morale ${g.morale} · stress ${g.stress} · strength ${g.power}`;
  tipEl.style.display = "block";
  tipEl.style.left = Math.min(x + 16, wrap.clientWidth - 330) + "px";
  tipEl.style.top = Math.min(y + 16, wrap.clientHeight - 120) + "px";
}
function hideTip() { tipEl.style.display = "none"; }

function syncTabs() {
  document.querySelectorAll(".tabs button").forEach(b =>
    b.classList.toggle("on", b.dataset.tab === tab));
}
document.querySelectorAll(".tabs button").forEach(b => {
  b.addEventListener("click", () => { tab = b.dataset.tab; syncTabs(); renderPanel(); });
});
document.getElementById("panel").addEventListener("click", e => {
  const card = e.target.closest(".card");
  if (card) {
    selected = state.groups.find(g => g.gid === card.dataset.gid) || null;
    tab = "detail"; syncTabs(); renderPanel(); draw();
    return;
  }
  const f = e.target.closest("[data-filter]");
  if (f) { filter = f.dataset.filter; renderPanel(); draw(); }
});

const toggle = (id, key) => document.getElementById(id).addEventListener("click", e => {
  show[key] = !show[key];
  e.currentTarget.classList.toggle("on", show[key]);
  draw();
});
toggle("btnRoutes", "routes");
toggle("btnTrails", "trails");
toggle("btnLabels", "labels");
toggle("btnGrid", "grid");
toggle("btnPois", "pois");
toggle("btnQueue", "queue");
document.getElementById("btnPois").addEventListener("click", renderLegend);
document.getElementById("btnFit").addEventListener("click", () => { fit(); renderHud(); });

window.addEventListener("resize", resize);
resize();
syncTabs();
renderPanel();
poll();
setInterval(poll, 2000);
