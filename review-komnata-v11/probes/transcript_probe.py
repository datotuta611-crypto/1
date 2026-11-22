import json, sys
sys.path.insert(0, sys.argv[1] + "/bridge")
import codex_runner as r
q = "ВОПРОС: " + "уточнение условий " * 80          # ~1.5k chars
rows = [{"author":"user","text":q},
        {"author":"mira","text":"НАЧАЛО_ОТВЕТА_V1 " + "м" * 9980},
        {"author":"lev","text":"НАЧАЛО_ПРОВЕРКИ " + "л" * 9980},
        {"author":"mira","text":"НАЧАЛО_ОТВЕТА_V2 " + "м" * 9980},
        {"author":"lev","text":"Замечание к v2 " + "л" * 3000}]
p = json.loads(r._transcript(rows, "lev", [], "peer"))["messages"]
print("реплик в контексте:", len(p), "из", len(rows))
print("исходный вопрос в контексте:", any(m["text"].startswith("ВОПРОС") for m in p))
print("первая реплика начинается с:", repr(p[0]["text"][:20]), "длина", len(p[0]["text"]))
print("признак обрезки передан модели:", any("…" in m["text"][:3] or "trunc" in json.dumps(m) for m in p))
