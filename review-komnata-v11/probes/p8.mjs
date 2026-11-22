const root = process.argv[2];
const {api} = await import(root + "/room.mjs");
const {localDatabase} = await import(root + "/sqlite.mjs");
let now = 1_000_000; Date.now = () => now*1000;
const db = localDatabase(":memory:"); const env = {DB: db, ROOM_BRIDGE_KEY: "k"};
const call = async (path, body, worker=false) => { const h={"content-type":"application/json","oai-authenticated-user-id":"o"}; if(worker) h["x-room-bridge"]="k";
  const r = await api(new Request("https://r.test/api/"+path,{method:body?"POST":"GET",headers:h,body:body?JSON.stringify(body):undefined}),env); return r.json(); };
const claim = async()=> (await call("bridge/claim",{turnDecisions:true,agentSettings:true,chatMemory:true},true)).job;
const turn = Number(process.argv[3]);
const b = (await call("chat-create",{title:"Другой чат"})).chat.id;
await call("message",{text:"Мира, исследуй вопрос, а Лев пусть проверит"});
await call("message?chat="+b,{text:"Обсудите между собой идеи для отпуска"});
const got = {1:0,[b]:0};
for (let i=0;i<20;i++) { const j = await claim(); if (!j) break; got[j.chatId]++; now += turn;
  await call("bridge/finish",{lease:j.lease,text:"ход "+i,action:"discuss"},true); }
const s1 = (await call("state")).room;
console.log(`ход длится ${turn} с: в чате ревью выдано ${got[1]} из 4, во втором чате ${got[b]}; итог чата ревью: «${s1.reason}»`);
