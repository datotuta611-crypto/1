const root = process.argv[2];
const {api} = await import(root + "/room.mjs");
const {localDatabase} = await import(root + "/sqlite.mjs");
const db = localDatabase(":memory:"); const env = {DB: db, ROOM_BRIDGE_KEY: "k"};
const call = async (path, body, worker=false) => { const h={"content-type":"application/json","oai-authenticated-user-id":"o"}; if(worker) h["x-room-bridge"]="k";
  const r = await api(new Request("https://r.test/api/"+path,{method:body?"POST":"GET",headers:h,body:body?JSON.stringify(body):undefined}),env); return r.json(); };
await call("message",{text:"тема"});
const N = Number(process.argv[3]);
const ins = await db.prepare("INSERT INTO messages(author,text,source,created,chat_id) VALUES('mira',?,'agent',1,1)");
const text = "Обычная реплика о планах, макетах и сроках проекта. ".repeat(20);
db.prepare("SELECT 1").first();
for (let i=0;i<N;i++) await db.prepare("INSERT INTO messages(author,text,source,created,chat_id) VALUES('mira',?,'agent',1,1)").bind(text).run();
const job = (await call("bridge/claim",{turnDecisions:true,agentSettings:true,chatMemory:true,historySearch:true},true)).job;
for (const q of ["макет","отсутствующее слово","проект редкий термин"]) {
  const t=performance.now(); const r = await call("bridge/archive",{lease:job.lease,query:q},true);
  console.log(`${N} реплик, запрос «${q}»: ${(performance.now()-t).toFixed(0)} мс, найдено ${r.messages?.length}`);
}
