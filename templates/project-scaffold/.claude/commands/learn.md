---
description: "Promover lição recorrente do acervo de SHIPPED a uma entrada de KB operations"
argument-hint: "(sem argumento — varre o acervo)"
---

# /learn — fechar o loop de boas práticas

Relê o acervo de **`SHIPPED`**, detecta a lição **recorrente** (que se repete entre features) e a
**promove** a uma entrada de KB `operations` reaplicável. **Nunca-destrutivo** (plano → aprova → aplica),
com **proveniência** (`promoted_from`). Protocolo na regra [`lessons.md`](../rules/lessons.md); sem engine
(reusa o molde do `/reflect`/G6).

> Distinto do `/reflect` (consolida o que **já está** na KB) e do `documenter` (registra ADRs em
> `docs/`): o `/learn` **capta o novo** — promove a prática que o uso real revelou.

---

## Passo 0 — Gatilho (no-op sob o limiar)

Resolva `$toolsRoot` pela cascata de [`rules/tooling.md`](../rules/tooling.md) e verifique se há candidatas:

```powershell
. "$toolsRoot/learn.ps1"
$status = Test-LessonsReady -ArchiveDir .claude/sdd/archive -KbDir .claude/kb
```

`$status.Ready` **falso** → **no-op**: avise *"acervo sem lições recorrentes suficientes (pendentes
$($status.PendingCount)/$($status.Threshold)) — nada a promover"* e **encerre**. Verdadeiro → siga.

---

## Passo 1 — Agrupar candidatas por domínio

`$status.Candidates` traz as lições `[candidata]` do acervo (já excluídas as features promovidas —
idempotência). Agrupe as **pendentes** por **domínio** (do alvo da prática). Selecione os domínios com
≥1 candidata.

---

## Passo 2 — Fan-out + detecção de recorrência

**Fan-out** via ferramenta **`Agent`**: 1 subagente por domínio, passando a regra `lessons.md` + as
lições candidatas + a KB `operations` existente do domínio. Cada subagente identifica a lição
**recorrente** (mesma prática em **≥2 features**) e propõe **1 entrada** `operations` /
`content_type: runbook`, com `promoted_from: [features]`.

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

Só após aprovação. **Backup** de qualquer entrada afetada (molde `Backup-File`); gravar a(s) entrada(s)
`operations` conforme [`kb-taxonomy.md`](../rules/kb-taxonomy.md) (frontmatter + **`promoted_from`**);
registrar no **ledger** `.claude/kb/_lessons/<data>.md`.

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

- **Só o recorrente** (≥2 features); lição `[pontual]` não promove.
- **Plano → aprova → aplica** com **backup**; nunca grava sem `promoted_from`/sem aprovação.
- **Nunca-destrutivo**: não toca o acervo `archive/` (só lê); não repromove o já promovido.
- Destino é a KB `operations` — **nunca** uma rule sempre-ativa.
- Sem engine — `Agent` nativo + a verificação determinística (`tools/learn.ps1`).
