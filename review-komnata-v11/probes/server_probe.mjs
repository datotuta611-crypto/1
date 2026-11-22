const root = process.argv[2];
const {api} = await import(root + "/room.mjs");
const {localDatabase} = await import(root + "/sqlite.mjs");

function setup() {
  const db = localDatabase(":memory:");
  const env = {DB: db, ROOM_BRIDGE_KEY: "k"};
  async function call(path, body, worker=false) {
    const headers = {"content-type":"application/json","oai-authenticated-user-id":"owner"};
    if (worker) headers["x-room-bridge"] = "k";
    const res = await api(new Request("https://room.test/api/"+path,{method:body?"POST":"GET",headers,body:body?JSON.stringify(body):undefined}),env);
    return {status:res.status, ...await res.json()};
  }
  const claim = async () => (await call("bridge/claim",{turnDecisions:true,agentSettings:true,chatMemory:true,historySearch:true},true)).job;
  const finish = (job,text,action) => call("bridge/finish",{lease:job.lease,text,action},true);
  const room = async () => (await call("state")).room;
  return {db,call,claim,finish,room};
}
const show = (label, v) => console.log(label.padEnd(58), JSON.stringify(v));

// P1: unaddressed research question after Lev spoke last
{
  const {call,claim,finish} = setup();
  await call("message",{text:"Лев, привет"}); await finish(await claim(),"Привет!","wait");
  await call("message",{text:"Исследуйте: когда вышел RFC 9457 и что он заменил?"});
  const j = await claim();
  show("P1 первый ход исследовательского вопроса без имени:", j.author);
}
// P2: Mira discuss -> Lev peer -> Lev pass (silent agreement)
{
  const {call,claim,finish,room} = setup();
  await call("message",{text:"Мира, найди ответ с источниками, а Лев пусть проверит"});
  const m = await claim(); await finish(m,"Ответ Миры со ссылкой https://example.org/a","discuss");
  const l = await claim(); show("P2 второй ход:", {author:l.author,cause:l.turnCause});
  const r = await finish(l,"","pass");
  const st = await call("state");
  show("P2 после pass Льва: posted / active / reason:", [r.posted, st.room.active, st.room.reason]);
  show("P2 сообщений Льва в чате:", st.messages.filter(x=>x.author==="lev").length);
}
// P3: owner clarification during Lev's verification, quota 4
{
  const {call,claim,finish,room} = setup();
  await call("message",{text:"Мира, исследуй вопрос; Лев, проверь"});
  const m = await claim(); await finish(m,"Ответ v1","discuss");
  const l = await claim(); show("P3 remaining во время проверки Льва:", (await room()).remaining);
  await call("message",{text:"Уточняю: речь о версии 2025 года"});
  show("P3 после уточнения: remaining / turn:", [(await room()).remaining, (await room()).turn]);
  show("P3 старый ответ Льва опубликован?", (await finish(l,"Подтверждаю v1","wait")).posted);
  const n = await claim(); show("P3 следующий ход после уточнения:", {author:n.author,cause:n.turnCause});
  await finish(n,"Ответ v2","discuss");
  const v = await claim(); show("P3 затем:", {author:v.author,cause:v.turnCause});
  await finish(v,"В v2 неверна дата, нужна правка","discuss");
  const st = await room(); show("P3 после замечания Льва: active / reason:", [st.active, st.reason]);
}
// P4: Lev raises an issue with discuss, Mira passes -> no revision, neutral status
{
  const {call,claim,finish,room} = setup();
  await call("limit",{limit:6});
  await call("message",{text:"Мира, исследуй; Лев, проверь"});
  await finish(await claim(),"Ответ v1","discuss");
  await finish(await claim(),"Пункт 2 неверен: см. https://example.org/b","discuss");
  const m2 = await claim(); show("P4 ход Миры после замечания:", {author:m2.author,cause:m2.turnCause});
  await finish(m2,"","pass");
  const st = await room(); show("P4 после pass Миры: active / reason:", [st.active, st.reason]);
}
// P5: limit 2 -> Mira + Lev verify with wait; nothing distinguishes 'verified' from 'out of turns'
{
  const {call,claim,finish,room} = setup();
  await call("limit",{limit:2});
  await call("message",{text:"Мира, исследуй; Лев, проверь"});
  await finish(await claim(),"Ответ v1","discuss");
  await finish(await claim(),"Нашёл расхождение в п.2, Мире стоит исправить","discuss");
  const st = await room(); show("P5 лимит 2, Лев вернул замечание: active / reason:", [st.active, st.reason]);
}
// P6: "Стоп, я понял" while idle -> starts a new round
{
  const {call,claim,finish,room} = setup();
  await call("message",{text:"Мира, привет"}); await finish(await claim(),"Привет","wait");
  await call("message",{text:"Стоп, я понял"});
  const st = await room(); const j = await claim();
  show("P6 'Стоп, я понял': active / remaining / ход выдан:", [st.active, st.remaining, !!j]);
}
// P7: addressing false positives
{
  const {call,claim,finish} = setup();
  for (const t of ["Лев Толстой писал о войне. Что думаете?","Мира во всём мире — реалистичная цель?","Лев — царь зверей?","Карта мира, которую ты прислал, устарела"]) {
    const {call:c2,claim:cl2,finish:f2} = setup();
    await c2("message",{text:"Лев, привет"}); await f2(await cl2(),"Привет","wait");
    await c2("message",{text:"Мира, привет"}); await f2(await cl2(),"Привет","wait");
    await c2("message",{text:t}); const j = await cl2();
    show("P7 «"+t+"» →", j.author);
  }
}
