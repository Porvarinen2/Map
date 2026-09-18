'use strict';
// Rebuild web/public/map/manifest.json (and the matching brain/config/default.json
// tile block) from the tiles that are actually present on disk.
//
// The viewer must never advertise a zoom level whose tiles were not shipped: that
// renders as an empty map instead of a detailed one. Run this after adding or
// removing a tile level, e.g. after restoring the deepest pyramid level:
//   node brain/tools/buildMapManifest.js
const fs=require('fs');
const path=require('path');

const root=path.resolve(__dirname,'..','..');
const tilesDir=path.join(root,'web','public','map','tiles');
const manifestFile=path.join(root,'web','public','map','manifest.json');
const configFile=path.join(root,'brain','config','default.json');

function readManifest(){
  try{return JSON.parse(fs.readFileSync(manifestFile,'utf8'));}catch{return {};}
}

function scanLevels(){
  if(!fs.existsSync(tilesDir))return {};
  const out={};
  for(const entry of fs.readdirSync(tilesDir,{withFileTypes:true})){
    if(!entry.isDirectory()||!/^\d+$/.test(entry.name))continue;
    const z=Number(entry.name);
    let maxX=-1,maxY=-1,count=0;
    for(const file of fs.readdirSync(path.join(tilesDir,entry.name))){
      const m=/^(\d+)_(\d+)\.(jpg|jpeg|png|webp)$/i.exec(file);
      if(!m)continue;
      maxX=Math.max(maxX,Number(m[1]));
      maxY=Math.max(maxY,Number(m[2]));
      count++;
    }
    if(count===0)continue;
    out[z]={cols:maxX+1,rows:maxY+1,tiles:count};
  }
  return out;
}

function build(){
  const previous=readManifest();
  const tileSize=Number(previous.tileSize)||512;
  const present=scanLevels();
  const zooms=Object.keys(present).map(Number).sort((a,b)=>a-b);
  if(!zooms.length)throw new Error(`no map tiles found under ${tilesDir}`);
  const maxZoom=zooms[zooms.length-1];
  const levels={};
  const incomplete=[];
  for(const z of zooms){
    const scanned=present[z];
    const prior=previous.levels?.[String(z)]||{};
    const width=Number(prior.width)||scanned.cols*tileSize;
    const height=Number(prior.height)||scanned.rows*tileSize;
    levels[String(z)]={width,height,cols:scanned.cols,rows:scanned.rows};
    const expected=scanned.cols*scanned.rows;
    if(scanned.tiles!==expected)incomplete.push(`level ${z}: ${scanned.tiles}/${expected} tiles`);
  }
  const manifest={
    tileSize,
    minZoom:zooms[0],
    maxZoom,
    imageWidth:levels[String(maxZoom)].width,
    imageHeight:levels[String(maxZoom)].height,
    format:previous.format||'jpg',
    levels,
    pathTemplate:previous.pathTemplate||'map/tiles/{z}/{x}_{y}.jpg'
  };
  fs.writeFileSync(manifestFile,JSON.stringify(manifest,null,2)+'\n');
  const cfg=JSON.parse(fs.readFileSync(configFile,'utf8'));
  cfg.map=cfg.map||{};
  cfg.map.tiles={...(cfg.map.tiles||{}),enabled:true,tileSize,minZoom:manifest.minZoom,maxZoom,imageWidth:manifest.imageWidth,imageHeight:manifest.imageHeight,format:manifest.format,pathTemplate:manifest.pathTemplate,levels};
  fs.writeFileSync(configFile,JSON.stringify(cfg,null,2)+'\n');
  return {manifest,incomplete};
}

if(require.main===module){
  const {manifest,incomplete}=build();
  console.log(`[TeslesNPC] map manifest rebuilt: zoom ${manifest.minZoom}-${manifest.maxZoom}, ${manifest.imageWidth}x${manifest.imageHeight} px`);
  for(const warning of incomplete)console.warn(`[TeslesNPC] incomplete tile level -> ${warning}`);
}
module.exports={build,scanLevels};
