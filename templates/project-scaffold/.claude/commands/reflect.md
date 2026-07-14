---
description: "Consolidar/compactar a KB (MERGE/COMPRESS/PRUNE) de forma nunca-destrutiva e verificável"
---

# /reflect — consolidar/compactar a KB (G6)

> Quando a KB cresce, consolida o conjunto (**MERGE/COMPRESS/PRUNE**) **preservando regras + casos**,
> de forma **nunca-destrutiva** (plano → aprova → aplica) e **verificável** (nenhum `id` some sem
> rastro). Gatilho determinístico e verificação em `tools/reflect.ps1` (reusa o `kb-lint`/B7); o
> julgamento é seu (LLM).
>
> **Este command é a fonte única da postura** — não há rule sempre-ativa correspondente. O protocolo
> inteiro está aqui e carrega **sob demanda**.

## Princípio

A KB só **cresce** (`/train-kb` adiciona; nada consolida) — acumula o mesmo conceito em 2 entradas,
prosa verbosa e conhecimento superado, o que incha o contexto e **dilui o sinal**. O que decide *o
que* consolidar é julgamento do LLM; o que torna isso seguro é o protocolo abaixo + a verificação de
proveniência. Distinto do [`/learn`](learn.md), que **capta o novo** (promove lição do `SHIPPED`):
o `/reflect` consolida o que **já está** na KB.

## Quando usar

- Manualmente, quando a KB ficou grande/redundante.
- Quando o **`curation-nudge`** avisar "KB acima do budget agregado — considere `/reflect`".

## O que preservar × o que encolher (o critério do fan-out)

| Preservar (sinal durável) | Encolher (inchaço) |
|---------------------------|--------------------|
| **Regra implementada** no processo | duplicação (mesmo conceito em N entradas) |
| **Caso ocorrido** (decisão, incidente, exceção) | prosa verbosa em torno da regra/caso |
| Proveniência (de onde veio) | conhecimento **superado**/contradito |

## As 3 operações

| Operação | Quando | Resultado |
|----------|--------|-----------|
| **MERGE** (fundir) | 2+ entradas capturam o **mesmo** conceito | 1 entrada; a sobrevivente lista `consolidates: [ids]` |
| **COMPRESS** (resumir) | 1 entrada verbosa | regra + caso **verbatim**, prosa cortada (mesma entrada/id) |
| **PRUNE** (podar) | entrada **superada/contradita** | removida; a entrada que a supera lista `supersedes: [ids]` |

## Passos

**Passo 0 — gatilho.** Rode a parte determinística:
```powershell
# resolva $toolsRoot pela cascata (rules/tooling.md): relativo → $env:SDD_WORKFLOW_HOME → degradação
. "$toolsRoot/reflect.ps1"
$b = Test-KbOverBudget -Dir .claude/kb
Format-ReflectReport -Budget $b
```
Se `$b.OverBudget` for `$false` → **pare** e relate "KB enxuta, nada a consolidar" (no-op).

**Passo 1 — mapear unidades.** `Get-KbInventory -Dir .claude/kb` agrupado por **camada×domínio**;
selecione as unidades acima do budget ou com entradas `OverBudget` (`Test-KbEntrySize`). **Snapshot
dos `id` atuais** (você vai verificar contra ele no Passo 6).

**Passo 2 — fan-out.** Para cada unidade, invoque um subagente (`Agent`) passando **o critério
"preservar × encolher" + as 3 operações** (tabelas acima) + as entradas da unidade. O subagente propõe
**MERGE/COMPRESS/PRUNE** **preservando regras+casos verbatim**, indicando a proveniência (quem absorve
quem). Unidades independentes podem rodar em paralelo (várias chamadas `Agent` na mesma mensagem).

**Passo 3 — plano.** Consolide as propostas num plano em
`.claude/kb/_reflections/<YYYY-MM-DD>-plan.md`: por unidade, cada operação com `action`
(merge/compress/prune), `targets` (ids), `rationale` e `provenance`. Relate o resumo ao usuário
(tamanho antes×depois estimado, nº de operações).

**Passo 4 — aprovação.** `AskUserQuestion`: **aplicar tudo** / **escolher unidades** / **só o plano**.
Sem aprovação → **fim, KB intocada**.

**Passo 5 — aplicar (nunca-destrutivo).** Para o que foi aprovado:
- **Backup** das entradas afetadas (não apague sem backup) — **FORA de `.claude/kb/`**, em
  `.claude/.cache/kb-backup/<data>/` (gitignored). **Nunca** ao lado do plano em `_reflections/`:
  backup dentro da KB fica invisível ao lint e duplica o `id` no grafo (`kb-lint`: `misplaced-entry`).
- Grave `consolidates`/`supersedes` no frontmatter das **sobreviventes**.
- Remova as entradas absorvidas/podadas.
- Registre no **ledger** `.claude/kb/_reflections/<YYYY-MM-DD>.md` (plano aplicado + onde foram os backups).

**Passo 6 — verificar.** Rode a pós-condição contra o snapshot do Passo 1:
```powershell
$f = Test-ReflectProvenance -BeforeIds $idsAntes -Dir .claude/kb
Format-ReflectReport -Findings $f
```
**≥1 finding `id-lost-without-trace` → reverta do backup e avise** (a consolidação não fica pela
metade). 0 findings → siga.

**Passo 7 — reindexar.** Rode **`/sync-context`** (G4) para `_index.yaml`/ponteiros refletirem o novo
estado. Relatório final: entradas fundidas/podadas/resumidas + tamanho antes×depois.

## Regras

- **Nunca** apague sem **backup + plano aprovado**; **nunca** descarte regra/caso (só inchaço).
- **Nunca** apague uma entrada sem registrá-la em `consolidates`/`supersedes` de uma sobrevivente.
- **Sem MERGE cross-domínio** (consolide dentro do domínio).
- `id` único por domínio preservado; entradas seguem o frontmatter da `kb-taxonomy.md`.
- Se a KB estiver enxuta → **no-op** silencioso (não force consolidação).
- Sem engine/scoring — `Agent` nativo + a verificação determinística (`tools/reflect.ps1`).
