---
description: "Ressincronizar os índices do projeto a partir do estado curado, sem tocar conteúdo escrito à mão"
---

# /sync-context — ressincronizar os índices do projeto

Regenera os **índices** do projeto a partir do estado real curado (agentes do `/audit-agents`
e KB do `/train-kb`) e atualiza os **ponteiros** nos docs canônicos — **sem tocar conteúdo
escrito à mão**. Fecha o loop da especialização: depois de rodar, o `git diff` mostra **só
índices/refs**.

> Feature **G4** (EPIC G — curadoria/auto-otimização). Reusa os inventários do **G2**
> (`Get-AgentInventory`) e do **G3** (`Get-KbInventory`); não reimplementa varredura.

---

## Uso

```text
/sync-context              # regenera índices + ponteiros
/sync-context --dry-run    # mostra o que mudaria, sem salvar (prova "git diff só índices")
```

---

## Passo 0 — Estado atual

Roda sobre o estado atual do repo (sem gate rígido). Se `.claude/agents/` só tem os genéricos
ou a KB está vazia, o comando ainda roda — os índices apenas refletem o que existe. Avise o
usuário se nada foi curado ainda (talvez ele queira rodar `/audit-agents` / `/train-kb` antes).

---

## Passo 1 — Carregar o driver de resync (fonte única)

```text
# resolva $toolsRoot pela cascata (rules/tooling.md): relativo → $env:SDD_WORKFLOW_HOME → degradação
. "$toolsRoot/resync.ps1"   # Invoke-Resync — reusa Build-AgentMap/Build-KbIndex/Invoke-GraphExport
```

A regeneração dos **3 artefatos derivados** (mapa + grafo + índice-KB) é do **`Invoke-Resync`**
(feature `auto-resync`) — a **mesma** função que a criação (`/audit-agents`·`/train-kb`·`/skill-gap`)
chama ao fechar o ciclo. Não refie os geradores à mão aqui; o driver é a **fonte única**.

---

## Passo 2 — Regenerar os artefatos derivados (100% gerados)

`Invoke-Resync -ClaudeDir .claude -Write` → regenera, de forma **determinística** e **idempotente**
(2× = mesmos bytes; nós/entradas ordenados, **LF**, UTF-8 sem BOM), os três:

| Artefato | O que é |
|----------|---------|
| `.claude/agents/AGENT_MAP.md` | grafo **Mermaid** humano (comandos + agentes de núcleo/domínio, ordenados) |
| `.claude/agents/graph.json` + `graph.cypher` | o **grafo unificado** (**H9**): agentes (`role`/`connects_to`) **+ KB** (`:KbEntry`, `:IN_DOMAIN`) **+ skills** (`:Skill`/`:PRESUPPOSES`) **+ domínios** (`:Domain`) **+ `:USES_SKILL`** **+ o `:Hub`** orquestrador-mestre (`:ORCHESTRATES` a todos — o **ápice**). JSON p/ consulta, Cypher p/ neo4j |
| `.claude/kb/_index.yaml` | domínios da KB (ordenados): `layer`/`entries`/`unverified`. KB vazia → `domains: {}` |

O `AGENT_MAP.md` (humano) e o grafo (máquina) saem do **mesmo estado curado**, sempre em sincronia —
`Invoke-Resync` só escreve o que **divergiu** (`-Write` é idempotente). São **100% gerados** — não editar à mão.

**Escopo do artefato commitado = project-scope** (determinístico/portável). Skills **global-scoped**
(`~/.claude/skills`, por-máquina) **não** entram no commitado — `Invoke-GraphExport -IncludeGlobal` dá a
visão local "cérebro completo" **on-demand** (**não** versionar).

**Ver o grafo (sem servidor):** `Invoke-GraphExport -Html` gera `graph.html` — página **interativa**
(arrastar/zoom/clicar) que abre no navegador, **sem neo4j**. **Opt-in** e **gitignored** (view
regenerável). O `graph.cypher` segue pronto p/ o neo4j **se** o volume um dia justificar.

Com `--dry-run`, passe `-Check` no lugar de `-Write` (não escreve; devolve o **drift** por artefato).

---

## Passo 3 — Atualizar ponteiros (só regiões marcadas)

Use `Update-MarkedRegion` para preencher **apenas** o conteúdo entre os marcadores
`<!-- sync-context:start:NAME -->` … `<!-- sync-context:end:NAME -->`:

| Doc | Região (`NAME`) | Conteúdo |
|-----|-----------------|----------|
| `CLAUDE.md` | `commands` | tabela de `/commands` (nome + propósito, **1 linha curta cada**) |
| `AGENTS.md` | `rules` | lista de `rules/*.md` (**1 linha curta cada** — ver orçamento abaixo) |
| `AGENTS.md` | `kb` | domínios da KB por camada (de `_index.yaml`) |

### Orçamento destes blocos — são **sumários**, não cópias da regra

Estes blocos são **always-on**: entram no contexto de **toda** sessão, para sempre. Uma descrição
longa aqui é **custo puro** — no Claude Code o arquivo da regra **já está inteiro no contexto** (o
harness varre `.claude/rules/`), então repetir o conteúdo dela aqui não informa nada novo.

- **Uma linha por item, ≤ ~12 palavras:** *o que é* + *quando serve* + o command entre parênteses.
- **Não** copie detalhes de implementação, condições, dependências ou ressalvas da regra — o leitor
  que precisa disso lê o arquivo.
- O sumário existe para os harnesses que **não** auto-carregam `.claude/rules/` (Codex, Cursor): é
  como eles descobrem que a regra existe. Por isso o bloco **fica** — mas enxuto.

> Em 2026-07-13 este bloco custava **1.120 tok** (descrições de 2-3 linhas) e foi enxugado para
> ~370. Regenerar "caprichado" **desfaz** a economia: caprichar aqui é **encurtar**.

---

## Passo 4 — `--dry-run`

Com `--dry-run`, rode `Invoke-Resync -ClaudeDir .claude -Check` (não escreve; devolve o drift por
artefato) e apenas **liste** o que mudaria nos ponteiros — sem salvar. Útil para conferir antes de aplicar.

**Busca semântica (opt-in, degrada em silêncio):** fora de `--dry-run`, se a tool
`mcp__semantic-kb__reindex` estiver disponível, chame `reindex(project_root=".")` — mesmo
ponto natural de "índices desatualizados" deste comando. Sem o MCP instalado (padrão), pule
sem avisar (ver [`semantic-search.md`](../rules/semantic-search.md)).

---

## Passo 5 — Relatório

```text
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
SYNC-CONTEXT — {NOME_PROJETO}
AGENT_MAP.md: {atualizado|sem mudança}   grafo (json/cypher): {atualizado|sem mudança}
kb/_index.yaml: {atualizado|sem mudança}
Ponteiros: commands {…} · rules {…} · kb {…}
→ Confira: git diff  (deve mostrar só índices/refs)
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
```

---

## Idempotência e regras

- **Idempotência:** rodar 2× sobre o mesmo estado → `git diff` **vazio** (saída determinística,
  sem timestamps no conteúdo gerado).
- **Nunca** escrever fora das regiões marcadas nem fora dos arquivos gerados.
- Os artefatos gerados (`AGENT_MAP.md`, `graph.json`, `graph.cypher`, `_index.yaml`) são **100%
  derivados** do estado curado — não editar à mão (`graph.*` saem em **LF**; a determinismo deles é
  o que mantém o `git diff` vazio na 2ª passada).
- O comando **não** orquestra a curadoria (isso é o **G1**); ele só reflete o estado atual.
