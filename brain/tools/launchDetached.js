'use strict';
const fs=require('fs');
const path=require('path');
const {spawn}=require('child_process');

function main(){
  const modRoot=path.resolve(__dirname,'..','..');
  const runtime=path.join(modRoot,'runtime');
  const serverJs=path.join(modRoot,'brain','src','server.js');
  const config=path.join(modRoot,'brain','config','installed.json');
  const userConfig=path.join(modRoot,'brain','config','user.json');
  const world=path.join(runtime,'world.json');
  const log=path.join(runtime,'brain.log');
  const pidFile=path.join(runtime,'brain.pid');
  fs.mkdirSync(runtime,{recursive:true});
  if(!fs.existsSync(serverJs))throw new Error(`Brain server missing: ${serverJs}`);
  if(!fs.existsSync(config))throw new Error(`Installed brain config missing: ${config}`);
  fs.appendFileSync(log,`\n==== BRAIN START ${new Date().toISOString()} ====\n`,'utf8');
  const fd=fs.openSync(log,'a');
  let child;
  try{
    child=spawn(process.execPath,[serverJs],{
      cwd:path.dirname(serverJs),
      detached:true,
      windowsHide:true,
      stdio:['ignore',fd,fd],
      env:{
        ...process.env,
        TESLES_NPC_CONFIG:config,
        TESLES_NPC_WORLD:world,
        TESLES_NPC_USER_CONFIG:userConfig
      }
    });
  } finally {
    fs.closeSync(fd);
  }
  if(!child.pid)throw new Error('Detached brain process did not return a PID.');
  fs.writeFileSync(pidFile,String(child.pid),'utf8');
  child.unref();
  console.log(`[TeslesNPCOverhaul] Detached brain process started (PID ${child.pid}).`);
}

try{main();}catch(err){
  console.error(`[TeslesNPCOverhaul] Brain launcher error: ${err&&err.stack||err}`);
  process.exitCode=1;
}
