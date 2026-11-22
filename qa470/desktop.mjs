import { spawn } from 'node:child_process';
import { readFile } from 'node:fs/promises';
import { join } from 'node:path';
import { setTimeout as delay } from 'node:timers/promises';

const exe = process.argv[2];
const child = spawn(exe, ['--remote-debugging-address=127.0.0.1','--remote-debugging-port=19381'], {stdio:'ignore'});
let ws;
try {
  let target;
  for (let i=0;i<120 && !target;i++) {
    if (child.exitCode !== null) throw new Error('Desktop exited: '+child.exitCode);
    const pages = await fetch('http://127.0.0.1:19381/json/list').then(r=>r.json()).catch(()=>[]);
    target = pages.find(p=>p.type==='page' && p.url.startsWith('app://setup'));
    if (!target) await delay(1000);
  }
  if (!target) throw new Error('No packaged setup window available');
  ws = new WebSocket(target.webSocketDebuggerUrl);
  await new Promise((ok,fail)=>{ws.onopen=ok;ws.onerror=fail;});
  let id=0;
  async function evaluate(expression) {
    const req=++id;
    return new Promise((ok,fail)=>{
      const time=setTimeout(()=>{ws.removeEventListener('message',onMessage);fail(new Error('setup window response timeout'))},30000);
      function onMessage(event) {
        const msg=JSON.parse(event.data);
        if(msg.id!==req)return;
        clearTimeout(time); ws.removeEventListener('message',onMessage);
        if(msg.error||msg.result?.exceptionDetails)fail(new Error('setup command failed'));
        else ok(msg.result.result.value);
      }
      ws.addEventListener('message',onMessage);
      ws.send(JSON.stringify({id:req,method:'Runtime.evaluate',params:{expression,awaitPromise:true,returnByValue:true}}));
    });
  }
  const state=()=>evaluate('(async()=>{const s=(await window.lingerSetup.getState()).localServer; const m=s.localModels;return {phase:s.phase,step:s.step,progress:s.progress,probe:m.state,eligible:m.eligible,recommendation:m.recommendation,reasons:m.reasons?.map(r=>r.code),model:m.model?.name}})()');
  let s;
  for(let i=0;i<150;i++){
    s=await state(); if(['checked','unavailable'].includes(s.probe))break;
    await delay(2000);
  }
  console.log('Setup eligibility:',JSON.stringify(s));
  if(s.probe!=='checked')throw new Error('Hardware inspection did not complete');
  if(!s.eligible)throw new Error('Desktop does not offer a local model on this host: '+JSON.stringify(s.reasons));
  await evaluate('void window.lingerSetup.run({op:"local.start",runtime:"local"})');
  let last='';
  for(let i=0;i<360;i++){
    s=await state();
    if(last!==s.phase+'/'+s.step){console.log('Install stage:',s.phase,s.step);last=s.phase+'/'+s.step;}
    if(s.phase==='failed')throw new Error('Desktop local model installation failed at '+s.step);
    if(s.phase==='ready'){
      const b=JSON.parse(await readFile(join(process.env.LINGER_HOME,'runtime','localmodels','binding.json'),'utf8'));
      if(b.ready!==true || !/^[a-f0-9]{64}$/.test(b.pi?.configFingerprint))throw new Error('Installation has no ready binding');
      console.log('Desktop ready and saved local model binding ready');break;
    }
    if(i===359)throw new Error('Local model installation timed out');
    await delay(4000);
  }
} finally { ws?.close(); child.kill(); }
