const root = process.argv[2];
const {api} = await import(root + "/room.mjs");
const {localDatabase} = await import(root + "/sqlite.mjs");
async function route(text, last) {
  const db = localDatabase(":memory:"); const env = {DB: db, ROOM_BRIDGE_KEY: "k"};
  const call = async (path, body, worker=false) => { const h={"content-type":"application/json","oai-authenticated-user-id":"o"}; if(worker) h["x-room-bridge"]="k";
    const r = await api(new Request("https://r.test/api/"+path,{method:body?"POST":"GET",headers:h,body:body?JSON.stringify(body):undefined}),env); return r.json(); };
  const claim = async()=> (await call("bridge/claim",{turnDecisions:true,agentSettings:true,chatMemory:true},true)).job;
  await call("message",{text:(last==="lev"?"Лев":"Мира")+", привет"}); const j0=await claim();
  await call("bridge/finish",{lease:j0.lease,text:"Привет",action:"wait"},true);
  await call("message",{text}); return (await claim()).author;
}
for (const [t,last] of [["Лев Толстой писал о войне. Что думаете?","mira"],["Лев — царь зверей?","mira"],
  ["Мира во всём мире — реалистичная цель?","lev"],["Это вопрос мира, а не войны.","lev"],["Чемпионат мира: кто фаворит?","lev"]])
  console.log(("«"+t+"» (последней говорила "+(last==="lev"?"Лев":"Мира")+") →").padEnd(78), await route(t,last));
