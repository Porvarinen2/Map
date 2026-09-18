'use strict';

const canvas=document.getElementById('map');
const ctx=canvas.getContext('2d');
const panel=document.getElementById('details');
const healthEl=document.getElementById('health');
const stats=document.getElementById('stats');
const conn=document.getElementById('conn');
const menu=document.getElementById('context');
const toast=document.getElementById('toast');
const zoomValue=document.getElementById('zoomValue');

let snap={npcs:[],groups:[],zombies:[],players:[],health:{}};
let cfg={
  minX:-750000,maxX:750000,minY:-750000,maxY:750000,defaultZ:30000,
  rows:['D','C','B','A','Z'],columns:['4','3','2','1','0'],
  tiles:{enabled:false,tileSize:512,minZoom:0,maxZoom:5,imageWidth:14481,imageHeight:14481,format:'jpg',pathTemplate:'map/tiles/{z}/{x}_{y}.jpg',levels:{}}
};
let selected=null;
let contextWorld=null;
let markerCache=[];
let view={centerX:0,centerY:0,zoom:0,initialized:false};
let pointerState=null;
const tileCache=new Map();

function mapWidth(){return cfg.maxX-cfg.minX}
function mapHeight(){return cfg.maxY-cfg.minY}
function rect(){return canvas.getBoundingClientRect()}
function clamp(v,min,max){return Math.max(min,Math.min(max,v))}
function esc(s){return String(s??'').replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]))}
function pct(v){return Math.round((v||0)*100)}
function groupFor(n){return snap.groups.find(g=>g.groupId===n.groupId)}

function ensureViewInitialized(force=false){
  if(view.initialized&&!force)return;
  view.centerX=(cfg.minX+cfg.maxX)/2;
  view.centerY=(cfg.minY+cfg.maxY)/2;
  view.zoom=clamp(Math.round(view.zoom||0), cfg.tiles?.minZoom??0, cfg.tiles?.maxZoom??5);
  view.initialized=true;
  clampView();
  updateZoomLabel();
}

function pixelsPerWorld(){
  const r=rect();
  const base=Math.min(r.width/mapWidth(), r.height/mapHeight());
  return base*Math.pow(2,view.zoom);
}

function clampView(){
  const r=rect();
  const ppw=pixelsPerWorld()||1;
  const halfW=r.width/(2*ppw);
  const halfH=r.height/(2*ppw);
  if(halfW*2>=mapWidth()) view.centerX=(cfg.minX+cfg.maxX)/2;
  else view.centerX=clamp(view.centerX,cfg.minX+halfW,cfg.maxX-halfW);
  if(halfH*2>=mapHeight()) view.centerY=(cfg.minY+cfg.maxY)/2;
  else view.centerY=clamp(view.centerY,cfg.minY+halfH,cfg.maxY-halfH);
}

function worldToScreen(x,y){
  const r=rect();
  const ppw=pixelsPerWorld();
  return {x:(view.centerX-x)*ppw+r.width/2,y:(view.centerY-y)*ppw+r.height/2};
}
function screenToWorld(px,py){
  const r=rect();
  const ppw=pixelsPerWorld();
  return {x:view.centerX-(px-r.width/2)/ppw,y:view.centerY-(py-r.height/2)/ppw};
}
function worldFracX(x){return (cfg.maxX-x)/mapWidth()}
function worldFracY(y){return (cfg.maxY-y)/mapHeight()}

function resize(){
  const r=rect();
  const d=window.devicePixelRatio||1;
  canvas.width=Math.floor(r.width*d);
  canvas.height=Math.floor(r.height*d);
  ctx.setTransform(d,0,0,d,0,0);
  if(view.initialized)clampView();
  draw();
}
addEventListener('resize',resize);

