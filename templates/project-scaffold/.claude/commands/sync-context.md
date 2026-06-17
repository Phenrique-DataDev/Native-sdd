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

## Passo 1 — Carregar inventários (reuso G2/G3)

```text
# resolva $toolsRoot pela cascata (rules/tooling.md): relativo → $env:SDD_WORKFLOW_HOME → degradação
. "$toolsRoot/agent-lint.ps1"   ; Get-AgentInventory -Dir .claude/agents
. "$toolsRoot/kb-lint.ps1"      ; Get-KbInventory    -Dir .claude/kb
. "$toolsRoot/graph-export.ps1" # regenera o grafo no Passo 2b (reusa o parser do agent-lint)
Glob(".claude/commands/*.md")
```

Não reimplemente a leitura de frontmatter — use as funções existentes.

---

## Passo 2 — Regenerar `AGENT_MAP.md` (100% gerado)

`Build-AgentMap -Agents <inventário> -Commands <nomes>` → escreva o resultado **inteiro** em
`.claude/agents/AGENT_MAP.md`. O arquivo é **gerado**: traz o aviso "não editar à mão" e um
grafo Mermaid determinístico (comandos + agentes de núcleo/domínio, ordenados).

---

## Passo 2b — Regenerar o grafo **unificado** (`graph.json` + `graph.cypher`, 100% gerado)

`Invoke-GraphExport -Dir .claude/agents` → regenera `.claude/agents/graph.json` (property-graph
portável) **e** `.claude/agents/graph.cypher` (dump `CREATE` p/ neo4j) — o **grafo unificado** (**H9**):
**agentes** (`role`/`connects_to`) **+ KB** (`:KbEntry` com `related`/`consolidates`/`promoted_from`/
`:IN_DOMAIN`) **+ skills** (`:Skill` + `:PRESUPPOSES`) **+ domínios** (`:Domain`, a junção) **+ o elo
`:USES_SKILL`** (derivado via domínio + override `skills_used`) **+ o `:Hub` orquestrador-mestre** (o
líder do MAX, ligado a **todos** os agentes por `:ORCHESTRATES` — o **ápice** do grafo). Como o
`AGENT_MAP.md`, são **100% gerados** e determinísticos — nós/arestas ordenados, **LF** — e não se editam à mão. Reusa
`Read-KbFrontmatter`/`Get-SkillInventory`/`Get-DeclaredSkills` (sem varredura nova); o `AGENT_MAP.md`
(Mermaid, humano) e o grafo (JSON/Cypher, máquina) saem do **mesmo estado curado**, sempre em sincronia.

**Escopo do artefato commitado = project-scope** (determinístico/portável). Skills **global-scoped**
(`~/.claude/skills`, por-máquina) **não** entram no commitado — use `Invoke-GraphExport -IncludeGlobal`
**on-demand** (visão local "cérebro completo", **não** versionar).

**Ver o grafo (sem servidor):** `Invoke-GraphExport -Html` gera também `graph.html` — uma página
**interativa** (arrastar/zoom/clicar; cor por tipo de nó) que abre direto no navegador, **sem neo4j nem
qualquer serviço**. É **opt-in** e **gitignored** (view regenerável, não versionada). O `graph.cypher`
segue pronto p/ importar no neo4j **se** o volume um dia justificar (servidor adiado, `[[H4]]`).

Com `--dry-run`, passe `-DryRun` (não escreve; só reporta nós/arestas). O **`:Hub` orquestrador-mestre é
o ápice permanente** do grafo (o líder sempre orquestra os experts; o **MAX** apenas amplifica esse hub);
`-NoHub` dá a view **só-pares** (raro, p/ inspecionar a estrutura sem o ápice).

---

## Passo 3 — Gerar `.claude/kb/_index.yaml` (100% gerado)

`Build-KbIndex -Entries <inventário>` → escreva em `.claude/kb/_index.yaml`. Por domínio
(ordenado): `layer`, `entries`, `unverified`. KB vazia → `domains: {}`.

---

## Passo 4 — Atualizar ponteiros (só regiões marcadas)

Use `Update-MarkedRegion` para preencher **apenas** o conteúdo entre os marcadores
`<!-- sync-context:start:NAME -->` … `<!-- sync-context:end:NAME -->`:

| Doc | Região (`NAME`) | Conteúdo |
|-----|-----------------|----------|
| `CLAUDE.md` | `commands` | tabela de `/commands` (nome + propósito) |
| `AGENTS.md` | `rules` | lista de `rules/*.md` |
| `AGENTS.md` | `kb` | domínios da KB por camada (de `_index.yaml`) |

Se um marcador não existir, **não escreva** — reporte e siga (a função é fail-safe). Nunca
altere texto fora dos blocos.

---

## Passo 5 — `--dry-run`

Com `--dry-run`, calcule tudo mas **não** salve: liste os arquivos que mudariam e mostre a
prévia do conteúdo gerado. Útil para conferir antes de aplicar.

---

## Passo 6 — Relatório

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
