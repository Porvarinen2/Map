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

const STATE_FI = {
  IDLE: "Odottaa", TRAVEL: "Matkalla", SEARCH: "Tutkii rakennuksia",
  HUNT: "Metsästää", CAMP: "Leiriytyy", PATROL: "Partioi", REST: "Lepää",
  HOLD: "Vartioi aluetta", COMBAT: "Taistelee", RETREAT: "Vetäytyy",
};

const canvas = document.getElementById("map");
const ctx = canvas.getContext("2d");
const wrap = document.getElementById("mapWrap");
const tipEl = document.getElementById("tip");

let state = { groups: [], events: [], health: [], stats: {}, calibration: CAL_DEFAULT };
let selected = null, selectedMember = null;
let tab = "world", filter = "all", query = "";
let view = { scale: 0, ox: 0, oy: 0 };
let show = { routes: true, trails: true, labels: false, grid: true };
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
mapImg.onload = () => {
  mapReady = true; mapMissing = false;
  if (!view.scale) fit(); else draw();
};
mapImg.onerror = () => {
  mapCandidate++;
  if (mapCandidate < MAP_CANDIDATES.length) {
    mapImg.src = MAP_CANDIDATES[mapCandidate];
  } else {
    mapMissing = true;
    lastError = "karttakuvaa ei löytynyt kansiosta livemap\\map\\";
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
  view.scale = Math.max(minScale, Math.min(40, view.scale * factor));
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
    drawTiles(r, s);
  } else if (mapReady && mapImg.naturalWidth) {
    const o = imgToScreen(0, 0);
    ctx.imageSmoothingEnabled = view.scale < 2;
    ctx.drawImage(mapImg, o.x, o.y, s.w * view.scale, s.h * view.scale);
  } else if (mapMissing) {
    drawMissingMap(r);
  } else {
    ctx.fillStyle = "#6d7684";
    ctx.font = "13px Inter, sans-serif";
    ctx.fillText("Ladataan karttaa…", 20, 30);
  }
}

// The grid alone looks like a broken page; say what is actually wrong.
function drawMissingMap(r) {
  const lines = [
    "Karttakuvaa ei löytynyt.",
    "",
    "Tallenna kartta tiedostoksi  livemap\\map\\scum_map.png",
    "tai aja SETUP_HIRES_MAP.bat, joka luo sen tarkasta kartasta.",
    "",
    "Ryhmien sijainnit piirtyvät silti ruudukkoon.",
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
  let best = tiles.levels[0], bestErr = Infinity;
  for (const lv of tiles.levels) {
    const need = Math.abs(Math.log2((lv.width / s.w) / view.scale));
    if (need < bestErr) { bestErr = need; best = lv; }
  }
  const k = view.scale * (s.w / best.width);
  const ts = best.tile;
  const x0 = Math.max(0, Math.floor((-view.ox) / (ts * k)));
  const y0 = Math.max(0, Math.floor((-view.oy) / (ts * k)));
  const x1 = Math.min(best.cols - 1, Math.ceil((r.width - view.ox) / (ts * k)));
  const y1 = Math.min(best.rows - 1, Math.ceil((r.height - view.oy) / (ts * k)));
  ctx.imageSmoothingEnabled = true;
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
        ctx.drawImage(img, view.ox + tx * ts * k, view.oy + ty * ts * k,
                      ts * k, ts * k);
      }
    }
  }
}

