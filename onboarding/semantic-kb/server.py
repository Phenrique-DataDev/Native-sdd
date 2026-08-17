"""
Servidor MCP de busca semântica LOCAL (Ollama + sqlite-vec) sobre KB/docs/archive de um
projeto scaffolded pelo Native-SDD.

NUNCA é um processo contínuo/daemon: o índice (`.claude/.cache/semantic-kb/index.db`, por
projeto, gitignored) é um ARTEFATO GERADO — mesmo molde de `graph.json`/`_index.yaml`
(regenerados por `/sync-context`). A reindexação é INCREMENTAL (hash por arquivo) e só roda
quando `reindex()` é chamado explicitamente — pelos 4 pontos de disparo do fluxo normal
(fim de onda do `/train-kb`, `/sync-context`, `/document`, `/ship`) ou manualmente. Ver
.claude/sdd/features/DESIGN_RAG_HIBRIDO.md.

Corpus indexado (relativo a `project_root`): `.claude/kb/`, `docs/`, `.claude/sdd/archive/`.
Só extensões de prosa (`.md`/`.yaml`/`.yml`/`.txt`) — nunca código-fonte (fora de escopo,
ver DEFINE_RAG_HIBRIDO.md).

Embeddings: Ollama local (`nomic-embed-text`, 768 dimensões) — offline, sem custo de API,
conteúdo nunca sai da máquina. Vetores: `sqlite-vec` (embarcado, sem servidor), carregado via
`pysqlite3-binary` em vez do `sqlite3` da stdlib — o Python bundled do macOS não suporta
`enable_load_extension` (ver DESIGN_RAG_HIBRIDO.md, seção "A-002").

Busca (`semantic_search`) NUNCA retorna o arquivo inteiro — só path + score + trecho curto,
mesma disciplina de economia de contexto do `local-ai/server.py` (`_deliver`/`save_to`). O
agente decide se vale a pena ler o arquivo completo a partir do path retornado.
"""

import hashlib
import os
import time
from contextlib import asynccontextmanager
from pathlib import Path

import httpx
from mcp.server.fastmcp import FastMCP

try:
    # pysqlite3-binary contorna a falta de enable_load_extension no Python bundled do macOS
    # (ver DESIGN_RAG_HIBRIDO.md) — funciona nos 3 SOs de forma uniforme.
    import pysqlite3 as sqlite3
except ImportError:  # pragma: no cover - fallback só p/ ambientes sem o pacote (ex.: CI de lint)
    import sqlite3  # type: ignore[no-redef]

import sqlite_vec
from sqlite_vec import serialize_float32

OLLAMA_HOST = os.environ.get("OLLAMA_HOST", "http://localhost:11434").rstrip("/")
EMBED_MODEL = os.environ.get("EMBED_MODEL", "nomic-embed-text")
EMBED_DIM = 768  # dimensão de saída do nomic-embed-text

# Timeout generoso o bastante p/ embedar um arquivo no orçamento máximo de KB (~32K chars);
# latência típica documentada é 15-50ms por chamada curta (ver DESIGN_RAG_HIBRIDO.md).
TIMEOUT = httpx.Timeout(30.0, connect=10.0)

# Probe barato ANTES do loop de embeddings (fail-fast): um GET /api/tags com connect timeout
# curto. Se o Ollama está fora do ar, isto retorna em <1s em vez de pagar N tentativas de embed
# (cada ConnectError custava ~2s → ~35s p/ 15 arquivos). Ver SEMANTIC_KB_FAILFAST.
PROBE_TIMEOUT = httpx.Timeout(5.0, connect=1.0)

# Circuit breaker: N embeds falhando EM SEQUÊNCIA aborta o resto do loop. Cobre o modo de falha
# que o probe NÃO pega — Ollama no ar mas modelo não baixado (o /api/tags responde, cada embed
# devolve 404). Sem isto, um reindex de 50 arquivos pagaria 50 respostas 404 à toa.
CIRCUIT_BREAKER_THRESHOLD = 3

