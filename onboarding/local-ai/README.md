# local-ai — MCP de modelo local (Ollama) para o Claude Code

Suplemento **opt-in** que deixa o Claude Code **delegar trabalho pesado a um modelo local**
(via [Ollama](https://ollama.com)) em vez de gastar a própria cota. O Claude **orquestra e
decide**; o modelo local é o **trabalhador** — revisão de código, análise de segurança
defensiva, geração volumosa. Tudo **offline**, **sem custo de API** e com o **código nunca
saindo da máquina**.

> Provisionamento espelha o padrão do `context7`: **não bloqueante** (falha = aviso, nunca
> quebra o onboarding) e **idempotente**. Off por padrão — exige Ollama + `uv` e baixa um
> modelo pesado (GBs).

## O que vem aqui

| Arquivo | Papel |
|---------|-------|
| `server.py` | Servidor MCP (FastMCP + httpx). Expõe 4 tools ao Claude. |
| `pyproject.toml` | Deps do server (`mcp[cli]`, `httpx`), gerenciadas pelo `uv`. |
| `bench.py` | Utilitário de validação: latência, throughput e qualidade dos modelos. |
| `install-local-ai.sh` | Instalador autônomo (macOS/Linux). |

No Windows o provisionamento é feito por `onboarding/windows/install-local-ai.ps1` (disparado
pelo onboarding com `-WithLocalAi`).

## Tools expostas

Todas aceitam `save_to` (caminho de arquivo): quando preenchido, a saída **completa** é gravada
no arquivo e o Claude recebe **só um resumo curto + o caminho** — economia máxima de contexto
(~94% medido).

| Tool | Para quê |
|------|----------|
| `ask_local_model` | Pergunta/instrução livre ao modelo local. |
| `local_code_review` | Revisão de código (bugs, design, legibilidade). |
| `local_security_review` | Análise de segurança **defensiva** (vulnerabilidades + mitigação). |
| `list_local_models` | Lista modelos no Ollama e o roteamento atual. |

Roteamento por tarefa via env vars no registro: `CODE_MODEL`, `SECURITY_MODEL`, `GENERAL_MODEL`
(default: o mesmo modelo em tudo), `OLLAMA_HOST`.

## Pré-requisitos

- **Ollama** — `winget install Ollama.Ollama` (Windows) · `curl -fsSL https://ollama.com/install.sh | sh` (macOS/Linux). Depois rode `ollama serve`.
- **uv** — runner/venv do server (já instalado pelo onboarding A1).
- **Claude Code** (`claude` no PATH) — para registrar o MCP.
- **Hardware** — `gpt-oss:20b` pede ~16 GB de VRAM. Pouca GPU? Use um modelo menor (ver abaixo).

## Instalar (pré-pronto)

### Windows — via onboarding
```powershell
# instala/registra o local-ai junto do ambiente:
.\onboarding\install.ps1 -WithLocalAi
# modelo mais leve (pouca VRAM/RAM):
.\onboarding\install.ps1 -WithLocalAi -LocalAiModel qwen2.5-coder:7b
# "doctor" — só relata o que falta, sem instalar:
.\onboarding\install.ps1 -Check -WithLocalAi
```

### macOS / Linux — instalador autônomo
```bash
./onboarding/local-ai/install-local-ai.sh                    # default (gpt-oss:20b)
./onboarding/local-ai/install-local-ai.sh qwen2.5-coder:7b   # modelo mais leve
CHECK=1 ./onboarding/local-ai/install-local-ai.sh            # doctor (não instala)
```

Os dois fazem o mesmo, de forma idempotente e não bloqueante: `uv sync` → `ollama pull <modelo>`
→ `claude mcp add local-ai --scope user`. **Reinicie o Claude Code** ao final para carregar o MCP.

## Usar (basta pedir ao Claude)

> *"Faça uma análise de segurança local do `app.py` e **salve em** `analises/app.md`."*

O Claude chama `local_security_review(..., save_to="analises/app.md")` sozinho, lê só o resumo e
abre o arquivo se precisar dos detalhes. **Sem `save_to`**, a análise inteira volta ao contexto
(útil para trabalhar em cima dela na hora).

## Validar (qualidade e economia)

```bash
cd onboarding/local-ai && uv run python bench.py
```
Mede latência, throughput (tok/s) e acerto sobre um código com vulnerabilidades plantadas
(gabarito embutido) — base para escolher o modelo e estimar a economia de tokens.

## Trocar de modelo

1. `ollama pull <novo-modelo>`
2. Re-registre apontando as env vars ao novo modelo (re-rode o instalador com o modelo desejado,
   ou `claude mcp remove local-ai` + `claude mcp add ...`).
3. Reinicie o Claude Code.

## Hardware × modelo

O instalador **avisa** (best-effort, GPUs NVIDIA via `nvidia-smi`) quando a VRAM detectada é menor
que a sugerida para o modelo — mas **não bloqueia** nem ajusta sozinho. Referência aproximada
(quantização Q4, ~0.7 GB por bilhão de parâmetros):

| Modelo | VRAM sugerida |
|--------|---------------|
| `gpt-oss:20b` (default) | ~14–16 GB |
| `qwen2.5-coder:14b` | ~10 GB |
| `qwen2.5-coder:7b` / `llama3.1:8b` | ~6 GB |

GPU AMD/Intel ou CPU-only: a detecção fica em silêncio (desconhecida) — escolha o modelo à mão via
`-LocalAiModel` / argumento do `.sh`. Sem GPU adequada, prefira um modelo de 7–8B.

## Ollama em outra máquina

Por padrão o registro aponta para `http://localhost:11434`. Para usar um Ollama remoto:

```powershell
.\onboarding\install.ps1 -WithLocalAi -LocalAiOllamaHost http://192.168.0.10:11434
```
```bash
OLLAMA_HOST=http://192.168.0.10:11434 ./onboarding/local-ai/install-local-ai.sh
```

## Notas operacionais

- O registro do MCP **não exige** o Ollama no ar — o `server.py` degrada com mensagem amigável
  (`[erro] … ollama serve`) se o serviço/modelo faltar.
- **Registro é por máquina e grava caminho absoluto.** O MCP é registrado *user-scoped* apontando
  para `…/onboarding/local-ai` (path absoluto deste clone). **Se você mover/renomear o clone**, o MCP
  quebra — reinstale (`claude mcp remove local-ai` + `install.ps1 -WithLocalAi`). Cada máquina precisa
  rodar o instalador (não há nada a versionar). Tudo é *user-scoped* — **não exige admin/UAC**.
- `gpt-oss:20b` é MoE/reasoning: a 1ª carga (fria) é lenta; aquecido, voa. Timeout do server: 900 s.
- Artefatos de runtime (`.venv/`, `analises/`, `bench_results.json`) são gitignored.