function drawGrid() {
  const s = mapSize();
  ctx.save();
  ctx.strokeStyle = "rgba(255,255,255,.13)";
  ctx.lineWidth = 1;
  ctx.font = "11px Inter, sans-serif";
  ctx.fillStyle = "rgba(255,255,255,.35)";
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

function colorFor(g) { return CLASS_COLOR[g.class] || "#d8dde4"; }

function drawRoute(g) {
  if (!g.route || g.route.length < 2) return;
  ctx.save();
  const isSel = selected && g.gid === selected.gid;
  ctx.strokeStyle = isSel ? "rgba(255,206,130,.98)" : "rgba(224,182,115,.62)";
  ctx.lineWidth = isSel ? 2.6 : 1.5;
  ctx.setLineDash(isSel ? [] : [7, 5]);
  ctx.shadowColor = "rgba(0,0,0,.8)";
  ctx.shadowBlur = 3;
  ctx.beginPath();
  g.route.forEach((p, i) => {
    const s = worldToScreen(p[0], p[1]);
    if (i === 0) ctx.moveTo(s.x, s.y); else ctx.lineTo(s.x, s.y);
  });
  ctx.stroke();
  const end = g.route[g.route.length - 1];
  const e = worldToScreen(end[0], end[1]);
  ctx.setLineDash([]);
  ctx.shadowBlur = 0;
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
  ctx.strokeStyle = colorFor(g) + (g === selected ? "cc" : "55");
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
  if (g.state === "COMBAT") {
    ctx.beginPath();
    ctx.arc(p.x, p.y, r + 10, 0, Math.PI * 2);
    ctx.strokeStyle = "rgba(240,112,112,.8)";
    ctx.lineWidth = 2;
    ctx.stroke();
  }
  ctx.beginPath();
  ctx.arc(p.x, p.y, r, 0, Math.PI * 2);
  ctx.fillStyle = col;
  ctx.fill();
  ctx.lineWidth = isSel ? 2.4 : 1;
  ctx.strokeStyle = isSel ? "#fff" : "rgba(0,0,0,.65)";
  ctx.stroke();

  // Member count badge
  ctx.font = "bold 10px Inter, sans-serif";
  ctx.textAlign = "center";
  ctx.textBaseline = "middle";
  ctx.fillStyle = "#07080a";
  ctx.fillText(String(g.members_alive), p.x, p.y + 0.5);

  if (show.labels || isSel) {
    const label = g.gid + "  " + (STATE_FI[g.state] || g.state);
    ctx.font = "11px Inter, sans-serif";
    ctx.textAlign = "left";
    const w = ctx.measureText(label).width;
    ctx.fillStyle = "rgba(7,8,10,.82)";
    ctx.fillRect(p.x + r + 5, p.y - 8, w + 8, 16);
    ctx.fillStyle = "#e8eaee";
    ctx.fillText(label, p.x + r + 9, p.y);
  }
  ctx.restore();
}

function draw() {
  const r = canvas.getBoundingClientRect();
  drawBase(r);
  if (show.grid) drawGrid();

  const list = visibleGroups();
  if (show.trails) list.forEach(drawTrail);
  if (show.routes) list.forEach(g => { if (g !== selected) drawRoute(g); });
  list.forEach(g => { if (!selected || g.gid !== selected.gid) drawGroup(g); });
  if (selected) {
    const live = state.groups.find(g => g.gid === selected.gid);
    if (live) { if (show.routes) drawRoute(live); drawGroup(live); }
  }
  (state.players || []).forEach(drawPlayer);
}

// A player: white diamond with a dashed ring at the materialise distance, so
// it is obvious how close a group has to be before it becomes real in game.
function drawPlayer(p) {
  const s = worldToScreen(p.x, p.y);
  const lod = state.lod || {};
  const ring = worldToScreen(p.x + (lod.materialize_m || 600) * 100, p.y);
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
  const label = "PELAAJA" + (p.nearest_m != null
    ? `  lähin ryhmä ${(p.nearest_m / 1000).toFixed(1)} km` : "");
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
      <div class="h"><div><div class="k">Pelaaja kartalla</div>
        <div class="d">lähin ryhmä ${esc(p.nearest_gid || "-")} · ${
          p.nearest_m != null ? (p.nearest_m / 1000).toFixed(2) + " km" : "-"} ·
          fyysiseksi alle ${esc(lod.materialize_m || 600)} m</div></div>
        <div class="s OK">ONLINE</div></div>`).join("");
  const playersSection = `
    <div class="section"><h2>Pelaajat</h2><div class="health">${players ||
      '<div class="h"><div><div class="k">Ei pelaajia</div><div class="d">Pelaaja näkyy ' +
      '30 s liittymisen jälkeen.</div></div><div class="s PENDING">-</div></div>'}</div></div>`;
  const waiting = state.waiting ? `
    <div class="section">
      <h2>Odottaa dataa</h2>
      <div class="health">
        <div class="h"><div><div class="k">${esc(state.reason || "")}</div>
          <div class="d">Mod-output: ${esc(state.output || "tuntematon")}</div></div>
          <div class="s PENDING">ODOTTAA</div></div>
      </div>
      <div class="note">
        1. Onko SCUM-palvelin kaynnissa? Mod kaynnistyy 25 s viiveella.<br>
        2. Katso mod-kansion output\\boot.log - se kertoo mihin asti mod paasi.<br>
        3. Jos boot.log puuttuu kokonaan, UE4SS ei lataa modia: tarkista
           Mods\\mods.txt rivi "TeslesNPCOverhaul : 1" ja UE4SS.log.<br>
        4. DIAGNOSE.bat kerää nama tiedot yhteen.
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
      <h2>Populaatio</h2>
      <div class="grid2">
        <div class="stat"><div class="v">${s.alive ?? 0}</div><div class="l">NPC elossa</div></div>
        <div class="stat"><div class="v">${s.groups ?? 0}</div><div class="l">Ryhmää</div></div>
        <div class="stat"><div class="v">${s.physical ?? 0}</div><div class="l">Fyysisiä</div></div>
        <div class="stat"><div class="v">${s.arrivals ?? 0}</div><div class="l">Saapumisia</div></div>
      </div>
    </div>

    <div class="section">
      <h2>Osajärjestelmät</h2>
      <div class="health">${health || '<div class="empty">Ei tietoja</div>'}</div>
      <div class="note">Tila kertoo vain mitä palvelimella on todennettu.
        OK spawn-katalogissa tarkoittaa löytynyttä luokkaa, ei onnistunutta
        spawnia, liikettä tai taistelua.</div>
    </div>

    <div class="section">
      <h2>Reititys ja liike</h2>
      <div class="kv">
        <b>Reittejä</b><span>${s.routes ?? 0} (epäonnistui ${s.route_fail ?? 0})</span>
        <b>Liikekäskyjä</b><span>${s.commands ?? 0}</span>
        <b>Uudelleenreititys</b><span>${s.replans ?? 0}</span>
        <b>Spawnit</b><span>${s.spawns ?? 0} (epäonnistui ${s.spawn_fail ?? 0})</span>
        <b>Kohtaamisia</b><span>${s.contacts ?? 0}</span>
        <b>Kuolemia</b><span>${s.deaths ?? 0}</span>
      </div>
    </div>

    <div class="section">
      <h2>Etäisyystilat</h2>
      <div class="kv">
        <b>FULL</b><span>≤ ${lod.full_m ?? "–"} m</span>
        <b>LIGHT</b><span>≤ ${lod.light_m ?? "–"} m</span>
        <b>Materialisointi</b><span>≤ ${lod.materialize_m ?? "–"} m</span>
        <b>Virtualisointi</b><span>&gt; ${lod.virtualize_m ?? "–"} m</span>
      </div>
      <div class="note">Kartan piste on virtuaalinen sijainti, ellei ryhmä ole
        merkitty fyysiseksi. Vihreä rengas = ryhmällä on pelissä oikea hahmo.</div>
    </div>
  </div>`;
}

function groupCard(g) {
  const sel = selected && selected.gid === g.gid ? " sel" : "";
  const phys = g.physical_members > 0
    ? `<span class="pill phys">FYYSINEN ${g.physical_members}</span>`
    : `<span class="pill virt">VIRTUAALINEN</span>`;
  return `<div class="card${sel}" data-gid="${esc(g.gid)}">
    <div class="top">
      <span class="name" style="color:${colorFor(g)}">${esc(g.gid)}</span>
      ${phys}
    </div>
    <div class="meta">
      ${esc(g.class_fi)} · taso ${g.level} · ${g.members_alive}/${g.members_total} NPC · ${esc(g.sector)}<br>
      ${esc(g.intent || STATE_FI[g.state] || g.state)}
      ${g.route_km ? ` · ${g.route_km} km (${esc(g.route_kind || "")})` : ""}
    </div>
    ${bar(g.morale, 1)}
  </div>`;
}

function renderGroups() {
  const list = visibleGroups().slice().sort((a, b) => a.gid.localeCompare(b.gid));
  const btn = (k, label) =>
    `<button data-filter="${k}" class="${filter === k ? "on" : ""}">${label}</button>`;
  return `<div class="pad">
    <input id="search" placeholder="Hae ryhmää, hahmoa tai kohdetta…" value="${esc(query)}">
    <div class="filters">
      ${btn("all", "Kaikki")}${btn("travel", "Matkalla")}${btn("working", "Kohteessa")}
      ${btn("physical", "Fyysiset")}${btn("combat", "Taistelu")}
    </div>
    ${list.length ? list.map(groupCard).join("") : '<div class="empty">Ei osumia</div>'}
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
        <div class="rl">${esc(m.archetype_fi)} · taso ${m.level} ${esc(m.level_name || "")}
          ${m.physical ? " · fyysinen" : ""}${m.alive ? "" : " · kuollut"}</div>
      </div>
      <span class="pill">${esc(m.action_fi || m.action || "")}</span>
    </div>
    <div class="kv" style="margin-top:7px">
      <b>Terveys</b><span>${m.health}</span>
      <b>Stressi</b><span>${m.stress.toFixed(2)} · ${esc(m.stress_fi)}</span>
      <b>Moraali</b><span>${m.morale.toFixed(2)}</span>
      ${m.traumas ? `<b>Traumat</b><span>${esc(m.traumas)}</span>` : ""}
      <b>Kokemus</b><span>${(m.xp && m.xp.fights) || 0} taistelua ·
        ${Math.round(((m.xp && m.xp.distance) || 0) / 100000)} km</span>
    </div>
    <div class="section" style="margin:10px 0 0">
      <h2>Taidot (12)</h2><div class="traitgrid">${skills}</div>
    </div>
    <div class="section" style="margin:10px 0 0">
      <h2>Luonteenpiirteet (38)</h2><div class="traitgrid">${traits}</div>
      <div class="note">Haalennetut piirteet ovat taustapersoonallisuutta:
        niillä ei ole omaa toimintoa päätöspisteytyksessä.</div>
    </div>
    ${mem ? `<div class="section" style="margin:10px 0 0"><h2>Muistot</h2>${mem}</div>` : ""}
  </div>`;
}

function renderDetail() {
  if (!selected) return `<div class="pad"><div class="empty">Valitse ryhmä kartalta tai listasta.</div></div>`;
  const g = state.groups.find(x => x.gid === selected.gid) || selected;
  const rel = (g.relations || []).map(r =>
    `<div class="feedrow"><span class="k">${esc(r.tier)}</span>${esc(r.gid)} (${r.value})</div>`
  ).join("");
  const hist = (g.history || []).slice().reverse()
    .map(h => `<div class="feedrow">${esc(h)}</div>`).join("");
  const STEP_FI = {
    BUILDING_DISCOVERY: "Rakennus loydetty",
    DOOR_DISCOVERY: "Ovi loydetty",
    DOOR_APPROACH: "Ovelle kuljettu",
    DOOR_INTERACTION: "Ovi kasitelty",
    INTERIOR_NAVIGATION: "Sisapisteet",
  };
  const proof = g.search_proof ? Object.entries(g.search_proof).map(([k, v]) =>
    `<div class="h"><div class="k">${esc(STEP_FI[k] || k)}</div>
      <div class="s ${v ? "OK" : "PENDING"}">${v ? "TODENNETTU" : "EI TODISTETTU"}</div></div>`
  ).join("") : "";

  return `<div class="pad">
    <div class="section">
      <h2>${esc(g.gid)} · ${esc(g.class_fi)}</h2>
      <div class="kv">
        <b>Tila</b><span>${esc(g.intent || g.state)}</span>
        <b>Kohde</b><span>${esc(g.goal || "ei valittua kohdetta")}
          ${g.goal_kind ? `(${esc(g.goal_kind)})` : ""}</span>
        <b>Reitti</b><span>${g.route_km || 0} km · ${esc(g.route_kind || "–")}
          · piste ${g.route_index}</span>
        <b>Sijainti</b><span>${g.x}, ${g.y} · ${esc(g.sector)}</span>
        <b>Etäisyystila</b><span>${esc(g.lod)}${g.player_distance_m >= 0
          ? ` · pelaaja ${g.player_distance_m} m` : " · ei pelaajaa lähellä"}</span>
        <b>Fyysisiä</b><span>${g.physical_members} / ${g.members_alive}</span>
        <b>Johtaja</b><span>${esc(g.leader || (g.leaderless ? "ei johtajaa" : "–"))}</span>
        <b>Moraali</b><span>${g.morale} · koheesio ${g.cohesion}</span>
        <b>Ryhmästressi</b><span>${g.stress}</span>
        <b>Voima</b><span>${g.power}</span>
        <b>Väsymys</b><span>${g.fatigue} / 100</span>
        <b>Huoltovara</b><span>${g.supply} / 100</span>
        <b>Matkaa</b><span>${g.distance_km} km · ${g.journeys} matkaa</span>
        <b>Liikekäskyt</b><span>${g.commands} · jumitukset ${g.stalls}</span>
        ${g.spawn_note ? `<b>Spawn</b><span class="s DEGRADED">${esc(g.spawn_note)}</span>` : ""}
      </div>
    </div>
    ${proof ? `<div class="section"><h2>Rakennushaku</h2>
      <div class="health">${proof}</div>
      <div class="note">${esc(g.search_note || "vaiheet merkitaan vasta kun peli vahvistaa ne")}</div></div>` : ""}
    ${rel ? `<div class="section"><h2>Suhteet muihin ryhmiin</h2>${rel}</div>` : ""}
    ${hist ? `<div class="section"><h2>Ryhmän historia</h2>${hist}</div>` : ""}
    <div class="section">
      <h2>Jäsenet (${g.members_alive}/${g.members_total})</h2>
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
  return `<div class="pad">${rows || '<div class="empty">Ei tapahtumia vielä</div>'}</div>`;
}

function renderPanel() {
  const el = document.getElementById("panel");
  const keep = el.scrollTop;
  el.innerHTML = tab === "world" ? renderWorld()
    : tab === "groups" ? renderGroups()
    : tab === "detail" ? renderDetail()
    : renderFeed();
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
    `<span class="row"><i class="sw" style="background:${CLASS_COLOR[k] || "#ccc"}"></i>${esc(fi)}</span>`
  ).join("");
  document.getElementById("legend").innerHTML = rows ||
    "Odotetaan ryhmätietoja…";
}