# Quantos arquivos grandes o relatório NOMEIA antes de resumir o resto em "+N outros". O relato
# tem de caber na resposta da tool sem virar um despejo: nos corpora do próprio framework, 179 de
# 289 `.md` passam do limite (medido 2026-08-14).
OVERSIZED_REPORT_LIMIT = 5

# Corpus indexado (DEFINE_RAG_HIBRIDO.md): KB + docs/ + histórico SDD arquivado. Fora de
# escopo de propósito: código-fonte (tools/*.ps1), .claude/commands/, graph.json.
CORPUS_ROOTS = (".claude/kb", "docs", ".claude/sdd/archive")
INDEXABLE_EXT = (".md", ".yaml", ".yml", ".txt")
SNIPPET_LEN = 280

mcp = FastMCP("semantic-kb")


# ─────────────────────────────────────────────────────────────────────────
# Funções PURAS (sem I/O de rede, sem Ollama) — provam AT-001/AT-002 sozinhas
# ─────────────────────────────────────────────────────────────────────────

def compute_file_manifest(project_root: str) -> dict[str, str]:
    """Varre CORPUS_ROOTS sob `project_root`, devolve {caminho-relativo: sha256}.
    Raiz ausente é ignorada (não é erro). Determinístico e sem efeitos colaterais."""
    root = Path(project_root).expanduser().resolve()
    manifest: dict[str, str] = {}
    for corpus_dir in CORPUS_ROOTS:
        base = root / corpus_dir
        if not base.is_dir():
            continue
        for f in sorted(base.rglob("*")):
            if not f.is_file() or f.suffix.lower() not in INDEXABLE_EXT:
                continue
            rel = f.relative_to(root).as_posix()
            manifest[rel] = hashlib.sha256(f.read_bytes()).hexdigest()
    return manifest


def diff_manifest(old: dict[str, str], new: dict[str, str]) -> dict[str, list[str]]:
    """Compara dois manifests -> {added, changed, removed, unchanged} (listas de path,
    ordenadas). É esta função que garante a reindexação INCREMENTAL: só `added`+`changed`
    disparam uma chamada de embedding; `unchanged` nunca é reprocessado."""
    old_paths, new_paths = set(old), set(new)
    common = old_paths & new_paths
    return {
        "added": sorted(new_paths - old_paths),
        "changed": sorted(p for p in common if old[p] != new[p]),
        "removed": sorted(old_paths - new_paths),
        "unchanged": sorted(p for p in common if old[p] == new[p]),
    }


def corpus_of(relpath: str) -> str:
    """Rotula a que raiz do corpus um caminho relativo pertence (metadado p/ o resultado)."""
    for c in CORPUS_ROOTS:
        if relpath == c or relpath.startswith(c + "/"):
            return c
    return "?"


# ─────────────────────────────────────────────────────────────────────────
# Camada de storage (sqlite-vec) — só I/O local, sem rede
# ─────────────────────────────────────────────────────────────────────────

def _db_path(project_root: str) -> Path:
    p = Path(project_root).expanduser().resolve() / ".claude" / ".cache" / "semantic-kb" / "index.db"
    p.parent.mkdir(parents=True, exist_ok=True)
    return p


def _connect(project_root: str) -> "sqlite3.Connection":
    db = sqlite3.connect(str(_db_path(project_root)))
    db.enable_load_extension(True)
    sqlite_vec.load(db)
    db.enable_load_extension(False)
    db.execute(f"CREATE VIRTUAL TABLE IF NOT EXISTS vec_entries USING vec0(embedding float[{EMBED_DIM}])")
    db.execute(
        "CREATE TABLE IF NOT EXISTS files ("
        "  rowid INTEGER PRIMARY KEY,"
        "  path TEXT UNIQUE NOT NULL,"
        "  hash TEXT NOT NULL,"
        "  corpus TEXT NOT NULL,"
        "  snippet TEXT NOT NULL,"
        "  updated_at REAL NOT NULL"
        ")"
    )
    return db


