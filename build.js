#!/usr/bin/env node
/* Kaaraisee src/app.html itsenaiseksi index.html-sivuksi.
   src/app.html on Artifact-muotoinen (ei <html>/<head>/<body>-tageja),
   jotta sama lahde toimii seka julkaistuna artifaktina etta paikallisena sivuna. */
const fs=require('fs'), path=require('path');
const root=__dirname;
const body=fs.readFileSync(path.join(root,'src','app.html'),'utf8');
const out=`<!doctype html>
<html lang="fi">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1,viewport-fit=cover">
<meta name="description" content="Kolmiulotteinen ilmavirtaussimulaatio 24 neliön yksiöstä: parvekkeen ovi, yläikkuna, parvekelasitus, poistoilmakanavat ja siirreltävä tornituuletin.">
<meta name="color-scheme" content="dark">
<style>html,body{margin:0;padding:0;background:#080D12;color-scheme:dark}
img{max-width:100%}[hidden]{display:none!important}</style>
</head>
<body>
${body}
</body>
</html>
`;
fs.writeFileSync(path.join(root,'index.html'),out);
console.log('index.html kirjoitettu,',out.length,'tavua');