function renderHud() {
  const s = state.stats || {};
  document.getElementById("chipPop").innerHTML =
    `NPC <b>${s.alive ?? 0}</b> · Ryhmät <b>${s.groups ?? 0}</b>`;
  document.getElementById("chipPhys").innerHTML =
    `Fyysisiä <b>${s.physical ?? 0}</b> · Zoom <b>${view.scale.toFixed(2)}</b>`;
  document.getElementById("chipTick").textContent =
    `tick ${state.tick || 0} · ${state.uptime ? Math.round(state.uptime / 60) + " min" : "–"}`;
  document.getElementById("verLabel").textContent = state.version || "–";
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
        `<b style="color:#e8c25a">ODOTTAA</b> · ${esc(data.reason || "ei tilatietoa")}`;
    } else {
      document.getElementById("chipLink").innerHTML =
        `<b style="color:#5fd67f">LIVE</b> · päivitetty ${new Date().toLocaleTimeString()}`;
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
  } catch (e) {
    pollFails++;
    lastError = String(e.message || e);
    document.getElementById("chipLink").innerHTML =
      `<b style="color:#f07070">OFFLINE</b> · ${esc(lastError)} ` +
      `· onko START_LIVEMAP.bat auki?`;
    if (pollFails === 1) draw();
  }
}