def _load_manifest(db: "sqlite3.Connection") -> dict[str, str]:
    """Manifest anterior = o que já está persistido em `files` (path -> hash)."""
    return {path: hash_ for path, hash_ in db.execute("SELECT path, hash FROM files")}


def _next_rowid(db: "sqlite3.Connection") -> int:
    row = db.execute("SELECT COALESCE(MAX(rowid), -1) + 1 FROM files").fetchone()
    return row[0]


def _delete_entry(db: "sqlite3.Connection", path: str) -> None:
    row = db.execute("SELECT rowid FROM files WHERE path = ?", [path]).fetchone()
    if row is None:
        return
    db.execute("DELETE FROM vec_entries WHERE rowid = ?", [row[0]])
    db.execute("DELETE FROM files WHERE path = ?", [path])


def _upsert_entry(db: "sqlite3.Connection", path: str, hash_: str, snippet: str, vec: list[float]) -> None:
    """Upsert seguro: vec0 NÃO aceita `INSERT OR REPLACE` (constraint de rowid) — o padrão
    correto é DELETE + INSERT (verificado; ver DESIGN_RAG_HIBRIDO.md)."""
    existing = db.execute("SELECT rowid FROM files WHERE path = ?", [path]).fetchone()
    rowid = existing[0] if existing is not None else _next_rowid(db)
    db.execute("DELETE FROM vec_entries WHERE rowid = ?", [rowid])
    db.execute("INSERT INTO vec_entries(rowid, embedding) VALUES (?, ?)", [rowid, serialize_float32(vec)])
    db.execute(
        "INSERT INTO files(rowid, path, hash, corpus, snippet, updated_at) VALUES (?, ?, ?, ?, ?, ?) "
        "ON CONFLICT(path) DO UPDATE SET hash=excluded.hash, corpus=excluded.corpus, "
        "snippet=excluded.snippet, updated_at=excluded.updated_at",
        [rowid, path, hash_, corpus_of(path), snippet, time.time()],
    )


# ─────────────────────────────────────────────────────────────────────────
# Ollama (única dependência de rede — sempre localhost)
# ─────────────────────────────────────────────────────────────────────────

# Motivos de falha do embed — o server SABE distinguir, então NÃO joga a ambiguidade
# "Ollama rodando? modelo baixado?" no usuário (achado 3 de SEMANTIC_KB_FAILFAST).
EMBED_OFFLINE = "offline"      # ConnectError — Ollama não está no ar
EMBED_NO_MODEL = "no-model"    # 404 — Ollama no ar, mas o modelo não foi baixado
EMBED_TOO_LARGE = "too-large"  # 500 de tamanho — Ollama RESPONDEU; o texto passou do context length
EMBED_OTHER = "other"          # outro erro HTTP (raro)

# Marcadores do corpo do 500 que o Ollama devolve quando o texto passa do context length do
# modelo. Verificado nesta máquina (2026-08-17, `nomic-embed-text`, ~10K chars):
# `HTTP 500 {"error":"the input length exceeds the context length"}` — ele NÃO trunca, rejeita.
# Distinguir isto de EMBED_OTHER é o ponto: é falha DETERMINÍSTICA e LOCAL AO ARQUIVO, não infra,
# e o server sabe a diferença — jogá-la em "other" faz o usuário ler "não contatei o Ollama" para
# um Ollama que respondeu (ver RAG_EMBED_FAILFAST no BACKLOG).
TOO_LARGE_MARKERS = (
    "input length exceeds",
    "exceeds the context length",
    "context length exceeded",
)