function tileUrl(z,x,y){
  const tpl=cfg.tiles?.pathTemplate||'';
  return tpl.replace('{z}',z).replace('{x}',x).replace('{y}',y);
}
function getTile(z,x,y){
  const key=`${z}/${x}/${y}`;
  let entry=tileCache.get(key);
  if(entry)return entry;
  const img=new Image();
  entry={img,loaded:false,error:false};
  img.onload=()=>{entry.loaded=true; draw();};
  img.onerror=()=>{entry.error=true; draw();};
  img.src=tileUrl(z,x,y);
  tileCache.set(key,entry);
  return entry;
}
function getSortedTileLevels(){
  return Object.entries(cfg.tiles?.levels||{}).map(([z,level])=>({z:Number(z),...level})).sort((a,b)=>a.z-b.z);
}
function selectTileLevel(){
  const levels=getSortedTileLevels();
  if(!levels.length)return null;
  const fullMapScreenPx=Math.max(mapWidth()*pixelsPerWorld(), mapHeight()*pixelsPerWorld())*(window.devicePixelRatio||1);
  for(const level of levels){ if(level.width>=fullMapScreenPx||level.height>=fullMapScreenPx) return level; }
  return levels[levels.length-1];
}
function drawTileLayer(level,{placeholder=false,pad=0}={}){
  if(!cfg.tiles?.enabled||!level)return false;
  const tiles=cfg.tiles;
  const r=rect(),w=r.width,h=r.height;
  const tl=screenToWorld(0,0), br=screenToWorld(w,h);
  const minFx=clamp(Math.min(worldFracX(tl.x),worldFracX(br.x)),0,1);
  const maxFx=clamp(Math.max(worldFracX(tl.x),worldFracX(br.x)),0,1);
  const minFy=clamp(Math.min(worldFracY(tl.y),worldFracY(br.y)),0,1);
  const maxFy=clamp(Math.max(worldFracY(tl.y),worldFracY(br.y)),0,1);
  const startX=clamp(Math.floor((minFx*level.width)/tiles.tileSize),0,level.cols-1);
  const endX=clamp(Math.floor(Math.max(0,(maxFx*level.width)-1)/tiles.tileSize),0,level.cols-1);
  const startY=clamp(Math.floor((minFy*level.height)/tiles.tileSize),0,level.rows-1);
  const endY=clamp(Math.floor(Math.max(0,(maxFy*level.height)-1)/tiles.tileSize),0,level.rows-1);
  let drew=false;
  for(let ty=startY;ty<=endY;ty++){
    const topPx=ty*tiles.tileSize;
    const bottomPx=Math.min(level.height,(ty+1)*tiles.tileSize);
    const topFrac=topPx/level.height;
    const bottomFrac=bottomPx/level.height;
    const wy0=cfg.maxY-topFrac*mapHeight();
    const wy1=cfg.maxY-bottomFrac*mapHeight();
    for(let tx=startX;tx<=endX;tx++){
      const leftPx=tx*tiles.tileSize;
      const rightPx=Math.min(level.width,(tx+1)*tiles.tileSize);
      const leftFrac=leftPx/level.width;
      const rightFrac=rightPx/level.width;
      const wx0=cfg.maxX-leftFrac*mapWidth();
      const wx1=cfg.maxX-rightFrac*mapWidth();
      const p0=worldToScreen(wx0,wy0), p1=worldToScreen(wx1,wy1);
      const dx=Math.min(p0.x,p1.x), dy=Math.min(p0.y,p1.y), dw=Math.abs(p1.x-p0.x), dh=Math.abs(p1.y-p0.y);
      const tile=getTile(level.z,tx,ty);
      if(tile.loaded){ ctx.drawImage(tile.img,dx-pad,dy-pad,dw+pad*2,dh+pad*2); drew=true; }
      else if(placeholder){ ctx.fillStyle='#1c2027'; ctx.fillRect(dx,dy,dw,dh); }
    }
  }
  return drew;
}



function drawTiles(){
  if(!cfg.tiles?.enabled)return false;
  const levels=getSortedTileLevels();
  if(!levels.length)return false;
  drawTileLayer(levels[0],{placeholder:true,pad:0});
  const best=selectTileLevel();
  if(best&&best.z!==levels[0].z) drawTileLayer(best,{placeholder:false,pad:0.75});
  return true;
}

