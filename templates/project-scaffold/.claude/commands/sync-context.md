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
. "$toolsRoot/agent-lint.ps1" ; Get-AgentInventory -Dir .claude/agents
. "$toolsRoot/kb-lint.ps1"    ; Get-KbInventory   -Dir .claude/kb
Glob(".claude/commands/*.md")
```

Não reimplemente a leitura de frontmatter — use as funções existentes.

---

## Passo 2 — Regenerar `AGENT_MAP.md` (100% gerado)

`Build-AgentMap -Agents <inventário> -Commands <nomes>` → escreva o resultado **inteiro** em
`.claude/agents/AGENT_MAP.md`. O arquivo é **gerado**: traz o aviso "não editar à mão" e um
grafo Mermaid determinístico (comandos + agentes de núcleo/domínio, ordenados).

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
AGENT_MAP.md: {atualizado|sem mudança}   kb/_index.yaml: {atualizado|sem mudança}
Ponteiros: commands {…} · rules {…} · kb {…}
→ Confira: git diff  (deve mostrar só índices/refs)
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
```

---

## Idempotência e regras

- **Idempotência:** rodar 2× sobre o mesmo estado → `git diff` **vazio** (saída determinística,
  sem timestamps no conteúdo gerado).
- **Nunca** escrever fora das regiões marcadas nem fora dos arquivos gerados.
- Os artefatos gerados (`AGENT_MAP.md`, `_index.yaml`) trazem aviso "não editar à mão".
- O comando **não** orquestra a curadoria (isso é o **G1**); ele só reflete o estado atual.