def _is_too_large(response: "httpx.Response") -> bool:
    """O 500 é de TAMANHO? Decide pelo corpo da resposta, não por um limiar hardcoded — o limite
    depende do modelo e do `num_ctx`, então medir um número aqui envelheceria na primeira troca de
    modelo. Ler o corpo pode falhar (resposta em streaming já consumida): nesse caso responde False
    e a falha cai em EMBED_OTHER, que é o comportamento conservador."""
    try:
        body = response.text.lower()
    except Exception:  # noqa: BLE001 - corpo indisponível não é motivo p/ derrubar o reindex
        return False
    return any(m in body for m in TOO_LARGE_MARKERS)


@asynccontextmanager
async def _embed_client(client: "httpx.AsyncClient | None" = None):
    """Cede um `AsyncClient` para uma chamada de embed, com POSSE explícita: se o chamador trouxe
    o seu (o loop do `_reindex`), cede o MESMO objeto e NÃO o fecha — fechar aqui mataria o pool
    para os arquivos seguintes; se não trouxe (o `semantic_search`, chamada única), cria um e
    fecha ao sair. Medido em 2026-08-07: criar um client por requisição custa ~16,4 ms/req de
    setup de transport/pool contra loopback (19,210 × 2,768 ms/req, 200 POSTs) — não é handshake
    TLS (não há TLS em localhost), é a montagem do pool. Client GLOBAL está fora por medição:
    guardado entre event loops dá `RuntimeError: Event loop is closed` na 2ª chamada (3/3)."""
    if client is not None:
        yield client
    else:
        async with httpx.AsyncClient(timeout=TIMEOUT) as owned:
            yield owned


async def _embed(
    text: str, client: "httpx.AsyncClient | None" = None
) -> tuple[list[float] | None, str | None]:
    """Chama Ollama /api/embeddings. Devolve `(embedding, None)` em sucesso ou `(None, motivo)`
    onde motivo ∈ {offline, no-model, too-large, other} — o chamador escolhe a mensagem exata p/ cada causa
    (não devolve None genérico, que apagaria a diferença que o server conhece). `client` é
    opcional: quem chama em LOTE passa o seu p/ reusar a conexão (ver `_embed_client`)."""
    payload = {"model": EMBED_MODEL, "prompt": text}
    try:
        async with _embed_client(client) as c:
            r = await c.post(f"{OLLAMA_HOST}/api/embeddings", json=payload)
            r.raise_for_status()
            return r.json().get("embedding"), None
    except httpx.HTTPStatusError as e:
        if e.response.status_code == 404:
            return None, EMBED_NO_MODEL
        if _is_too_large(e.response):
            return None, EMBED_TOO_LARGE
        return None, EMBED_OTHER
    except httpx.ConnectError:
        return None, EMBED_OFFLINE
    except httpx.HTTPError:
        return None, EMBED_OTHER


async def _probe_ollama() -> str | None:
    """Probe barato de disponibilidade ANTES do loop de embeddings (fail-fast). Devolve None se o
    Ollama responde, ou o motivo (offline/other) se não. NÃO cobre "modelo não baixado" — o
    /api/tags responde mesmo sem o modelo; esse caso cai no circuit breaker do loop."""
    try:
        async with httpx.AsyncClient(timeout=PROBE_TIMEOUT) as client:
            r = await client.get(f"{OLLAMA_HOST}/api/tags")
            r.raise_for_status()
        return None
    except httpx.ConnectError:
        return EMBED_OFFLINE
    except httpx.HTTPError:
        return EMBED_OTHER