function drawFallbackGrid(strength=1){
  const r=rect(),w=r.width,h=r.height;
  ctx.fillStyle='#171a1f';
  ctx.fillRect(0,0,w,h);
  ctx.strokeStyle=strength>0.5?'#343a44':'#343a4477';
  ctx.lineWidth=1;
  const rows=cfg.rows||['D','C','B','A','Z'];
  const cols=cfg.columns||['4','3','2','1','0'];
  for(let i=0;i<=5;i++){
    const fx=i/5;
    const wx=cfg.maxX-fx*mapWidth();
    const wy=cfg.maxY-fx*mapHeight();
    const px=worldToScreen(wx,view.centerY).x;
    const py=worldToScreen(view.centerX,wy).y;
    ctx.beginPath();ctx.moveTo(px,0);ctx.lineTo(px,h);ctx.stroke();
    ctx.beginPath();ctx.moveTo(0,py);ctx.lineTo(w,py);ctx.stroke();
  }
  ctx.fillStyle='#7d8798';
  ctx.font='13px Segoe UI';
  ctx.textAlign='center';
  ctx.textBaseline='middle';
  for(let ry=0;ry<5;ry++)for(let cx=0;cx<5;cx++){
    const fx=(cx+0.5)/5,fy=(ry+0.5)/5;
    const wx=cfg.maxX-fx*mapWidth();
    const wy=cfg.maxY-fy*mapHeight();
    const p=worldToScreen(wx,wy);
    ctx.fillText(`${rows[ry]}${cols[cx]}`,p.x,p.y);
  }
}

function drawGridOverlay(){
  const rows=cfg.rows||['D','C','B','A','Z'];
  const cols=cfg.columns||['4','3','2','1','0'];
  ctx.strokeStyle='#b8c0cc28';
  ctx.lineWidth=1;
  for(let i=0;i<=5;i++){
    const fx=i/5;
    const wx=cfg.maxX-fx*mapWidth();
    const wy=cfg.maxY-fx*mapHeight();
    const px=worldToScreen(wx,view.centerY).x;
    const py=worldToScreen(view.centerX,wy).y;
    ctx.beginPath();ctx.moveTo(px,0);ctx.lineTo(px,rect().height);ctx.stroke();
    ctx.beginPath();ctx.moveTo(0,py);ctx.lineTo(rect().width,py);ctx.stroke();
  }
  ctx.fillStyle='#d7deea88';
  ctx.font='12px Segoe UI';
  ctx.textAlign='center';
  ctx.textBaseline='middle';
  for(let ry=0;ry<5;ry++)for(let cx=0;cx<5;cx++){
    const fx=(cx+0.5)/5,fy=(ry+0.5)/5;
    const wx=cfg.maxX-fx*mapWidth();
    const wy=cfg.maxY-fy*mapHeight();
    const p=worldToScreen(wx,wy);
    if(p.x<-40||p.x>rect().width+40||p.y<-20||p.y>rect().height+20)continue;
    ctx.fillText(`${rows[ry]}${cols[cx]}`,p.x,p.y);
  }
}

function drawMarkers(){
  markerCache=[];
  for(const z of snap.zombies||[]){
    if(!z.position)continue;
    const p=worldToScreen(z.position.x,z.position.y);
    if(p.x<-8||p.x>rect().width+8||p.y<-8||p.y>rect().height+8)continue;
    ctx.fillStyle='#7a3940';
    ctx.beginPath();ctx.arc(p.x,p.y,2.4,0,Math.PI*2);ctx.fill();
  }
  for(const n of snap.npcs||[]){
    if(!n.alive||!n.position)continue;
    const p=worldToScreen(n.position.x,n.position.y);
    if(p.x<-16||p.x>rect().width+16||p.y<-16||p.y>rect().height+16)continue;
    const g=groupFor(n);
    const radius=n.role==='leader'?7:5;
    ctx.fillStyle=n.simulationLod==='FULL'?'#f2f2f2':n.simulationLod==='LIGHT'?'#85c7ff':'#d8a5ff';
    ctx.beginPath();ctx.arc(p.x,p.y,radius,0,Math.PI*2);ctx.fill();
    if(n.role==='leader'){ctx.strokeStyle='#ffd166';ctx.lineWidth=2;ctx.stroke();}
    if(n.destination){
      const d=worldToScreen(n.destination.x,n.destination.y);
      ctx.strokeStyle='#ffffff33';ctx.lineWidth=1;ctx.beginPath();ctx.moveTo(p.x,p.y);ctx.lineTo(d.x,d.y);ctx.stroke();
    }
    markerCache.push({n,x:p.x,y:p.y,r:Math.max(9,radius+4),g});
  }
  if(selected){
    const m=markerCache.find(x=>x.n.npcId===selected);
    if(m){ctx.strokeStyle='#ff4d4d';ctx.lineWidth=2;ctx.beginPath();ctx.arc(m.x,m.y,m.r+3,0,Math.PI*2);ctx.stroke();}
  }
}

