"""
Benchmark dos modelos locais: latência, throughput (tokens/s) e qualidade.

Usa a API do Ollama diretamente para capturar métricas que o server não expõe:
prompt_eval_count, eval_count, load_duration, prompt_eval_duration, eval_duration.
"""

import json
import time

import httpx

OLLAMA = "http://localhost:11434"
TIMEOUT = httpx.Timeout(900.0, connect=10.0)

# Código com 5 problemas plantados conhecidos (gabarito):
#  1. SQL injection (f-string na query)
#  2. Command injection (os.system com input do usuário)
#  3. Segredo hardcoded (API_KEY)
#  4. Path traversal (open com caminho do usuário sem sanitizar)
#  5. Divisão sem tratamento de zero / sem validação de tipo
TEST_CODE = '''
import os, sqlite3

API_KEY = "demo_live_9f8a7b6c5d4e3f2a1b0c"   # segredo hardcoded (valor fictício de teste)

def get_user(db, name):
    cur = db.cursor()
    cur.execute(f"SELECT * FROM users WHERE name = '{name}'")
    return cur.fetchall()

def ping_host(host):
    os.system("ping -c 1 " + host)

def read_file(path):
    with open("/data/" + path) as f:
        return f.read()

def ratio(a, b):
    return a / b
'''

GABARITO = ["sql injection", "command injection", "segredo/hardcoded secret",
            "path traversal", "divisão por zero / validação"]

SECURITY_SYSTEM = (
    "Você é um analista de segurança de aplicações (AppSec) defensivo. Identifique "
    "vulnerabilidades, classifique por severidade e proponha mitigações. Responda em pt-BR."
)


def run(model: str, system: str, prompt: str) -> dict:
    payload = {
        "model": model,
        "messages": [
            {"role": "system", "content": system},
            {"role": "user", "content": prompt},
        ],
        "stream": False,
        "options": {"temperature": 0.2},
    }
    t0 = time.time()
    with httpx.Client(timeout=TIMEOUT) as c:
        r = c.post(f"{OLLAMA}/api/chat", json=payload)
        r.raise_for_status()
        d = r.json()
    wall = time.time() - t0
    content = d.get("message", {}).get("content", "")
    return {
        "model": model,
        "wall_s": round(wall, 1),
        "prompt_tokens": d.get("prompt_eval_count", 0),
        "gen_tokens": d.get("eval_count", 0),
        "load_s": round(d.get("load_duration", 0) / 1e9, 1),
        "gen_s": round(d.get("eval_duration", 0) / 1e9, 1),
        "tok_per_s": round(d.get("eval_count", 0) / (d.get("eval_duration", 1) / 1e9), 1),
        "content": content,
    }


def score_quality(text: str) -> int:
    """Conta quantos dos 5 problemas plantados o modelo mencionou (heurística por palavras-chave)."""
    t = text.lower()
    hits = 0
    if "sql" in t and ("inje" in t or "injection" in t):
        hits += 1
    if ("command" in t or "comando" in t or "os.system" in t) and ("inje" in t or "injection" in t):
        hits += 1
    if "segredo" in t or "hardcoded" in t or "api_key" in t or "api key" in t or "chave" in t:
        hits += 1
    if "path" in t and ("traversal" in t or "diretór" in t or "directory" in t) or "../" in t:
        hits += 1
    if "zero" in t or "zerodivision" in t or "divis" in t:
        hits += 1
    return hits


PROMPT = "Analise a segurança do código a seguir:\n\n```python\n" + TEST_CODE + "\n```"

results = []
for model in ["qwen3:14b", "gpt-oss:20b"]:
    print(f"\n>>> rodando {model} ...", flush=True)
    res = run(model, SECURITY_SYSTEM, PROMPT)
    res["score"] = score_quality(res["content"])
    results.append(res)
    print(f"    wall={res['wall_s']}s load={res['load_s']}s gen={res['gen_s']}s "
          f"| in={res['prompt_tokens']}tok out={res['gen_tokens']}tok "
          f"| {res['tok_per_s']} tok/s | qualidade={res['score']}/5", flush=True)

# salva resultados completos para inspeção
with open("bench_results.json", "w", encoding="utf-8") as f:
    json.dump([{k: v for k, v in r.items()} for r in results], f, ensure_ascii=False, indent=2)

print("\n=== RESUMO ===")
print(f"{'modelo':<16}{'wall':>7}{'load':>7}{'in_tok':>8}{'out_tok':>9}{'tok/s':>8}{'qual':>7}")
for r in results:
    print(f"{r['model']:<16}{r['wall_s']:>6}s{r['load_s']:>6}s"
          f"{r['prompt_tokens']:>8}{r['gen_tokens']:>9}{r['tok_per_s']:>8}{r['score']:>5}/5")
print("\nResultados completos em bench_results.json")
