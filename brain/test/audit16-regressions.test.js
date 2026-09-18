const test=require('node:test');
const assert=require('node:assert/strict');
const fs=require('node:fs');
const os=require('node:os');
const path=require('node:path');

const {loadConfig}=require('../src/server');

test('brain accepts Windows PowerShell 5.1 UTF-8 BOM in installed.json',()=>{
  const dir=fs.mkdtempSync(path.join(os.tmpdir(),'tesles-bom-config-'));
  const installed=path.join(dir,'installed.json');
  const user=path.join(dir,'missing-user.json');
  const cfg={server:{host:'127.0.0.1',port:17381},ipc:{},world:{seed:'bom-test'}};
  fs.writeFileSync(installed,'\uFEFF'+JSON.stringify(cfg),'utf8');
  const oldConfig=process.env.TESLES_NPC_CONFIG;
  const oldUser=process.env.TESLES_NPC_USER_CONFIG;
  try{
    process.env.TESLES_NPC_CONFIG=installed;
    process.env.TESLES_NPC_USER_CONFIG=user;
    assert.deepEqual(loadConfig().server,cfg.server);
  } finally {
    if(oldConfig===undefined) delete process.env.TESLES_NPC_CONFIG; else process.env.TESLES_NPC_CONFIG=oldConfig;
    if(oldUser===undefined) delete process.env.TESLES_NPC_USER_CONFIG; else process.env.TESLES_NPC_USER_CONFIG=oldUser;
    fs.rmSync(dir,{recursive:true,force:true});
  }
});

test('installer writes Node-readable config JSON as UTF-8 without BOM',()=>{
  const install=fs.readFileSync(path.join(__dirname,'..','..','installer','Install.ps1'),'utf8');
  assert.match(install,/function\s+Write-Utf8NoBom\b/i);
  assert.match(install,/Write-Utf8NoBom\s+\$userCfg\b/i);
  assert.match(install,/Write-Utf8NoBom\s+\(Join-Path\s+\$dest\s+'brain\\config\\installed\.json'\)/i);
  assert.doesNotMatch(install,/Set-Content[^\r\n]*installed\.json[^\r\n]*-Encoding\s+UTF8/i);
});