function draw(){
  if(!view.initialized)ensureViewInitialized();
  const r=rect(),w=r.width,h=r.height;
  ctx.clearRect(0,0,w,h);
  ctx.fillStyle='#0f1217';
  ctx.fillRect(0,0,w,h);
  const usingTiles=drawTiles();
  if(!usingTiles)drawFallbackGrid(1);
  drawGridOverlay();
  drawMarkers();
}

function hit(x,y){let best=null,bd=999;for(const m of markerCache){const d=Math.hypot(x-m.x,y-m.y);if(d<m.r&&d<bd){best=m;bd=d}}return best}
function nearestWorldZ(x,y){const samples=[...(snap.npcs||[]).filter(n=>n.alive).map(n=>n.position),...(snap.zombies||[]).map(z=>z.position),...(snap.players||[]).map(p=>p.position)].filter(p=>p&&Number.isFinite(Number(p.x))&&Number.isFinite(Number(p.y))&&Number.isFinite(Number(p.z)));let nearest=null,best=Infinity;for(const p of samples){const d=Math.hypot(Number(p.x)-x,Number(p.y)-y);if(d<best){best=d;nearest=p}}return nearest?{z:Number(nearest.z),distance:best}:{z:Number(cfg.defaultZ),distance:Infinity}}
function nearestContextWorld(px,py){const base=screenToWorld(px,py);const nearest=nearestWorldZ(base.x,base.y);return{x:base.x,y:base.y,z:nearest.z,approxZ:true,zSource:Number.isFinite(nearest.distance)?'nearest live entity':'configured fallback'}}

function renderDetails(n){
  if(!n){panel.innerHTML='<div class="muted">Click an NPC marker.</div>';return}
  const g=groupFor(n);
  const trauma=(n.traumas||[]).map(t=>`<span class="tag">${esc(t.type)} ${pct(t.severity)}%</span>`).join('')||'<span class="muted">none</span>';
  const traits=Object.entries(n.traits||{}).sort((a,b)=>b[1]-a[1]).map(([k,v])=>`<div class="row"><span>${esc(k)}</span><b>${pct(v)}</b></div>`).join('');
  const skills=Object.entries(n.skills||{}).sort((a,b)=>b[1]-a[1]).map(([k,v])=>`<div class="row"><span>${esc(k)}</span><b>${pct(v)}</b></div>`).join('');
  panel.innerHTML=`<h2>${esc(n.npcId)}</h2><div class="card"><div class="row"><span>Body</span><b>${esc(n.bodyProfile)}</b></div><div class="row"><span>Archetype</span><b>${esc(n.archetype)}</b></div><div class="row"><span>Skill tier</span><b>${n.skillTier}</b></div><div class="row"><span>LOD</span><b>${esc(n.simulationLod)}</b></div><div class="row"><span>Group</span><b>${esc(n.groupId||'solo')}</b></div><div class="row"><span>Role</span><b>${esc(n.role)}</b></div><div class="row"><span>Stress</span><b>${pct(n.stress)}%</b></div><div class="bar"><i style="width:${pct(n.stress)}%"></i></div><div class="row"><span>Morale</span><b>${pct(n.morale)}%</b></div><div class="row"><span>Activity</span><b>${esc(n.activity)}</b></div><div class="row"><span>Position</span><b>${Math.round(n.position.x)}, ${Math.round(n.position.y)}, ${Math.round(n.position.z)}</b></div></div>${g?`<div class="card"><h3>Group ${esc(g.groupId)}</h3><div class="row"><span>Class</span><b>${esc(g.classId)}</b></div><div class="row"><span>Level</span><b>${g.level}</b></div><div class="row"><span>Leader</span><b>${esc(g.leaderId||'LEADERLESS')}</b></div><div class="row"><span>Cohesion</span><b>${pct(g.cohesion)}%</b></div><div class="row"><span>Morale</span><b>${pct(g.morale)}%</b></div><div class="row"><span>Combat power</span><b>${g.combatPower}</b></div><div class="row"><span>Leader shock</span><b>${pct(g.effects?.leaderDeathShock)}%</b></div></div>`:''}<div class="card"><h3>Trauma</h3>${trauma}</div><div class="card"><h3>Traits</h3>${traits}</div><div class="card"><h3>Skills</h3>${skills}</div>`;
}