def _embed_hint(reason: str | None) -> str:
    """Frase honesta por modo de falha — distingue Ollama-fora-do-ar de modelo-não-baixado e deixa
    explícito que busca semântica é infra LOCAL e OPCIONAL do scaffold, NÃO pendência do projeto
    (é o ruído cognitivo que o achado 3 relatou). Fonte única da mensagem p/ reindex e search."""
    if reason == EMBED_NO_MODEL:
        return f"modelo de embedding '{EMBED_MODEL}' nao baixado no Ollama — rode: ollama pull {EMBED_MODEL}"
    if reason == EMBED_TOO_LARGE:
        return (f"acima do limite de contexto do modelo '{EMBED_MODEL}' — o Ollama RESPONDEU, nao e "
                f"falha de infra; estes arquivos ficaram FORA do indice e o resto do lote foi indexado")
    if reason == EMBED_OFFLINE:
        return (f"Ollama nao esta no ar em {OLLAMA_HOST} — busca semantica e infra LOCAL e OPCIONAL "
                f"do scaffold, nada do projeto quebra; para ligar: ollama serve")
    return f"nao foi possivel contatar o Ollama em {OLLAMA_HOST} (busca semantica e opcional; siga)"


# ─────────────────────────────────────────────────────────────────────────
# Tools MCP
# ─────────────────────────────────────────────────────────────────────────

@mcp.tool()
async def reindex(project_root: str = ".") -> str:
    """Reindexa INCREMENTALMENTE o corpus (.claude/kb/, docs/, .claude/sdd/archive/) do
    projeto — só processa arquivos novos ou alterados desde a última chamada (hash SHA-256).
    Nunca roda sozinho: chame isto ao fim de uma onda do /train-kb, /sync-context, /document
    ou /ship (ou manualmente). Não é um processo em segundo plano.

    Args:
        project_root: raiz do projeto a reindexar (default: diretório atual).
    """
    return await _reindex(project_root)


async def _reindex(project_root: str) -> str:
    """Núcleo testável do reindex (separado do decorator `@mcp.tool()` p/ os testes chamarem
    direto). Ordem deliberada: remoções primeiro e COMMITADAS antes de qualquer rede — elas são
    locais e não podem depender do Ollama (achado 2); só então o probe de disponibilidade
    (fail-fast) e o loop de embeddings com circuit breaker."""
    start = time.monotonic()
    try:
        db = _connect(project_root)
    except Exception as e:  # noqa: BLE001
        return f"[erro] não foi possível abrir/preparar o índice sqlite-vec: {e}"

    old_manifest = _load_manifest(db)
    new_manifest = compute_file_manifest(project_root)
    diff = diff_manifest(old_manifest, new_manifest)
    root = Path(project_root).expanduser().resolve()

    # Remoções: I/O local, NÃO precisam de Ollama. Aplica e PERSISTE antes de qualquer embed —
    # senão um reindex só-com-remoções (ou onde todo add foi pulado) descartaria as deleções ao
    # fechar, deixando no índice arquivos que já não existem (achado 2, bug independente).
    for rel in diff["removed"]:
        _delete_entry(db, rel)
    db.commit()

    to_embed = diff["added"] + diff["changed"]
    skipped = 0
    reason = None
    aborted = False
    oversized: list[str] = []

    if to_embed:
        probe = await _probe_ollama()
        if probe is not None:
            # Fail-fast: Ollama fora do ar — 1 requisição (o probe), não N. Marca todos pendentes
            # (hash antigo não é atualizado) p/ a próxima reindexação com o Ollama de pé.
            skipped = len(to_embed)
            reason = probe
        else:
            succeeded = 0
            consecutive = 0
            # UM client para todo o lote: o setup de transport/pool (~16,4 ms/req medidos em
            # loopback) era pago N vezes, uma por arquivo. Escopo do LOOP, não global — client
            # guardado entre event loops dá `RuntimeError: Event loop is closed` (medido, 3/3).
            async with httpx.AsyncClient(timeout=TIMEOUT) as client:
                for i, rel in enumerate(to_embed):
                    text = (root / rel).read_text(encoding="utf-8", errors="ignore")
                    vec, err = await _embed(text, client)
                    if vec is None:
                        if err == EMBED_TOO_LARGE:
                            # NÃO conta no circuit breaker. O breaker existe p/ "os N seguintes
                            # quase certamente falhariam igual" — verdade p/ Ollama fora do ar ou
                            # modelo ausente, FALSO p/ tamanho: o próximo arquivo pode ser pequeno.
                            # Três arquivos grandes seguidos matavam a indexação dos pequenos que
                            # vinham depois. Também não vira `reason`: a mensagem global é sobre
                            # infra, e aqui não há falha de infra — estes ganham segmento próprio,
                            # nomeando o arquivo que ficou de fora.
                            oversized.append(rel)
                            continue
                        reason = err
                        consecutive += 1
                        if consecutive >= CIRCUIT_BREAKER_THRESHOLD and i + 1 < len(to_embed):
                            aborted = True  # os N seguintes quase certamente falhariam igual
                            break
                        continue
                    consecutive = 0
                    succeeded += 1
                    _upsert_entry(db, rel, new_manifest[rel], text[:SNIPPET_LEN], vec)
                    db.commit()  # por-arquivo: reindex interrompido não perde o já processado
            skipped = len(to_embed) - succeeded

    elapsed = time.monotonic() - start
    resumo = (
        f"{len(diff['added'])} adicionados, {len(diff['changed'])} alterados, "
        f"{len(diff['removed'])} removidos, {len(diff['unchanged'])} inalterados"
    )
    if skipped:
        partes = []
        if oversized:
            # Nomear o arquivo é o ponto: "N pulados (nao contatei o Ollama)" não dizia QUAL ficou
            # de fora nem que a causa era o próprio arquivo. Lista truncada p/ não estourar a
            # resposta — o que foi cortado é CONTADO, nunca omitido em silêncio.
            nomes = ", ".join(oversized[:OVERSIZED_REPORT_LIMIT])
            restantes = len(oversized) - OVERSIZED_REPORT_LIMIT
            if restantes > 0:
                nomes += f" (+{restantes} outros)"
            partes.append(f"{len(oversized)} {_embed_hint(EMBED_TOO_LARGE)}: {nomes}")
        if reason is not None:
            detalhe = _embed_hint(reason)
            if aborted:
                detalhe += f"; abortado apos {CIRCUIT_BREAKER_THRESHOLD} falhas seguidas"
            partes.append(detalhe)
        resumo += f", {skipped} pulados ({'; '.join(partes)})"
    return f"{resumo} — {elapsed:.2f}s"


