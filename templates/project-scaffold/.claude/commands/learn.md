---
description: "Promover lição recorrente do acervo de SHIPPED a uma entrada de KB operations"
argument-hint: "(sem argumento — varre o acervo)"
---

# /learn — fechar o loop de boas práticas

Relê o acervo de **`SHIPPED`**, detecta a lição **recorrente** (que se repete entre features) e a
**promove** a uma entrada de KB `operations` reaplicável. **Nunca-destrutivo** (plano → aprova → aplica),
com **proveniência** (`promoted_from`). Sem engine (reusa o molde do `/reflect`/G6).

> Distinto do `/reflect` (consolida o que **já está** na KB) e do `documenter` (registra ADRs em
> `docs/`): o `/learn` **capta o novo** — promove a prática que o uso real revelou.
>
> **Este command é a fonte única da postura** — não há rule sempre-ativa correspondente. O protocolo
> inteiro está aqui e carrega **sob demanda**.

---

## Princípio

Boas práticas descobertas no **uso real** só viram valor quando **promovidas** a conhecimento
reaplicável. O `/ship` arquiva "Lições aprendidas" em `SHIPPED_*.md` — acervo que ninguém relê. O
`/learn` fecha esse loop: uma lição vira **prática** quando se **repete** (≥2 features). Destino é a KB
camada `operations` — **não** uma rule sempre-ativa (mantém `rules/` enxuta e reusa a infra de KB).

## O que é promovível (o critério do fan-out)

| Promove (sinal durável, reaplicável) | NÃO promove |
|--------------------------------------|-------------|
| **prática recorrente** (mesma lição em ≥2 features) | lição **pontual**/one-off de um ciclo só |
| "sempre rode X antes de Y" / "valide Z assim" (processo) | aprendizado já coberto pela KB factual (`/train-kb`) |
| armadilha técnica que se repete e tem mitigação clara | wording/nota efêmera sem padrão |

Insumo: cada lição no `SHIPPED` é marcada `[candidata]` (promovível) ou `[pontual]` (one-off) pelo
[`/ship`](ship.md). O gatilho conta as `[candidata]` **ainda não promovidas**.

---

## Passo 0 — Gatilho (no-op sob o limiar)

Resolva `$toolsRoot` pela cascata de [`rules/tooling.md`](../rules/tooling.md) e verifique se há candidatas:

```powershell
. "$toolsRoot/learn.ps1"
$status = Test-LessonsReady -ArchiveDir .claude/sdd/archive -KbDir .claude/kb
```

`$status.Ready` **falso** → **no-op**: avise *"acervo sem lições recorrentes suficientes (pendentes
$($status.PendingCount)/$($status.Threshold)) — nada a promover"* e **encerre**. Verdadeiro → siga.

> **"Tem trabalho?" ≠ "devo avisar?"** — `Test-LessonsReady` (usada **aqui**) responde ao **estado**:
> quem digita `/learn` quer ver o **backlog inteiro**. O hook `curation-nudge` usa outra função
> (`Get-LessonsNudgeDecision`, com **histerese**) para decidir se **avisa** — só quando há candidatas
> **novas** desde o último aviso. Fundir as duas produz um **nudge eterno**, e isso já aconteceu: o
> acervo de `SHIPPED` só **cresce**, então um limiar absoluto fica verdadeiro **para sempre**.
> **Silenciar o aviso nunca esconde o backlog de quem digita `/learn` de propósito.**

---

## Passo 1 — Agrupar candidatas por domínio

`$status.Candidates` traz as lições `[candidata]` do acervo (já excluídas as features promovidas —
idempotência). Agrupe as **pendentes** por **domínio** (do alvo da prática). Selecione os domínios com
≥1 candidata.

---

## Passo 2 — Fan-out + detecção de recorrência

**Fan-out** via ferramenta **`Agent`**: 1 subagente por domínio, passando **o critério "O que é
promovível"** (tabela acima) + as lições candidatas + a KB `operations` existente do domínio. Cada
subagente identifica a lição **recorrente** (mesma prática em **≥2 features**) e propõe **1 entrada**
`operations` / `content_type: runbook`, com `promoted_from: [features]`.

---

## Passo 3 — Plano (não ação)

Consolide as propostas num **plano** `.claude/kb/_lessons/<data>-plan.md` — por domínio: a **prática**, a
**entrada-alvo**, o `promoted_from` e o rationale. Apresente o resumo ao usuário.

---

## Passo 4 — Aprovação (AskUserQuestion)

`AskUserQuestion`: **aplicar tudo** / **escolher domínios** / **só-plano**. Sem aprovação → **fim, KB
intocada**.

---

## Passo 5 — Aplicar (nunca-destrutivo)

Só após aprovação. **Backup** de qualquer entrada afetada (molde `Backup-File`) — o backup vai **FORA
de `.claude/kb/`**, em `.claude/.cache/kb-backup/<data>/` (gitignored). **Nunca** ao lado do plano em
`_lessons/`: um `.md` com frontmatter de entrada dentro da KB é backup **invisível** ao lint e **duplica
o id** no grafo (`kb-lint` acusa `misplaced-entry`). Gravar a(s) entrada(s) `operations` conforme
[`kb-taxonomy.md`](../rules/kb-taxonomy.md) (frontmatter + **`promoted_from`**); registrar no **ledger**
`.claude/kb/_lessons/<data>.md`.

---

## Passo 6 — Verificar

```powershell
$findings = @(Test-LessonProvenance -KbDir .claude/kb -ArchiveDir .claude/sdd/archive)
```

`$findings` não-vazio (`lesson-without-source`) **ou** entrada nova inválida no `kb-lint` → **reverter do
backup** e avisar (fail-safe; promoção não fica pela metade).

---

## Passo 7 — Reindexar

Rode **`/sync-context`** (G4) para o índice/ponteiros refletirem a nova entrada. Relatório final:
práticas promovidas, entradas criadas, `promoted_from` por entrada.

---

## Regras

- **Só o recorrente** (≥2 features); lição `[pontual]` não promove — vira ruído na KB.
- **Não invente recorrência** sem ≥2 fontes reais.
- **Plano → aprova → aplica** com **backup**; nunca grava sem `promoted_from`/sem aprovação.
- **Nunca-destrutivo**: não toca o acervo `archive/` (só lê — é histórico imutável; a proveniência
  mora na KB); não repromove o já promovido (`promoted_from` é idempotente).
- **Não promova entre domínios** diferentes (promove dentro do domínio).
- Destino é a KB `operations` — **nunca** uma rule sempre-ativa.
- Sem engine — `Agent` nativo + a verificação determinística (`tools/learn.ps1`).