function renderHealth(){
  const rows=Object.entries(snap.health||{}).map(([k,v])=>`<div class="healthItem"><div class="row"><span>${esc(k)}</span><b class="health-${String(v.status).toLowerCase()}">${esc(v.status)}</b></div>${v.detail?`<div class="detail">${esc(v.detail)}</div>`:''}</div>`).join('');
  healthEl.innerHTML=`<div class="card"><h3>Subsystem health</h3>${rows||'<div class="muted">No health data yet.</div>'}</div>`;
}

async function loadDetails(id){
  if(!id){renderDetails(null);return}
  try{
    const d=await fetch('/api/npc/'+encodeURIComponent(id),{cache:'no-store'}).then(r=>r.ok?r.json():Promise.reject(new Error('npc not found')));
    renderDetails(d.npc);
  }catch{renderDetails(null)}
}

function updateZoomLabel(){ if(zoomValue)zoomValue.textContent=String(view.zoom); }
function setZoom(nextZoom,anchorX=null,anchorY=null){
  ensureViewInitialized();
  const tiles=cfg.tiles||{minZoom:0,maxZoom:5};
  const minZ=tiles.minZoom??0,maxZ=tiles.maxZoom??5;
  const clamped=clamp(Math.round(nextZoom),minZ,maxZ);
  if(clamped===view.zoom){updateZoomLabel();draw();return;}
  let anchorWorld=null;
  if(anchorX!=null&&anchorY!=null)anchorWorld=screenToWorld(anchorX,anchorY);
  view.zoom=clamped;
  if(anchorWorld){
    const after=screenToWorld(anchorX,anchorY);
    view.centerX+=anchorWorld.x-after.x;
    view.centerY+=anchorWorld.y-after.y;
  }
  clampView();
  updateZoomLabel();
  draw();
}
function panByPixels(dx,dy){
  const ppw=pixelsPerWorld();
  view.centerX+=dx/ppw;
  view.centerY+=dy/ppw;
  clampView();
  draw();
}
function resetView(){ view.initialized=false; ensureViewInitialized(true); draw(); }