/* ----------------------------------------------------------------- input */

wrap.addEventListener("mousedown", e => {
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
    draw();
    return;
  }
  const sx = e.clientX - r.left, sy = e.clientY - r.top;
  if (sx < 0 || sy < 0 || sx > r.width || sy > r.height) { hideTip(); return; }
  const w = screenToWorld(sx, sy);
  document.getElementById("chipCoords").textContent =
    `X ${Math.round(w.x)} / Y ${Math.round(w.y)} / ${sectorOf(w.x, w.y)}`;
  const g = pick(sx, sy);
  if (g) showTip(g, e.clientX - r.left, e.clientY - r.top); else hideTip();
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
  e.preventDefault();
  const r = canvas.getBoundingClientRect();
  zoomAt(e.clientX - r.left, e.clientY - r.top, e.deltaY < 0 ? 1.18 : 1 / 1.18);
  renderHud();
}, { passive: false });

function pick(sx, sy) {
  let best = null, bestD = 18;
  for (const g of visibleGroups()) {
    const p = worldToScreen(g.x, g.y);
    const d = Math.hypot(p.x - sx, p.y - sy);
    if (d < bestD) { best = g; bestD = d; }
  }
  return best;
}

function showTip(g, x, y) {
  const lead = (g.members || []).find(m => m.leader);
  tipEl.innerHTML = `<b>${esc(g.gid)} · ${esc(g.class_fi)}</b><br>
    ${g.members_alive}/${g.members_total} NPC · taso ${g.level} ·
    ${g.physical_members > 0 ? "fyysinen" : "virtuaalinen"}<br>
    ${esc(g.intent || g.state)}<br>
    ${lead ? "Johtaja: " + esc(lead.name) + " (" + esc(lead.archetype_fi) + ")<br>" : ""}
    Moraali ${g.morale} · stressi ${g.stress} · voima ${g.power}`;
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
document.getElementById("btnFit").addEventListener("click", () => { fit(); renderHud(); });

window.addEventListener("resize", resize);
resize();
syncTabs();
renderPanel();
poll();
setInterval(poll, 2000);
