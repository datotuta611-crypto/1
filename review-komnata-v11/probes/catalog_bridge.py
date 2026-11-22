import sys, threading
sys.path.insert(0, sys.argv[1] + "/bridge")
import main as bridge
from unittest.mock import patch
claims = {"with_catalog":0, "without":0}
class Stop:
    def __init__(s): s.t=0; s.flag=False
    def is_set(s): return s.flag
    def wait(s, d): s.t += d; s.flag = s.t > 600; return s.flag
stop = Stop()
def call(method, path, body=None, **kw):
    if path == "/api/bridge/claim":
        if "catalog" in body:
            claims["with_catalog"] += 1
            raise ValueError("Некорректный каталог моделей.")
        claims["without"] += 1
        return {"job": None}
    raise AssertionError(path)
with patch.object(bridge, "model_choices", return_value={"models":[{"id":"a:b"}],"defaults":{}}), \
     patch.object(bridge, "run_telegram", lambda *a, **k: None), patch("sys.stderr"):
    bridge.run(call, stop)
print("за 10 минут моста: claim с каталогом (отклонены) =", claims["with_catalog"], "| claim без каталога =", claims["without"])