@mcp.tool()
async def semantic_search(query: str, project_root: str = ".", top_k: int = 5) -> str:
    """Busca semântica sobre o que já foi indexado por `reindex` (KB/docs/archive). Prefira
    esta ferramenta a Grep/Glob quando a pergunta é linguagem natural sobre prosa (ex.: "onde
    decidimos X em vez de Y?") — não para símbolo/arquivo exato, onde Grep/Glob continuam
    melhores. Retorna path + score + trecho curto por resultado — NUNCA o arquivo inteiro;
    use Read no path retornado se precisar do conteúdo completo.

    Args:
        query: a pergunta/busca em linguagem natural.
        project_root: raiz do projeto (default: diretório atual).
        top_k: quantos resultados retornar (default 5).
    """
    vec, err = await _embed(query)
    if vec is None:
        return f"[indisponivel] {_embed_hint(err)}"

    try:
        db = _connect(project_root)
    except Exception as e:  # noqa: BLE001
        return f"[erro] não foi possível abrir o índice sqlite-vec: {e}"

    rows = db.execute(
        "SELECT f.path, f.snippet, v.distance FROM vec_entries v "
        "JOIN files f ON f.rowid = v.rowid "
        "WHERE v.embedding MATCH ? AND k = ? "
        "ORDER BY v.distance",
        [serialize_float32(vec), top_k],
    ).fetchall()

    if not rows:
        return "Nenhum resultado — rode reindex primeiro, ou o índice ainda está vazio para este projeto."

    linhas = [
        f"{i}. {path} (score={distance:.4f})\n   {snippet}"
        for i, (path, snippet, distance) in enumerate(rows, start=1)
    ]
    return "\n".join(linhas)


if __name__ == "__main__":
    mcp.run()