canvas.addEventListener('wheel',e=>{
  e.preventDefault();
  const r=rect();
  const mx=e.clientX-r.left,my=e.clientY-r.top;
  setZoom(view.zoom+(e.deltaY<0?1:-1),mx,my);
},{passive:false});
canvas.addEventListener('dblclick',e=>{
  const r=rect();
  setZoom(view.zoom+1,e.clientX-r.left,e.clientY-r.top);
});
canvas.addEventListener('pointerdown',e=>{
  const r=rect();
  pointerState={id:e.pointerId,startX:e.clientX,startY:e.clientY,lastX:e.clientX,lastY:e.clientY,canvasX:e.clientX-r.left,canvasY:e.clientY-r.top,moved:false};
  canvas.setPointerCapture(e.pointerId);
  canvas.style.cursor='grabbing';
});
canvas.addEventListener('pointermove',e=>{
  if(!pointerState||pointerState.id!==e.pointerId)return;
  const dx=e.clientX-pointerState.lastX,dy=e.clientY-pointerState.lastY;
  if(pointerState.moved||Math.hypot(e.clientX-pointerState.startX,e.clientY-pointerState.startY)>4){
    pointerState.moved=true;
    panByPixels(dx,dy);
  }
  pointerState.lastX=e.clientX;pointerState.lastY=e.clientY;
});
function finishPointer(e){
  if(!pointerState||pointerState.id!==e.pointerId)return;
  const r=rect();
  const x=e.clientX-r.left,y=e.clientY-r.top;
  if(!pointerState.moved){
    const m=hit(x,y);
    selected=m?.n.npcId||null;
    loadDetails(selected);
    draw();
  }
  try{canvas.releasePointerCapture(e.pointerId);}catch{}
  pointerState=null;
  canvas.style.cursor='grab';
}
canvas.addEventListener('pointerup',finishPointer);
canvas.addEventListener('pointercancel',finishPointer);
canvas.addEventListener('contextmenu',e=>{
  e.preventDefault();
  const r=rect(),x=e.clientX-r.left,y=e.clientY-r.top,m=hit(x,y);
  contextWorld=m?{...m.n.position,approxZ:false,zSource:'NPC exact position'}:{...nearestContextWorld(x,y)};
  document.getElementById('copyTp').textContent=contextWorld.approxZ?'Copy teleport command (approx Z)':'Copy teleport command';
  menu.style.left=`${x}px`;
  menu.style.top=`${y}px`;
  menu.classList.remove('hidden');
});
document.addEventListener('click',e=>{if(!menu.contains(e.target)&&e.target!==canvas)menu.classList.add('hidden')});

async function copy(text,note=''){await navigator.clipboard.writeText(text);toast.textContent=note?`Copied: ${text} — ${note}`:`Copied: ${text}`;toast.style.opacity=1;setTimeout(()=>toast.style.opacity=0,2600);menu.classList.add('hidden')}
document.getElementById('copyTp').onclick=()=>{const cmd=`#Teleport ${Number(contextWorld.x).toFixed(2)} ${Number(contextWorld.y).toFixed(2)} ${Number(contextWorld.z).toFixed(2)}`;copy(cmd,contextWorld.approxZ?`approximate Z from ${contextWorld.zSource}; adjust altitude if needed`:'')};
document.getElementById('copyCoords').onclick=()=>copy(`${Number(contextWorld.x).toFixed(2)} ${Number(contextWorld.y).toFixed(2)} ${Number(contextWorld.z).toFixed(2)}`,contextWorld.approxZ?'approximate Z':'');
document.getElementById('zoomIn').onclick=()=>setZoom(view.zoom+1);
document.getElementById('zoomOut').onclick=()=>setZoom(view.zoom-1);
document.getElementById('zoomReset').onclick=()=>resetView();

async function refresh(){
  try{
    const [s,c]=await Promise.all([
      fetch('/api/map-snapshot',{cache:'no-store'}).then(r=>r.json()),
      fetch('/api/map-config',{cache:'no-store'}).then(r=>r.json())
    ]);
    snap=s;
    cfg=Object.assign({},cfg,c||{});
    cfg.tiles=Object.assign({},cfg.tiles||{},(c&&c.tiles)||{});
    ensureViewInitialized();
    conn.textContent='live';
    conn.style.color='#8bcf8b';
    stats.textContent=`NPC ${s.npcs.filter(n=>n.alive).length} · Groups ${s.groups.length} · Zombies ${s.zombies.length} · Zoom ${view.zoom}`;
    renderHealth();
    if(selected)loadDetails(selected);
    draw();
  }catch(e){
    conn.textContent='offline';
    conn.style.color='#ff6b6b';
  }
}

canvas.style.cursor='grab';
resize();
refresh();
setInterval(refresh,1000);
