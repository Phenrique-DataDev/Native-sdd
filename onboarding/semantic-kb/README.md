# semantic-kb — MCP de busca semântica local (Ollama + sqlite-vec) para o Claude Code

Suplemento **opt-in** que deixa o Claude Code fazer **busca semântica** (linguagem natural, não
palavra-chave exata) sobre a KB, `docs/` e o histórico de features arquivado (`.claude/sdd/
archive/`) de um projeto scaffolded. **Complementa** `Grep`/`Glob` — nunca os substitui. Tudo
**offline**, **sem custo de API** e com o **conteúdo nunca saindo da máquina**.

> **Nunca é um processo em segundo plano.** O índice (`.claude/.cache/semantic-kb/index.db`, por
> projeto, gitignored) é um **artefato gerado** — mesmo molde de `graph.json`/`_index.yaml`
> (regenerados por `/sync-context`). A reindexação é **incremental** (só reprocessa o que mudou,
> por hash SHA-256) e roda em 4 pontos já existentes do fluxo normal (`/train-kb`, `/sync-context`,
> `/document`, `/ship`) — nunca um daemon/watcher contínuo. Ver
> `.claude/sdd/features/DESIGN_RAG_HIBRIDO.md` (raiz do framework) para o desenho completo.

## O que vem aqui

| Arquivo | Papel |
|---------|-------|
| `server.py` | Servidor MCP (FastMCP + httpx + sqlite-vec). Expõe 2 tools ao Claude. |
| `pyproject.toml` | Deps do server (`mcp[cli]`, `httpx`, `sqlite-vec`, `pysqlite3-binary` no macOS), gerenciadas pelo `uv`. |
| `test_server.py` | Testes `pytest` das funções puras (diff incremental) e da camada `sqlite-vec` (upsert/delete/KNN) — rodam sem Ollama. |
| `install-semantic-kb.sh` | Instalador autônomo (macOS/Linux). |

No Windows o provisionamento é feito por `onboarding/windows/install-semantic-kb.ps1` (disparado
pelo onboarding com `-WithSemanticKb`).

## Tools expostas

| Tool | Para quê |
|------|----------|
| `reindex(project_root=".")` | Reindexa **incrementalmente** `.claude/kb/`, `docs/` e `.claude/sdd/archive/` — só processa arquivo novo/alterado (hash). Retorna contagem (adicionados/alterados/removidos/inalterados) + tempo gasto. |
| `semantic_search(query, project_root=".", top_k=5)` | Busca semântica sobre o que já foi indexado. Retorna **path + score + trecho curto** por resultado — **nunca o arquivo inteiro** (economia de contexto); leia o arquivo você mesmo se precisar do conteúdo completo. |

Roteamento de quando usar `semantic_search` em vez de `Grep`/`Glob`:
[`semantic-search.md`](../../templates/project-scaffold/.claude/rules/semantic-search.md).

## Pré-requisitos

- **Ollama** — `winget install Ollama.Ollama` (Windows) · `curl -fsSL https://ollama.com/install.sh | sh` (macOS/Linux). Depois rode `ollama serve`.
- **uv** — runner/venv do server (já instalado pelo onboarding A1).
- **Claude Code** (`claude` no PATH) — para registrar o MCP.
- **Hardware** — `nomic-embed-text` é leve (~274MB); roda bem em CPU, sem exigência de GPU.

## Instalar (pré-pronto)

### Windows — via onboarding
```powershell
# instala/registra o semantic-kb junto do ambiente:
.\onboarding\install.ps1 -WithSemanticKb
# outro modelo de embedding:
.\onboarding\install.ps1 -WithSemanticKb -SemanticKbModel outro-modelo
# "doctor" — só relata o que falta, sem instalar:
.\onboarding\install.ps1 -Check -WithSemanticKb
```

### macOS / Linux — instalador autônomo
```bash
./onboarding/semantic-kb/install-semantic-kb.sh                # default (nomic-embed-text)
CHECK=1 ./onboarding/semantic-kb/install-semantic-kb.sh         # doctor (não instala)
```

Os dois fazem o mesmo, de forma idempotente e não bloqueante: `uv sync` → `ollama pull <modelo>`
→ `claude mcp add semantic-kb --scope user`. **Reinicie o Claude Code** ao final para carregar o
MCP.

**Independente do `local-ai`** — instalar um não instala o outro; ambos usam Ollama, mas baixam
modelos diferentes (embedding vs. chat) e são registrados como MCPs separados.

## Usar (basta pedir ao Claude)

> *"Onde já discutimos usar sqlite-vec em vez de um serviço externo de vetores?"*

Se o MCP estiver instalado, o Claude chama `semantic_search(...)` sozinho (a rule
`semantic-search.md` ensina quando preferir isso a `Grep`) e devolve os paths mais prováveis com
um trecho curto de cada — você (ou o próprio Claude) decide se vale ler o arquivo inteiro.

Reindexar manualmente (raro — os 4 pontos de disparo já cobrem o fluxo normal):

> *"Rode reindex no projeto atual."*

## Validar (testes reais, sem Ollama)

```bash
cd onboarding/semantic-kb && uv run pytest test_server.py -v
```
Cobre a lógica de diff incremental (a prova de que só o que mudou é reprocessado) e a camada
`sqlite-vec` (upsert/delete/busca por similaridade) com vetores fake — não depende do Ollama
estar rodando.

## Notas operacionais

- O registro do MCP **não exige** o Ollama no ar — o `server.py` degrada com mensagem amigável
  (`[erro] … ollama serve`) se o serviço/modelo faltar.
- **Registro é por máquina e grava caminho absoluto.** O MCP é registrado *user-scoped* apontando
  para `…/onboarding/semantic-kb` (path absoluto deste clone). **Se você mover/renomear o clone**,
  o MCP quebra — reinstale (`claude mcp remove semantic-kb` + `install.ps1 -WithSemanticKb`). Cada
  máquina precisa rodar o instalador (não há nada a versionar). Tudo é *user-scoped* — **não
  exige admin/UAC**.
- **Índice é por-projeto:** o `project_root` passado em cada chamada decide qual `.claude/.cache/
  semantic-kb/index.db` é lido/escrito — um único MCP (registrado uma vez) serve qualquer projeto.
- **macOS:** o Python bundled do sistema não suporta carregar extensões SQLite
  (`enable_load_extension`) — o `pyproject.toml` já declara `pysqlite3-binary` como dependência
  condicional (`sys_platform == 'darwin'`) para contornar isso automaticamente.
- Artefatos de runtime (`.venv/`, `__pycache__/`, `uv.lock`, `.pytest_cache/`) são gitignored (ver
  `.gitignore` desta pasta); o índice por-projeto (`.claude/.cache/semantic-kb/`) é gitignored no
  **projeto-alvo**, não aqui.
